//
//  JavascriptAPIUtils.swift
//  yina
//
//  Created by Collider LI on 2/3/2019.
//  Copyright © 2019 lhc. All rights reserved.
//

import Foundation
import JavaScriptCore

fileprivate func searchBinary(_ file: String, in url: URL) -> URL? {
  let url = url.appendingPathComponent(file)
  return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

fileprivate extension Process {
  var descriptionDict: [String: Any] {
    return [
      "status": terminationStatus
    ]
  }
}

@objc protocol JavascriptAPIUtilsExportable: JSExport {
  func fileInPath(_ file: String) -> Bool
  func resolvePath(_ path: String) -> String?
  func exec(_ file: String, _ args_: Any, _ cwd: JSValue?, _ stdoutHook_: JSValue?, _ stderrHook_: JSValue?) -> JSValue?
  func execWithOptions(_ file: String, _ args_: Any, _ cwd: JSValue?, _ stdoutHook_: JSValue?, _ stderrHook_: JSValue?, _ options: [String: Any]) -> JSValue?
  func ask(_ title: String) -> Bool
  func prompt(_ title: String) -> String?
  func chooseFile(_ title: String, _ options: [String: Any]) -> Any
  func keychainWrite(_ service: String, _ name: String, _ password: String) -> Any
  func keychainRead(_ service: String, _ name: String) -> Any
  func open(_ url: String) -> Bool
  func preferredLocalizations() -> Any
}

class JavascriptAPIUtils: JavascriptAPI, JavascriptAPIUtilsExportable {
  func keychainWrite(_ service: String, _ name: String, _ password: String) -> Any {
    if service.isEmpty {
      return false
    }
    let serviceName = "\(pluginInstance.plugin.identifier) - \(service)"
    do {
      try KeychainAccess.write(username: name, password: password, forService: .init(serviceName))
      return true
    } catch {
      return false
    }
  }
  
  func keychainRead(_ service: String, _ name: String) -> Any {
    if service.isEmpty {
      return false
    }
    let serviceName = "\(pluginInstance.plugin.identifier) - \(service)"
    do {
      let (_, result) = try KeychainAccess.read(username: name, forService: .init(serviceName))
      return result
    } catch {
      return false
    }
  }
  
  override func extraSetup() {
    context.evaluateScript("""
    yina.utils.ERROR_BINARY_NOT_FOUND = -1;
    yina.utils.ERROR_RUNTIME = -2;
    """)
  }

  func fileInPath(_ file: String) -> Bool {
    guard permitted(to: .accessFileSystem) else {
      return false
    }
    if file.isEmpty {
      return false
    }
    if let _ = searchBinary(file, in: Utility.binariesURL) ?? searchBinary(file, in: Utility.exeDirURL) {
      return true
    }
    if let path = parsePath(file, forceLocalPath: false).path {
      return FileManager.default.fileExists(atPath: path)
    }
    return false
  }

  func resolvePath(_ path: String) -> String? {
    guard permitted(to: .accessFileSystem) else {
      return nil
    }
    return parsePath(path).path
  }

  func exec(_ file: String, _ args_: Any, _ cwd: JSValue?, _ stdoutHook_: JSValue?, _ stderrHook_: JSValue?) -> JSValue? {
    runProcess(file, args_, cwd, stdoutHook_, stderrHook_, options: [:])
  }

  /// `output: "files"` returns stdoutFile/stderrFile in the plugin's temporary
  /// directory. `maxOutputBytes` rejects when the combined streams exceed the
  /// limit; no successful result is truncated. Plain exec retains text results.
  func execWithOptions(_ file: String, _ args_: Any, _ cwd: JSValue?, _ stdoutHook_: JSValue?, _ stderrHook_: JSValue?, _ options: [String: Any]) -> JSValue? {
    runProcess(file, args_, cwd, stdoutHook_, stderrHook_, options: options)
  }

  private func runProcess(_ file: String, _ args_: Any, _ cwd: JSValue?, _ stdoutHook_: JSValue?, _ stderrHook_: JSValue?, options: [String: Any]) -> JSValue? {
    guard permitted(to: .accessFileSystem) else {
      return nil
    }
    
    guard let args = args_ as? [String] else {
      throwError(withMessage: "The exec args parameter must be a string array")
      return nil
    }
    let fileOutput = options["output"] as? String == "files"
    if let output = options["output"] as? String, output != "files" && output != "text" {
      throwError(withMessage: "output must be text or files")
      return nil
    }
    let maxOutputBytes = options["maxOutputBytes"] as? Int
    if let maxOutputBytes, maxOutputBytes < 0 {
      throwError(withMessage: "maxOutputBytes must be nonnegative")
      return nil
    }

    return createPromise { [weak self] resolve, reject in
      guard let self, let owner = self.pluginInstance else { return }
      var path = ""
      var args = args
      if !file.contains("/") {
        if let url = searchBinary(file, in: Utility.binariesURL) ?? searchBinary(file, in: Utility.exeDirURL) {
          // a binary included in YINA's bundle?
          path = url.path(percentEncoded: false)
        } else {
          // assume it's a system command
          args.insert(file, at: 0)
        }
      } else {
        // it should be an existing file
        if file.first == "/" {
          // an absolute path?
          path = file
        } else {
          path = parsePath(file).path ?? ""
        }
        // make sure the file exists
        guard FileManager.default.fileExists(atPath: path) else {
          reject.call(withArguments: [-1, "Cannot find the binary \(file)"])
          return
        }
      }

      // If this binary belongs to the plugin but doesn't have exec permission, try fix it
      if !FileManager.default.isExecutableFile(atPath: path) && (
        path.hasPrefix(self.pluginInstance.plugin.dataURL.path) ||
        path.hasPrefix(self.pluginInstance.plugin.tmpURL.path)) {
        do {
          try FileManager.default.setAttributes([.posixPermissions: NSNumber(integerLiteral: 0o755)], ofItemAtPath: path)
        } catch {
          reject.call(withArguments: [-2, "The binary is not executable, and execute permission cannot be added"])
          return
        }
      }

      let (stdout, stderr) = (Pipe(), Pipe())
      let process = Process()
      process.environment = ["LC_ALL": "en_US.UTF-8"]
      process.launchPath = path
      process.arguments = args
      if let cwd, cwd.isString, let cwdPath = parsePath(cwd.toString()).path {
        process.currentDirectoryPath = cwdPath
      }
      process.standardOutput = stdout
      process.standardError = stderr

      let outputDirectory = owner.plugin.tmpURL
      let stdoutURL = outputDirectory.appendingPathComponent("exec-\(UUID().uuidString)-stdout")
      let stderrURL = outputDirectory.appendingPathComponent("exec-\(UUID().uuidString)-stderr")
      do {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
      } catch {
        reject.call(withArguments: ["Unable to create process output files"])
        return
      }
      guard FileManager.default.createFile(atPath: stdoutURL.path, contents: nil),
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil),
            let stdoutFile = try? FileHandle(forWritingTo: stdoutURL),
            let stderrFile = try? FileHandle(forWritingTo: stderrURL) else {
        try? FileManager.default.removeItem(at: stdoutURL)
        try? FileManager.default.removeItem(at: stderrURL)
        reject.call(withArguments: ["Unable to create process output files"])
        return
      }
      let group = DispatchGroup()
      let outputLock = NSLock()
      var outputBytes = 0
      var exceededLimit = false
      func capture(_ pipe: Pipe, to outputFile: FileHandle, hook: JSValue?) {
        group.enter()
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] file in
          let data = file.availableData
          guard !data.isEmpty else {
            file.readabilityHandler = nil
            group.leave()
            return
          }
          outputLock.lock()
          outputBytes += data.count
          if let maxOutputBytes, outputBytes > maxOutputBytes { exceededLimit = true }
          let overLimit = exceededLimit
          outputLock.unlock()
          if overLimit {
            if let process, process.isRunning { process.terminate() }
            return
          }
          outputFile.write(data)
          if let hook, let text = String(data: data, encoding: .utf8) {
            DispatchQueue.main.async { [weak self] in
              guard self?.pluginInstance != nil else { return }
              hook.call(withArguments: [text])
            }
          }
        }
      }
      capture(stdout, to: stdoutFile, hook: stdoutHook_?.isObject == true ? stdoutHook_ : nil)
      capture(stderr, to: stderrFile, hook: stderrHook_?.isObject == true ? stderrHook_ : nil)
      group.enter()
      process.terminationHandler = { _ in group.leave() }
      Logger.log("Executing \(path) \(args.joined(separator: " "))", subsystem: pluginInstance.subsystem)
      do {
        owner.track(process)
        try process.run()
      } catch {
        owner.untrack(process)
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        try? stdoutFile.close()
        try? stderrFile.close()
        try? FileManager.default.removeItem(at: stdoutURL)
        try? FileManager.default.removeItem(at: stderrURL)
        reject.call(withArguments: ["Execution failed reporting: \(error.localizedDescription)"])
        return
      }

      group.notify(queue: .global(qos: .utility)) { [weak self, weak owner] in
        try? stdoutFile.close()
        try? stderrFile.close()
        outputLock.lock()
        let overLimit = exceededLimit
        outputLock.unlock()
        let result: [String: Any]?
        let readFailure: Bool
        if fileOutput || overLimit {
          result = nil
          readFailure = false
        } else if let out = try? String(contentsOf: stdoutURL, encoding: .utf8),
                  let err = try? String(contentsOf: stderrURL, encoding: .utf8) {
          result = ["status": process.terminationStatus, "stdout": out, "stderr": err]
          readFailure = false
          try? FileManager.default.removeItem(at: stdoutURL)
          try? FileManager.default.removeItem(at: stderrURL)
        } else {
          result = nil
          readFailure = true
          try? FileManager.default.removeItem(at: stdoutURL)
          try? FileManager.default.removeItem(at: stderrURL)
        }
        DispatchQueue.main.async {
          owner?.untrack(process)
          guard self?.pluginInstance != nil else { return }
          if overLimit {
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
            reject.call(withArguments: ["Process output exceeded maxOutputBytes"])
          } else if readFailure {
            reject.call(withArguments: ["Unable to read process output"])
          } else if fileOutput {
            resolve.call(withArguments: [[
              "status": process.terminationStatus,
              "stdoutFile": stdoutURL.path,
              "stderrFile": stderrURL.path
            ] as [String: Any]])
          } else if let result {
            resolve.call(withArguments: [result])
          }
        }
      }
    }
  }

  func ask(_ title: String) -> Bool {
    let panel = NSAlert()
    panel.messageText = title
    panel.addButton(withTitle: NSLocalizedString("general.ok", comment: "OK"))
    panel.addButton(withTitle: NSLocalizedString("general.cancel", comment: "Cancel"))
    return panel.runModal() == .alertFirstButtonReturn
  }

  func prompt(_ title: String) -> String? {
    let panel = NSAlert()
    panel.messageText = title
    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 60))
    input.lineBreakMode = .byWordWrapping
    input.usesSingleLineMode = false
    panel.accessoryView = input
    panel.addButton(withTitle: NSLocalizedString("general.ok", comment: "OK"))
    panel.addButton(withTitle: NSLocalizedString("general.cancel", comment: "Cancel"))
    panel.window.initialFirstResponder = input
    if panel.runModal() == .alertFirstButtonReturn {
      return input.stringValue
    }
    return nil
  }

  func chooseFile(_ title: String, _ options: [String: Any]) -> Any {
    let chooseDir = options["chooseDir"] as? Bool ?? false
    let allowedFileTypes = options["allowedFileTypes"] as? [String]
    return createPromise { resolve, reject in
      Utility.quickOpenPanel(title: title, chooseDir: chooseDir, allowedFileTypes: allowedFileTypes) { result in
        resolve.call(withArguments: [result.path])
      }
    }
  }

  func open(_ url: String) -> Bool {
    // always open web links
    if let url = URL(string: url) {
      if url.scheme == "https" || url.scheme == "http" {
        NSWorkspace.shared.open(url)
        return true
      }
    }
    // might be a file path
    let (path, isLocal) = parsePath(url)
    guard let path else {
      log("utils.open: path cannot be found", level: .error)
      return false
    }
    let fileURL = URL(fileURLWithPath: path)
    if isLocal {
      NSWorkspace.shared.open(fileURL)
      return true
    }
    return whenPermitted(to: .accessFileSystem) {
      NSWorkspace.shared.open(fileURL)
      return true
    } ?? false
  }

  func preferredLocalizations() -> Any {
    return Bundle.main.preferredLocalizations
  }
}
