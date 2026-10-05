//
//  WebSocketServer.swift
//  yina
//
//  Created by Hechen Li on 8/8/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation
import Network


protocol WebSocketServerDelegate: AnyObject {
  func stateUpdated(_ state: NWListener.State)
  func newConnection(_ conn: NWConnection, connID: String)
  func connection(_ conn: String, stateUpdated state: NWConnection.State)
  func connection(_ conn: String, receivedData data: Data, context: NWConnection.ContentContext)
}


class WebSocketServer {
  let label: String
  weak var delegate: WebSocketServerDelegate?

  var listener: NWListener
  private var activeConnections: [String: NWConnection] = [:]
  var connections: [String: NWConnection] { onServerQueue { activeConnections } }

  let serverQueue: DispatchQueue
  private let queueKey = DispatchSpecificKey<Void>()
  private var stopped = false
  let subsystem: Logger.Subsystem

  init?(port: UInt16, label: String, logger: Logger.Subsystem? = nil) {
    self.label = label
    self.serverQueue = DispatchQueue(label: "YINAWebSocketServer.\(label)")
    self.subsystem = logger ?? Logger.makeSubsystem("ws-server")
    // TODO: Support TLS
    let parameters = NWParameters(tls: nil)
    parameters.allowLocalEndpointReuse = true
    parameters.includePeerToPeer = true

    let wsOptions = NWProtocolWebSocket.Options()
    wsOptions.autoReplyPing = true
    parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

    do {
      if let port = NWEndpoint.Port(rawValue: port) {
        listener = try NWListener(using: parameters, on: port)
      } else {
        Logger.log("Cannot start WebSocket server on port \(port)", level: .error, subsystem: subsystem)
        return nil
      }
    } catch {
      Logger.log(error.localizedDescription, level: .error, subsystem: subsystem)
      return nil
    }
    serverQueue.setSpecific(key: queueKey, value: ())
  }

  func start() {
    onServerQueue {
      guard !stopped else { return }
      listener.newConnectionHandler = { [weak self] connection in
        guard let self, !self.stopped else { connection.cancel(); return }
        self.handleNewConnection(connection)
      }
      listener.stateUpdateHandler = { [weak self] state in
        guard let self, !self.stopped else { return }
        self.handleStateUpdate(state)
      }
      listener.start(queue: serverQueue)
    }
  }

  func stop() {
    onServerQueue {
      stopped = true
      delegate = nil
      listener.newConnectionHandler = nil
      listener.stateUpdateHandler = nil
      listener.cancel()
      for connection in activeConnections.values {
        connection.stateUpdateHandler = nil
        connection.cancel()
      }
      activeConnections.removeAll()
    }
  }

  deinit { stop() }

  private func onServerQueue<T>(_ body: () -> T) -> T {
    if DispatchQueue.getSpecific(key: queueKey) != nil { return body() }
    return serverQueue.sync(execute: body)
  }

  private func handleNewConnection(_ connection: NWConnection) {
    // Create a UUID to identify each connection
    let connID = UUID().uuidString
    Logger.log("New connection: \(connID)", level: .debug, subsystem: subsystem)
    Logger.log(connection.debugDescription, level: .debug, subsystem: subsystem)
    activeConnections[connID] = connection
    delegate?.newConnection(connection, connID: connID)
    guard !stopped else { connection.cancel(); return }

    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let self, let connection, !self.stopped else { return }
      Logger.log("Connection \(state) (\(connID))", subsystem: subsystem)
      self.delegate?.connection(connID, stateUpdated: state)
      switch state {
      case .failed(_):
        connection.cancel()  // do we need to cancel here?
        fallthrough
      case .cancelled:
        connection.stateUpdateHandler = nil
        self.activeConnections[connID] = nil
      default:
        break
      }
    }

    connection.start(queue: serverQueue)

    receive(from: connection, connID: connID)
  }

  private func receive(from connection: NWConnection, connID: String) {
    guard !stopped else { return }
    connection.receiveMessage { [weak self, weak connection] (data, context, isComplete, error) in
      guard let self, let connection, !self.stopped,
            self.activeConnections[connID] === connection else { return }
      if error != nil {
        connection.cancel()
        return
      }
      if let data, let context {
        // handle ping frames
        if let metadata = context.protocolMetadata as? [NWProtocolWebSocket.Metadata],
           metadata.first?.opcode == .ping {
          Logger.log("Ping (\(connID))", subsystem: subsystem)
          let pongContext = NWConnection.ContentContext(
            identifier: "pong",
            metadata: [NWProtocolWebSocket.Metadata(opcode: .pong)]
          )
          connection.send(content: data, contentContext: pongContext, completion: .idempotent)
        } else {
          // normal data
          Logger.log("Data (\(connID))", subsystem: subsystem)
          self.delegate?.connection(connID, receivedData: data, context: context)
        }
        self.receive(from: connection, connID: connID)
      }
    }
  }

  private func handleStateUpdate(_ state: NWListener.State) {
    Logger.log("Server \(state)", subsystem: subsystem)
    delegate?.stateUpdated(state)
  }

  func send(data: Data, to connection: NWConnection, callback: ((NWError?) -> Void)?) throws {
    // do we need a separate send(text:to:) method to send text frames?
    let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
    let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
    connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed({ [weak self] error in
      guard let self, !self.stopped else { return }
      callback?(error)
    }))
  }
}
