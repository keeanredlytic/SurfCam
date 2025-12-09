import SwiftUI
import Foundation
import WebKit

@main
struct SurfCamApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

// Hidden WKWebView that uses Safari's networking stack to bypass iOS connectivity checks
class WebViewRequester: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var completion: ((Bool) -> Void)?
    private var timeoutWorkItem: DispatchWorkItem?
    
    override init() {
        super.init()
        // Create WKWebView on main thread
        DispatchQueue.main.async {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent() // Don't cache
            self.webView = WKWebView(frame: .zero, configuration: config)
            self.webView?.navigationDelegate = self
        }
    }
    
    func request(url: URL, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            guard let webView = self.webView else {
                completion(false)
                return
            }
            
            self.completion = completion
            
            // Cancel any pending timeout
            self.timeoutWorkItem?.cancel()
            
            // Load the URL
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
            webView.load(request)
            
            // Timeout after 4 seconds
            let timeout = DispatchWorkItem { [weak self] in
                self?.webView?.stopLoading()
                self?.completion?(false)
                self?.completion = nil
            }
            self.timeoutWorkItem = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: timeout)
        }
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        timeoutWorkItem?.cancel()
        completion?(true)
        completion = nil
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        timeoutWorkItem?.cancel()
        print("WebView navigation failed: \(error.localizedDescription)")
        completion?(false)
        completion = nil
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        timeoutWorkItem?.cancel()
        print("WebView provisional navigation failed: \(error.localizedDescription)")
        completion?(false)
        completion = nil
    }
    
    // Handle HTTP responses (even non-2xx are considered "loaded")
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // Any response means the request succeeded
        timeoutWorkItem?.cancel()
        completion?(true)
        completion = nil
        decisionHandler(.cancel) // Don't actually render the response
    }
}

class PanRigAPI: ObservableObject {
    private let baseURL = URL(string: "http://192.168.4.1")!
    private let webRequester = WebViewRequester()

    @Published var statusText: String = "Ready"
    @Published var currentAngle: Double = 90   // 0–180
    @Published var minAngle: Double = 10   // adjust for your mount
    @Published var maxAngle: Double = 170
    
    // Test ESP32 connectivity
    func testConnection() {
        send(path: "/", completion: nil)
    }

    private func send(path: String, completion: (() -> Void)? = nil) {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            DispatchQueue.main.async { self.statusText = "Bad URL" }
            return
        }

        DispatchQueue.main.async { self.statusText = "Sending…" }

        // Use WKWebView which uses Safari's networking stack
        // This bypasses iOS's connectivity checks that block URLSession/NWConnection
        webRequester.request(url: url) { [weak self] success in
            DispatchQueue.main.async {
                if success {
                    self?.statusText = "Ready"
                } else {
                    self?.statusText = "Error: Request failed"
                }
                completion?()
            }
        }
    }

    func track(angle: Int) {
        let clamped = max(Int(minAngle), min(Int(maxAngle), angle))
        currentAngle = Double(clamped)
        send(path: "/track?angle=\(clamped)")
    }

    func step(delta: Int) {
        let raw = currentAngle + Double(delta)
        let newAngle = max(minAngle, min(maxAngle, raw))
        currentAngle = newAngle
        send(path: "/step?delta=\(delta)")
    }

    func center() {
        currentAngle = 90
        send(path: "/center")
    }
}
