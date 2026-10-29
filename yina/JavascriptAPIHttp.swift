//
//  JavascriptAPIHttp.swift
//  yina
//
//  Created by Collider LI on 12/9/2018.
//  Copyright © 2018 lhc. All rights reserved.
//

import Foundation
import JavaScriptCore
import Just

@objc protocol JavascriptAPIHttpExportable: JSExport {
  func get(_ url: String, _ options: [String: Any]?) -> JSValue?
  func post(_ url: String, _ options: [String: Any]?) -> JSValue?
  func put(_ url: String, _ options: [String: Any]?) -> JSValue?
  func patch(_ url: String, _ options: [String: Any]?) -> JSValue?
  func delete(_ url: String, _ options: [String: Any]?) -> JSValue?
  func xmlrpc(_ location: String) -> JavascriptAPIXmlrpc?
  func download(_ url: String, _ dest: String, _ options: [String: Any]?) -> JSValue?
}

class JavascriptAPIHttp: JavascriptAPI, JavascriptAPIHttpExportable {
  private let session = URLSession.shared

  @objc func get(_ url: String, _ options: [String: Any]?) -> JSValue? {
    return request(.get, url: url, options: options)
  }

  @objc func post(_ url: String, _ options: [String: Any]?) -> JSValue? {
    return request(.post, url: url, options: options)
  }

  @objc func put(_ url: String, _ options: [String: Any]?) -> JSValue? {
    return request(.put, url: url, options: options)
  }

  @objc func patch(_ url: String, _ options: [String: Any]?) -> JSValue? {
    return request(.patch, url: url, options: options)
  }

  @objc func delete(_ url: String, _ options: [String: Any]?) -> JSValue? {
    return request(.delete, url: url, options: options)
  }

  @objc func xmlrpc(_ location: String) -> JavascriptAPIXmlrpc? {
    guard hostIsValid(location) else {
      return nil
    }
    return JavascriptAPIXmlrpc(context: context, pluginInstance: pluginInstance, location: location)
  }

  func download(_ url: String, _ dest: String, _ options: [String: Any]?) -> JSValue? {
    return whenPermitted(to: .networkRequest) {
      guard hostIsValid(url) else {
        throwError(withMessage: "URL is not allowed.")
        return nil
      }
      guard let method = HTTPMethod(rawValue: options?["method"] as? String ?? "GET") else {
        throwError(withMessage: "method is invalid.")
        return nil
      }
      guard let destPath = self.parsePath(dest).path else {
        throwError(withMessage: "Not allowed to write to the destination.")
        return nil
      }
      guard let request = makeRequest(method, url: url, options: options) else { return nil }
      return createPromise { [weak self] resolve, reject in
        guard let self, let owner = self.pluginInstance else { return }
        weak var trackedTask: URLSessionTask?
        let task = self.session.downloadTask(with: request) { [weak self, weak owner] temporaryURL, response, error in
          if let trackedTask { owner?.untrack(trackedTask) }
          let http = response as? HTTPURLResponse
          let status = http?.statusCode ?? 0
          var failure: [String: Any?]?
          if let error {
            failure = ["statusCode": status, "reason": error.localizedDescription, "data": nil, "text": nil]
          } else if !(200...299).contains(status) {
            let responseData = temporaryURL.flatMap { try? Data(contentsOf: $0) }
            failure = [
              "statusCode": status,
              "reason": HTTPURLResponse.localizedString(forStatusCode: status),
              "data": responseData.flatMap { try? JSONSerialization.jsonObject(with: $0) },
              "text": responseData.flatMap { String(data: $0, encoding: .utf8) }
            ]
          } else if let temporaryURL {
            let destination = URL(fileURLWithPath: destPath)
            let staged = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).download")
            do {
              try FileManager.default.copyItem(at: temporaryURL, to: staged)
              if FileManager.default.fileExists(atPath: destPath) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
              } else {
                try FileManager.default.moveItem(at: staged, to: destination)
              }
            } catch {
              try? FileManager.default.removeItem(at: staged)
              failure = ["statusCode": status, "reason": "Unable to write to the destination.", "data": nil, "text": nil]
            }
          } else {
            failure = ["statusCode": status, "reason": "No downloaded file was returned.", "data": nil, "text": nil]
          }
          DispatchQueue.main.async { [weak self] in
            guard self?.pluginInstance != nil else { return }
            if let failure {
              reject.call(withArguments: [failure])
            } else {
              resolve.call(withArguments: [])
            }
          }
        }
        trackedTask = task
        owner.track(task)
        task.resume()
      }
    }
  }

  private func request(_ method: HTTPMethod, url: String, options: [String: Any]?) -> JSValue? {
    return whenPermitted(to: .networkRequest) {
      // check host
      guard hostIsValid(url) else {
        return JSValue(undefinedIn: context)
      }
      guard let request = makeRequest(method, url: url, options: options) else { return nil }
      return createPromise { [weak self] resolve, reject in
        guard let self, let owner = self.pluginInstance else { return }
        weak var trackedTask: URLSessionTask?
        let task = self.session.dataTask(with: request) { [weak self, weak owner] body, response, error in
          if let trackedTask { owner?.untrack(trackedTask) }
          let http = response as? HTTPURLResponse
          let status = http?.statusCode ?? 0
          let result: [String: Any?] = [
            "statusCode": status,
            "reason": error?.localizedDescription ?? HTTPURLResponse.localizedString(forStatusCode: status),
            "data": body.flatMap { try? JSONSerialization.jsonObject(with: $0) },
            "text": body.flatMap { String(data: $0, encoding: .utf8) }
          ]
          DispatchQueue.main.async { [weak self] in
            guard self?.pluginInstance != nil else { return }
            ((error == nil && (200...299).contains(status)) ? resolve : reject).call(withArguments: [result])
          }
        }
        trackedTask = task
        owner.track(task)
        task.resume()
      }
    }
  }

  private func makeRequest(_ method: HTTPMethod, url: String, options: [String: Any]?) -> URLRequest? {
    guard var components = URLComponents(string: url.addingPercentEncoding(withAllowedCharacters: .urlAllowed) ?? url),
          components.url != nil else {
      throwError(withMessage: "URL is invalid.")
      return nil
    }
    let params = options?["params"] as? [String: String] ?? [:]
    if !params.isEmpty {
      var added = URLComponents()
      added.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
      let encoded = added.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") ?? ""
      components.percentEncodedQuery = [components.percentEncodedQuery, encoded]
        .compactMap { $0?.isEmpty == false ? $0 : nil }
        .joined(separator: "&")
    }
    guard let requestURL = components.url else { return nil }
    var request = URLRequest(url: requestURL)
    request.httpMethod = method.rawValue
    for (key, value) in options?["headers"] as? [String: String] ?? [:] {
      request.setValue(value, forHTTPHeaderField: key)
    }
    if let data = options?["data"] as? [String: Any], !data.isEmpty {
      var body = URLComponents()
      body.queryItems = data.map { URLQueryItem(name: $0.key, value: String(describing: $0.value)) }
      request.httpBody = body.percentEncodedQuery?
        .replacingOccurrences(of: "+", with: "%2B")
        .data(using: .utf8)
      if request.value(forHTTPHeaderField: "Content-Type") == nil {
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      }
    }
    return request
  }

  private func hostIsValid(_ url: String) -> Bool {
    guard let urlComponents = URLComponents(string: url.addingPercentEncoding(withAllowedCharacters: .urlAllowed) ?? url),
          let requestURL = urlComponents.url else {
      throwError(withMessage: "URL \(url) is invalid.")
      return false
    }
    guard pluginInstance.canAccess(url: requestURL) else {
      throwError(withMessage: "URL \(url) is not allowed.")
      return false
    }
    return true
  }
}
@objc protocol JavascriptAPIXmlrpcExportable: JSExport {
  func call(_ method: String, _ args: [Any]) -> JSValue?
}

class JavascriptAPIXmlrpc: JavascriptAPI, JavascriptAPIXmlrpcExportable {
  private let xmlrpc: JustXMLRPC

  init(context: JSContext, pluginInstance: JavascriptPluginInstance, location: String) {
    self.xmlrpc = JustXMLRPC(location)
    super.init(context: context, pluginInstance: pluginInstance)
  }

  @objc func call(_ method: String, _ args: [Any]) -> JSValue? {
    return createPromise { resolve, reject in
      self.xmlrpc.call(method, args) { response in
        switch response {
        case .ok(let returnValue):
          resolve.call(withArguments: [returnValue])
        case .failure:
          reject.call(withArguments: [])
        case .error(let err):
          reject.call(withArguments: [[
            "httpCode": err.httpCode,
            "reason": err.reason,
            "description": err.readableDescription,
          ] as [String: Any]])
        }
      }
    }
  }
}
