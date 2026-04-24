import Foundation
import WebKit

public class ConektaTokenizer: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    public static let sdkReadyTimeout: TimeInterval = 15
    public static let tokenRequestTimeout: TimeInterval = 20

    private var webView: WKWebView?
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

    public func setup() {
        DispatchQueue.main.async {
            guard self.webView == nil else { return }
            let config = WKWebViewConfiguration()
            config.userContentController.add(self, name: "conektaResult")
            let wv = WKWebView(frame: .zero, configuration: config)
            wv.navigationDelegate = self
            self.webView = wv
            wv.loadHTMLString(ConektaTokenizer.html, baseURL: URL(string: "https://conekta.com"))
        }
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
                let initJS = "initConekta('\(publicKey.replacingOccurrences(of: "'", with: "\\'"))'); 0"
                let tokenJS = "createToken('\(name.replacingOccurrences(of: "'", with: "\\'"))', '\(cardNumber)', '\(cvc)', '\(expMonth)', '\(expYear)'); 0"

                self.armTokenTimeout()

                webView.evaluateJavaScript(initJS) { [weak self] _, error in
                    guard let self = self else { return }
                    if let error = error {
                        self.finishToken(with: .failure(error))
                        return
                    }
                    webView.evaluateJavaScript(tokenJS) { [weak self] _, error in
                        guard let self = self else { return }
                        if let error = error {
                            self.finishToken(with: .failure(error))
                        }
                    }
                }
            }
        }
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
        case .apiError(_, let code, _, _, _): return code
        }
    }
}
