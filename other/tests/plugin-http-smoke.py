"""Run the production plugin HTTP methods against a local synthetic server."""
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
import subprocess
import tempfile
import threading
from urllib.parse import parse_qs, urlsplit

source = Path('yina/JavascriptAPIHttp.swift').read_text()
start = source.index('  func download(', source.index('class JavascriptAPIHttp:'))
end = source.index('@objc protocol JavascriptAPIXmlrpcExportable', start)
methods = source[start:end]
fixture = r'''import Foundation
extension CharacterSet { static var urlAllowed: CharacterSet { .urlQueryAllowed } }
enum HTTPMethod: String { case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE" }
enum JavascriptPlugin { enum Permission { case networkRequest } }
final class JSValue {
  let callback: (([Any]) -> Void)?
  init(_ callback: (([Any]) -> Void)? = nil) { self.callback = callback }
  convenience init(undefinedIn: Any) { self.init() }
  func call(withArguments arguments: [Any]) { callback?(arguments) }
}
final class Instance {
  private var tasks: Set<URLSessionTask> = []
  func canAccess(url: URL) -> Bool { url.host == "127.0.0.1" }
  func track(_ task: URLSessionTask) { tasks.insert(task) }
  func untrack(_ task: URLSessionTask) { tasks.remove(task) }
  var pending: Int { tasks.count }
}
final class JavascriptAPIHttp {
  var pluginInstance: Instance! = Instance()
  let context = NSObject()
  let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 3
    return URLSession(configuration: config)
  }()
  var errors: [String] = []
  var completed: (Bool, [Any])?
  var completionHandler: ((Bool, [Any]) -> Void)?
  func throwError(withMessage message: String) { errors.append(message) }
  func whenPermitted<T>(to permission: JavascriptPlugin.Permission, _ body: () -> T?) -> T? { body() }
  func parsePath(_ path: String) -> (path: String?, local: Bool) { (path, true) }
  func createPromise(_ body: @escaping (JSValue, JSValue) -> Void) -> JSValue {
    body(JSValue({ [weak self] args in
           self?.completed = (true, args)
           self?.completionHandler?(true, args)
         }), JSValue({ [weak self] args in
           self?.completed = (false, args)
           self?.completionHandler?(false, args)
         }))
    return JSValue()
  }
  func post(_ url: String, _ options: [String: Any]?) -> JSValue? { request(.post, url: url, options: options) }
'''+methods+r'''
@main enum Smoke {
  static func main() {
    let target = CommandLine.arguments[1]
    let url = CommandLine.arguments[2]
    let http = JavascriptAPIHttp()
    let options: [String: Any] = ["method": "POST", "params": ["episode": "3", "special": "a+b & é"],
       "data": ["token": "abc", "special": "a+b & é"], "headers": ["X-Probe": "yes"]]
    var stage = 0
    http.completionHandler = { success, args in
      precondition(success && http.pluginInstance.pending == 0, "request failed: \(args) \(http.errors)")
      if stage == 0 {
        precondition((try! FileManager.default.attributesOfItem(atPath: target)[.size] as! Int) == 5 * 1024 * 1024, "download size")
        stage = 1
        _ = http.post(url, ["params": ["episode": "3", "special": "a+b & é"],
                            "data": ["token": "abc", "special": "a+b & é"],
                            "headers": ["X-Probe": "yes", "X-Small": "yes"]])
      } else {
        let result = args[0] as! [String: Any?]
        precondition(result["statusCode"] as? Int == 200, "status")
        let json = result["data"] as! [String: String]
        precondition(json["method"] == "POST", "JSON")
        precondition((result["text"] as? String)?.contains("POST") == true, "text")
        print("PASS: production HTTP download writes 5 MiB; method, params, headers, JSON/text and owner cleanup")
        exit(0)
      }
    }
    _ = http.download(url, target, options)
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
      fputs("Timed out waiting for Promise completion, stage \(stage), result \(String(describing: http.completed))\n", stderr)
      exit(1)
    }
    dispatchMain()
  }
}
'''
class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length)
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        form = parse_qs(body.decode('utf-8'))
        valid = (url.path == '/download' and query == {'episode': ['3'], 'special': ['a+b & é']} and
                 form == {'token': ['abc'], 'special': ['a+b & é']} and
                 self.headers.get('X-Probe') == 'yes')
        small = self.headers.get('X-Small') == 'yes'
        payload = b'{"method":"POST"}' if small else b'x' * (5 * 1024 * 1024)
        self.send_response(200 if valid else 400)
        self.send_header('Content-Type', 'application/json' if small else 'application/octet-stream')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_args):
        pass

with tempfile.TemporaryDirectory(prefix='yina-plugin-http-') as directory:
    path = Path(directory)
    (path/'test.swift').write_text(fixture)
    cache = path/'module-cache'
    cache.mkdir()
    env = {**os.environ, 'CLANG_MODULE_CACHE_PATH': str(cache), 'SWIFT_MODULE_CACHE_PATH': str(cache)}
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(cache), str(path/'test.swift'), '-o', str(path/'test')], check=True, env=env)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        url = f'http://127.0.0.1:{server.server_port}/download'
        subprocess.run([str(path/'test'), str(path/'download.bin'), url], check=True, timeout=15)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
