import Foundation
import JavaScriptCore
import Network

enum Logger {
  typealias Subsystem = String
  enum Level { case error, debug }
  static func makeSubsystem(_ name: String) -> String { name }
  static func log(_ message: String, level: Level = .debug, subsystem: String) {}
}
final class JavascriptPluginInstance {
  final class Plugin { let identifier = "fixture" }
  let plugin = Plugin()
}
class JavascriptAPI: NSObject {
  weak var context: JSContext!
  weak var pluginInstance: JavascriptPluginInstance!
  init(context: JSContext, pluginInstance: JavascriptPluginInstance) {
    self.context = context; self.pluginInstance = pluginInstance
  }
  func throwError(withMessage message: String) { fatalError(message) }
  func cleanUp(_ instance: JavascriptPluginInstance) {}
  func createPromise(_ block: @escaping @convention(block) (JSValue, JSValue) -> Void) -> JSValue {
    context.objectForKeyedSubscript("Promise").construct(withArguments: [JSValue(object: block, in: context)!])
  }
}
func createUInt8Array(fromData data: Data) -> JSValue? { nil }

private final class Probe: WebSocketServerDelegate {
  let received = DispatchSemaphore(value: 0)
  var message = Data()
  func stateUpdated(_ state: NWListener.State) {}
  func newConnection(_ conn: NWConnection, connID: String) {}
  func connection(_ conn: String, stateUpdated state: NWConnection.State) {}
  func connection(_ conn: String, receivedData data: Data, context: NWConnection.ContentContext) {
    message = data
    received.signal()
  }
}

@main enum WebSocketLifecycleSmoke {
  static func main() throws {
    let context = JSContext()!
    let plugin = JavascriptPluginInstance()
    weak var releasedAPI: JavascriptAPIWebSocketController?
    weak var releasedServer: WebSocketServer?
    autoreleasepool {
      let api = JavascriptAPIWebSocketController(context: context, pluginInstance: plugin)
      releasedAPI = api
      api.createServer(["port": UInt16(49181)])
      releasedServer = api.server
    }
    precondition(releasedAPI == nil && releasedServer == nil, "server/delegate must not retain API")

    let api = JavascriptAPIWebSocketController(context: context, pluginInstance: plugin)
    context.evaluateScript("var oldCalls = 0; var newCalls = 0")
    api.onStateUpdate(context.evaluateScript("(() => { oldCalls++; })")!)
    api.onStateUpdate(context.evaluateScript("(() => { newCalls++; })")!)
    api.stateUpdated(.ready)
    precondition(context.objectForKeyedSubscript("oldCalls").toInt32() == 0)
    precondition(context.objectForKeyedSubscript("newCalls").toInt32() == 1, "replacement installs new handler")
    api.onMessage(context.evaluateScript("(() => {})")!)
    api.onNewConnection(context.evaluateScript("(() => {})")!)
    api.onConnectionStateUpdate(context.evaluateScript("(() => {})")!)
    api.createServer(["port": UInt16(49182)])
    var previous: WebSocketServer? = api.server
    api.startServer()
    let lateState = previous!.listener.stateUpdateHandler!
    let lateConnection = previous!.listener.newConnectionHandler!
    api.createServer(["port": UInt16(49183)])
    precondition(previous!.delegate == nil && previous!.connections.isEmpty)
    lateState(.ready)
    let stale = NWConnection(host: "127.0.0.1", port: 49182, using: .tcp)
    lateConnection(stale)
    precondition(previous!.connections.isEmpty, "queued callback cannot admit a connection after stop")
    weak var replaced = previous
    previous = nil
    precondition(replaced == nil, "listener handlers must not retain replaced server")
    api.cleanUp(plugin)
    precondition(api.server == nil && api.stateHandler == nil && api.messageHandler == nil && api.newConnHandler == nil && api.connStateHandler == nil)
    api.stateUpdated(.ready)
    precondition(context.objectForKeyedSubscript("newCalls").toInt32() == 1, "cleanup detaches handlers")

    // Establish a real isolated loopback connection and verify accepted sockets are cancelled.
    var server: WebSocketServer? = WebSocketServer(port: 49184, label: "loopback")!
    let probe = Probe()
    server!.delegate = probe
    server!.start()
    let parameters = NWParameters(tls: nil)
    parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
    let client = NWConnection(to: .url(URL(string: "ws://127.0.0.1:49184/")!), using: parameters)
    let ready = DispatchSemaphore(value: 0)
    client.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
    client.start(queue: DispatchQueue(label: "fixture.client"))
    let deadline = Date(timeIntervalSinceNow: 5)
    while server!.connections.isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    precondition(!server!.connections.isEmpty, "loopback client was accepted")
    precondition(ready.wait(timeout: .now() + 5) == .success, "WebSocket handshake completed")
    let messageContext = NWConnection.ContentContext(identifier: "fixture", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
    client.send(content: Data("fixture".utf8), contentContext: messageContext, isComplete: true, completion: .idempotent)
    precondition(probe.received.wait(timeout: .now() + 5) == .success)
    precondition(server!.serverQueue.sync { probe.message } == Data("fixture".utf8), "messages still reach the delegate")
    let accepted = server!.connections.values.first!
    server!.stop()
    server!.stop()
    precondition(server!.connections.isEmpty && accepted.stateUpdateHandler == nil)
    weak var stopped = server
    server = nil
    precondition(stopped == nil, "accepted receive callbacks must not retain stopped server")
    client.cancel()
    print("PASS: delegate release, handler replacement, server replacement, late callbacks, unload, message delivery, accepted connection cancellation, repeated stop")
  }
}
