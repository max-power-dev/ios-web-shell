// A thin WKWebView shell. It serves the files bundled in App.app/www over the custom
// scheme shellres://local/, so the page loads with no network and no file:// rules.
// Swift language mode 5, iOS 16.0.
import UIKit
import WebKit
import os

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    let soakLog = SoakLogStore()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        soakLog.append(SoakEntry.make(kind: "launch"))
        #if DEV_FLAVOR
        // Dev builds only. Logged so the optimizer keeps the string, the release binary must lack it.
        let testModeMarker = "__shell_test_mode__"
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "shell", category: "spike")
            .log("\(testModeMarker, privacy: .public)")
        #endif
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: SoakLogViewController(store: soakLog))
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        soakLog.append(SoakEntry.make(kind: "resume"))
    }
}

final class WebViewController: UIViewController, WKNavigationDelegate {
    static let scheme = "shellres"
    static let entry = URL(string: "shellres://local/index.html")!

    private var webView: WKWebView!
    private let bridge = Bridge()

    override func loadView() {
        let config = WKWebViewConfiguration()
        // Must be registered before the web view exists, and only once per scheme.
        let root = Bundle.main.bundleURL.appendingPathComponent("www", isDirectory: true)
        config.setURLSchemeHandler(SchemeHandler(root: root), forURLScheme: Self.scheme)
        config.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "native")
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        bridge.webView = webView
        #if DEV_FLAVOR
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        #endif
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.load(URLRequest(url: Self.entry))
    }

    // The web content process can be killed under memory pressure while the app lives on.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: Bridge.terminationCountKey) + 1, forKey: Bridge.terminationCountKey)
        webView.load(URLRequest(url: Self.entry))
    }
}

final class SchemeHandler: NSObject, WKURLSchemeHandler {
    private let root: URL
    private var stopped = Set<ObjectIdentifier>()
    private let lock = NSLock()

    init(root: URL) {
        self.root = root
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        // A new task may reuse the identity of a stopped one that is gone.
        lock.lock(); stopped.remove(ObjectIdentifier(task)); lock.unlock()
        let path = task.request.url?.path ?? "/"
        let relative = (path.isEmpty || path == "/") ? "index.html" : path
        guard !path.contains(".."),
              let data = try? Data(contentsOf: root.appendingPathComponent(relative)) else {
            finish(task, status: 404, mime: "text/plain", data: Data())
            return
        }
        finish(task, status: 200, mime: Self.mime(for: relative), data: data)
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        lock.lock(); stopped.insert(ObjectIdentifier(task)); lock.unlock()
    }

    private func finish(_ task: any WKURLSchemeTask, status: Int, mime: String, data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped.contains(ObjectIdentifier(task)), let url = task.request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": mime,
                                                            "Content-Length": "\(data.count)",
                                                            "Cache-Control": "no-store"]) else {
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    static func mime(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html": return "text/html"
        case "js": return "text/javascript"
        case "wasm": return "application/wasm"
        case "json": return "application/json"
        case "m4a": return "audio/mp4"
        default: return "application/octet-stream"
        }
    }
}
