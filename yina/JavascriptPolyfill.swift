//
//  JavascriptPolyfill.swift
//  yina
//
//  Created by Collider LI on 6/3/2020.
//  Copyright © 2020 lhc. All rights reserved.
//

import JavaScriptCore

class JavascriptPolyfill {
  weak var plugin: JavascriptPluginInstance!
  private let timerLock = NSLock()
  private var timers = [String: Timer]()
  private var pendingTimers = Set<String>()

  init(pluginInstance: JavascriptPluginInstance) {
    self.plugin = pluginInstance
  }

  deinit {
    removeAllTimers()
  }

  func removeAllTimers() {
    let removed = timerLock.withLock { () -> [Timer] in
      let removed = Array(timers.values)
      timers.removeAll()
      pendingTimers.removeAll()
      return removed
    }
    removed.forEach { $0.invalidate() }
  }

  func removeTimer(identifier: String) {
    let timer = timerLock.withLock {
      pendingTimers.remove(identifier)
      return timers.removeValue(forKey: identifier)
    }
    timer?.invalidate()
  }

  func createTimer(callback: JSValue, ms: Double, repeats : Bool) -> String {
    let clampedMs = repeats ? max(ms, 16.0) : ms
    let timeInterval  = clampedMs/1000.0
    let uuid = NSUUID().uuidString
    timerLock.withLock { _ = pendingTimers.insert(uuid) }

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let timer = Timer(timeInterval: timeInterval, repeats: repeats) { [weak self] timer in
        guard let self else { timer.invalidate(); return }
        guard self.timerLock.withLock({ self.timers[uuid] === timer }) else { return }
        if !repeats { self.removeTimer(identifier: uuid) }
        callback.call(withArguments: nil)
      }
      timer.tolerance = timeInterval * 0.1
      let shouldSchedule = self.timerLock.withLock {
        guard self.pendingTimers.remove(uuid) != nil else { return false }
        self.timers[uuid] = timer
        return true
      }
      if shouldSchedule { RunLoop.main.add(timer, forMode: .default) }
    }
    return uuid
  }

  func register(inContext context: JSContext) {
    let setInterval: @convention(block) (JSValue, Double) -> String = { [unowned self] (callback, ms) in
      return self.createTimer(callback: callback, ms: ms, repeats: true)
    }

    let setTimeout: @convention(block) (JSValue, Double) -> String = { [unowned self] (callback, ms) in
      return self.createTimer(callback: callback, ms: ms, repeats: false)
    }

    let clearInterval: @convention(block) (String) -> () = { [unowned self] identifier in
      self.removeTimer(identifier: identifier)
    }

    let clearTimeout: @convention(block) (String) -> () = { [unowned self] identifier in
      self.removeTimer(identifier: identifier)
    }

    let require: @convention(block) (String) -> Any? = { [unowned self] path in
      let instance = self.plugin!
      let currentPath = instance.currentFile!.deletingLastPathComponent()
      let requiredURL = currentPath.appendingPathComponent(path).standardized
      guard requiredURL.absoluteString.hasPrefix(instance.plugin.root.absoluteString) else {
        return nil
      }
      return [
        "path": requiredURL.path,
        "module": instance.evaluateFile(requiredURL, asModule: true)
      ] as [String: Any?]
    }

    context.setObject(clearInterval, forKeyedSubscript: "clearInterval" as NSString)
    context.setObject(clearTimeout, forKeyedSubscript: "clearTimeout" as NSString)
    context.setObject(setInterval, forKeyedSubscript: "setInterval" as NSString)
    context.setObject(setTimeout, forKeyedSubscript: "setTimeout" as NSString)
    context.setObject(require, forKeyedSubscript: "__require__" as NSString)
    context.evaluateScript(requirePolyfill)
  }
}

fileprivate let requirePolyfill = """
require = (() => {
  const cache = {};
  return function (file) {
    if (cache[file]) {
      return cache[file];
    }
    const result = __require__(file);
    if (result) {
      cache[result.path] = result.module;
      return result.module;
    }
    return undefined;
  };
})();
"""
