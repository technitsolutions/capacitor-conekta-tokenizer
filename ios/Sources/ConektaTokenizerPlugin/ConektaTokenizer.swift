import Foundation
import UIKit
import WebKit

public class ConektaTokenizer: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    public static let sdkReadyTimeout: TimeInterval = 15
    public static let tokenRequestTimeout: TimeInterval = 20

    /// 1×1 pt in the top-left corner, all but transparent and not interactive. Enough for WebKit
    /// to treat the page as visible, small enough to be imperceptible and never hit by a touch.
    static let hiddenFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
    static let hiddenAlpha: CGFloat = 0.01

    private var webView: WKWebView?
    /// View the hidden web view is parented to. Weak so the tokenizer, which lives as long as the
    /// plugin, never keeps a view controller's view alive.
    private weak var hostView: UIView?
    private var publicKey: String?
    private var sdkReady = false
    private var sdkReadyWaiters: [(Result<Void, Error>) -> Void] = []
    private var tokenCompletion: ((Result<[String: Any], Error>) -> Void)?
    private var sdkReadyTimeoutItem: DispatchWorkItem?
    private var tokenTimeoutItem: DispatchWorkItem?
    private var hasAttemptedReload = false

    private static let html = """
    <!DOCTYPE html>
    <html>
    <head>
    <script src="https://cdn.conekta.io/js/latest/conekta.js"></script>
    <script>
    window.addEventListener('load', function() {
        window.webkit.messageHandlers.conektaResult.postMessage(JSON.stringify({type:'ready'}));
    });
    function initConekta(publicKey) {
        try {
            if (typeof Conekta === 'undefined' || !Conekta) {
                window.webkit.messageHandlers.conektaResult.postMessage(JSON.stringify({
                    type:'token', success:false,
                    error: { message_to_purchaser: 'Conekta SDK not loaded', code: 'sdk_not_loaded' }
                }));
                return;
            }
            Conekta.setPublicKey(publicKey);
            Conekta.setLanguage('es');
        } catch (e) {
            window.webkit.messageHandlers.conektaResult.postMessage(JSON.stringify({
                type:'token', success:false,
                error: { message_to_purchaser: (e && e.message) || 'initConekta threw', code: 'js_exception' }
            }));
        }
    }
    function createToken(name, number, cvc, expMonth, expYear) {
        try {
            if (typeof Conekta === 'undefined' || !Conekta || !Conekta.Token) {
                window.webkit.messageHandlers.conektaResult.postMessage(JSON.stringify({
                    type:'token', success:false,
                    error: { message_to_purchaser: 'Conekta SDK not loaded', code: 'sdk_not_loaded' }
                }));
                return;
            }
            Conekta.Token.create({
                card: { name: name, number: number, cvc: cvc, exp_month: expMonth, exp_year: expYear }
            }, function(token) {
                window.webkit.messageHandlers.conektaResult.postMessage(JSON.stringify({type:'token', success:true, token:token}));
            }, function(error) {
                window.webkit.messageHandlers.conektaResult.postMessage(JSON.stringify({type:'token', success:false, error: error || {message_to_purchaser: 'Token creation failed'}}));
            });
        } catch (e) {
            window.webkit.messageHandlers.conektaResult.postMessage(JSON.stringify({
                type:'token', success:false,
                error: { message_to_purchaser: (e && e.message) || 'createToken threw', code: 'js_exception' }
            }));
        }
    }
    </script>
    </head>
    <body></body>
    </html>
    """

    /// - Parameter hostView: view to parent the hidden web view to, normally the Capacitor
    ///   bridge's view. Optional: when it is not available yet the key window is used instead.
    public func setup(hostView: UIView? = nil) {
        DispatchQueue.main.async {
            if let hostView = hostView {
                self.hostView = hostView
            }
            guard self.webView == nil else {
                self.attachIfNeeded()
                return
            }
            let config = WKWebViewConfiguration()
            config.userContentController.add(self, name: "conektaResult")
            let wv = WKWebView(frame: ConektaTokenizer.hiddenFrame, configuration: config)
            wv.navigationDelegate = self
            wv.alpha = ConektaTokenizer.hiddenAlpha
            wv.isUserInteractionEnabled = false
            wv.isOpaque = false
            wv.backgroundColor = .clear
            wv.accessibilityElementsHidden = true
            self.webView = wv
            self.attachIfNeeded()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.applicationDidBecomeActive),
                name: UIApplication.didBecomeActiveNotification,
                object: nil
            )
            wv.loadHTMLString(ConektaTokenizer.html, baseURL: URL(string: "https://conekta.com"))
        }
    }

    // MARK: - View hierarchy

    /// WebKit suspends the content process of a web view that is not in a window, and a suspended
    /// process stops answering `evaluateJavaScript` and `postMessage`. Tokenization then dies on
    /// the 20 s timeout with no error and nothing having run — the failure mode behind the
    /// `token_request_timeout` reports, all of them iOS. Keeping the view in the hierarchy is
    /// what keeps its process scheduled.
    private func attachIfNeeded() {
        guard let wv = webView, wv.window == nil else { return }
        guard let host = ConektaTokenizer.resolveHost(
            preferred: hostView,
            fallbackWindow: ConektaTokenizer.keyWindow()
        ) else { return }
        if wv.superview !== host {
            wv.removeFromSuperview()
            host.addSubview(wv)
        }
        wv.frame = ConektaTokenizer.hiddenFrame
    }

    /// Prefers the view the plugin handed us, but only once it is in a window — during launch the
    /// bridge's view is not yet, and parenting to it there would leave the process unscheduled.
    /// Falls back to the preferred view when there is no window at all, so the view is never left
    /// orphaned; the next `attachIfNeeded` re-runs this and moves it once a window exists.
    static func resolveHost(preferred: UIView?, fallbackWindow: UIWindow?) -> UIView? {
        if let preferred = preferred, preferred.window != nil {
            return preferred
        }
        return fallbackWindow ?? preferred
    }

    static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    /// The window can change while the app is backgrounded, and a content process killed under
    /// memory pressure only reports back once we are live again.
    @objc private func applicationDidBecomeActive() {
        attachIfNeeded()
    }

    public func setPublicKey(_ publicKey: String) {
        self.publicKey = publicKey
    }

    public func isReady() -> Bool {
        return sdkReady
    }

    public func warmUp(completion: @escaping (Result<Void, Error>) -> Void) {
        ensureReady(completion: completion)
    }

    private func ensureReady(completion: @escaping (Result<Void, Error>) -> Void) {
        if sdkReady {
            completion(.success(()))
            return
        }
        sdkReadyWaiters.append(completion)
        if webView == nil {
            setup()
        }
        if sdkReadyTimeoutItem == nil {
            let item = DispatchWorkItem { [weak self] in
                self?.flushReadyWaiters(with: .failure(ConektaError.sdkLoadTimeout))
            }
            sdkReadyTimeoutItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + ConektaTokenizer.sdkReadyTimeout, execute: item)
        }
    }

    private func flushReadyWaiters(with result: Result<Void, Error>) {
        sdkReadyTimeoutItem?.cancel()
        sdkReadyTimeoutItem = nil
        let waiters = sdkReadyWaiters
        sdkReadyWaiters.removeAll()
        for waiter in waiters {
            waiter(result)
        }
    }

    public func createToken(
        name: String,
        cardNumber: String,
        expMonth: String,
        expYear: String,
        cvc: String,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        guard let publicKey = self.publicKey else {
            completion(.failure(ConektaError.publicKeyNotSet))
            return
        }

        if tokenCompletion != nil {
            completion(.failure(ConektaError.requestInFlight))
            return
        }

        self.tokenCompletion = completion

        ensureReady { [weak self] readyResult in
            guard let self = self else { return }
            if case .failure(let error) = readyResult {
                self.finishToken(with: .failure(error))
                return
            }
            guard let webView = self.webView else {
                self.finishToken(with: .failure(ConektaError.webViewNotReady))
                return
            }

            DispatchQueue.main.async {
                let initJS = "initConekta(\(ConektaTokenizer.jsLiteral(publicKey))); 0"
                let tokenJS = "createToken("
                    + "\(ConektaTokenizer.jsLiteral(name)), "
                    + "\(ConektaTokenizer.jsLiteral(cardNumber)), "
                    + "\(ConektaTokenizer.jsLiteral(cvc)), "
                    + "\(ConektaTokenizer.jsLiteral(expMonth)), "
                    + "\(ConektaTokenizer.jsLiteral(expYear))); 0"

                // Last chance to get the page back into a window before we depend on it
                // answering: the window may have changed since the view was created.
                self.attachIfNeeded()
                self.armTokenTimeout()

                webView.evaluateJavaScript(initJS) { [weak self] _, error in
                    guard let self = self else { return }
                    if let error = error, ConektaTokenizer.isFatalEvaluationError(error) {
                        self.finishToken(with: .failure(ConektaError.evaluationFailed(underlying: error)))
                        return
                    }
                    webView.evaluateJavaScript(tokenJS) { [weak self] _, error in
                        guard let self = self else { return }
                        if let error = error, ConektaTokenizer.isFatalEvaluationError(error) {
                            self.finishToken(with: .failure(ConektaError.evaluationFailed(underlying: error)))
                        }
                    }
                }
            }
        }
    }

    // MARK: - JS evaluation helpers

    /// Encodes a value as a fully escaped JS string literal so a cardholder name containing
    /// a quote, a backslash or a line break cannot break the script we evaluate. Manual
    /// quote-escaping only covered `'`, which left `\` and newlines able to produce a syntax
    /// error instead of a token.
    static func jsLiteral(_ value: String) -> String {
        // Wrapped in an array because top-level string fragments need `.fragmentsAllowed`.
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let json = String(data: data, encoding: .utf8),
              json.count > 2 else {
            return "\"\""
        }
        return String(json.dropFirst().dropLast())
            // Legal in JSON, but line terminators inside a JS string literal predate ES2019.
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// `WKErrorJavaScriptResultTypeIsUnsupported` means the script *ran* and only its completion
    /// value could not be bridged back to native. That value is never used — tokenization results
    /// arrive asynchronously over the `conektaResult` message handler — so failing the call here
    /// would abort a request that is still in flight and drop the token that lands moments later.
    /// Every other evaluation error means the script did not run, so those still fail fast.
    static func isFatalEvaluationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == WKError.errorDomain else { return true }
        return nsError.code != WKError.javaScriptResultTypeIsUnsupported.rawValue
    }

    private func armTokenTimeout() {
        tokenTimeoutItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.finishToken(with: .failure(ConektaError.tokenRequestTimeout))
        }
        tokenTimeoutItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + ConektaTokenizer.tokenRequestTimeout, execute: item)
    }

    private func finishToken(with result: Result<[String: Any], Error>) {
        tokenTimeoutItem?.cancel()
        tokenTimeoutItem = nil
        let completion = tokenCompletion
        tokenCompletion = nil
        completion?(result)
    }

    // MARK: - WKScriptMessageHandler

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? String,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "ready":
            sdkReady = true
            flushReadyWaiters(with: .success(()))
        case "token":
            let success = json["success"] as? Bool ?? false
            if success, let tokenObj = json["token"] as? [String: Any] {
                finishToken(with: .success(tokenObj))
            } else {
                let raw: [String: Any]
                if let dict = json["error"] as? [String: Any] {
                    raw = dict
                } else if let str = json["error"] as? String {
                    raw = ["message_to_purchaser": str]
                } else {
                    raw = [:]
                }
                let message = (raw["message_to_purchaser"] as? String)
                    ?? (raw["message"] as? String)
                    ?? "Token creation failed"
                finishToken(with: .failure(ConektaError.apiError(
                    message: message,
                    code: raw["code"] as? String,
                    type: raw["type"] as? String,
                    param: raw["param"] as? String,
                    raw: raw
                )))
            }
        default:
            break
        }
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(error: error)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(error: error)
    }

    /// The page died with its process, so nothing will ever answer a request that is in flight —
    /// without this the call would sit on the spinner for the full 20 s timeout. Reload so the
    /// next attempt finds a live page, and fail the current one now with a code that says why.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        sdkReady = false
        hasAttemptedReload = false
        attachIfNeeded()
        webView.loadHTMLString(ConektaTokenizer.html, baseURL: URL(string: "https://conekta.com"))
        finishToken(with: .failure(ConektaError.webContentProcessTerminated))
    }

    private func handleNavigationFailure(error: Error) {
        if !hasAttemptedReload, let wv = webView {
            hasAttemptedReload = true
            wv.loadHTMLString(ConektaTokenizer.html, baseURL: URL(string: "https://conekta.com"))
            return
        }
        flushReadyWaiters(with: .failure(ConektaError.webViewNotReady))
        finishToken(with: .failure(ConektaError.webViewNotReady))
    }
}

enum ConektaError: LocalizedError {
    case publicKeyNotSet
    case webViewNotReady
    case sdkLoadTimeout
    case tokenRequestTimeout
    case requestInFlight
    case webContentProcessTerminated
    case evaluationFailed(underlying: Error)
    case apiError(message: String, code: String?, type: String?, param: String?, raw: [String: Any])

    var errorDescription: String? {
        switch self {
        case .publicKeyNotSet:
            return "Public key not set. Call setPublicKey() before createToken()."
        case .webViewNotReady:
            return "Conekta WebView is not ready."
        case .sdkLoadTimeout:
            return "Conekta SDK did not load in time."
        case .tokenRequestTimeout:
            return "Conekta token request timed out."
        case .requestInFlight:
            return "A Conekta token request is already in flight."
        case .webContentProcessTerminated:
            return "The Conekta WebView was terminated by the system."
        case .evaluationFailed:
            return "Could not run the Conekta tokenization script."
        case .apiError(let message, _, _, _, _):
            return message
        }
    }

    var code: String? {
        switch self {
        case .publicKeyNotSet: return "public_key_not_set"
        case .webViewNotReady: return "webview_not_ready"
        case .sdkLoadTimeout: return "sdk_load_timeout"
        case .tokenRequestTimeout: return "token_request_timeout"
        case .requestInFlight: return "request_in_flight"
        case .webContentProcessTerminated: return "webview_process_terminated"
        case .evaluationFailed: return "webview_eval_failed"
        case .apiError(_, let code, _, _, _): return code
        }
    }
}
