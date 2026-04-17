import Foundation
import WebKit

public class ConektaTokenizer: NSObject, WKScriptMessageHandler {
    private var webView: WKWebView?
    private var publicKey: String?
    private var sdkReady = false
    private var sdkReadyCompletion: (() -> Void)?
    private var tokenCompletion: ((Result<[String: Any], Error>) -> Void)?

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
        Conekta.setPublicKey(publicKey);
        Conekta.setLanguage('es');
    }
    function createToken(name, number, cvc, expMonth, expYear) {
        Conekta.Token.create({
            card: { name: name, number: number, cvc: cvc, exp_month: expMonth, exp_year: expYear }
        }, function(token) {
            window.webkit.messageHandlers.conektaResult.postMessage(JSON.stringify({type:'token', success:true, token:token}));
        }, function(error) {
            window.webkit.messageHandlers.conektaResult.postMessage(JSON.stringify({type:'token', success:false, error: error || {message_to_purchaser: 'Token creation failed'}}));
        });
    }
    </script>
    </head>
    <body></body>
    </html>
    """

    public func setup() {
        DispatchQueue.main.async {
            let config = WKWebViewConfiguration()
            config.userContentController.add(self, name: "conektaResult")
            let wv = WKWebView(frame: .zero, configuration: config)
            self.webView = wv
            wv.loadHTMLString(ConektaTokenizer.html, baseURL: URL(string: "https://conekta.com"))
        }
    }

    public func setPublicKey(_ publicKey: String) {
        self.publicKey = publicKey
    }

    private func ensureReady(completion: @escaping () -> Void) {
        if sdkReady {
            completion()
            return
        }
        sdkReadyCompletion = completion
        if webView == nil {
            setup()
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

        self.tokenCompletion = completion

        ensureReady { [weak self] in
            guard let self = self, let webView = self.webView else {
                completion(.failure(ConektaError.webViewNotReady))
                return
            }

            DispatchQueue.main.async {
                let initJS = "initConekta('\(publicKey.replacingOccurrences(of: "'", with: "\\'"))'); 0"
                let tokenJS = "createToken('\(name.replacingOccurrences(of: "'", with: "\\'"))', '\(cardNumber)', '\(cvc)', '\(expMonth)', '\(expYear)'); 0"

                webView.evaluateJavaScript(initJS) { _, error in
                    if let error = error {
                        completion(.failure(error))
                        return
                    }
                    webView.evaluateJavaScript(tokenJS) { _, error in
                        if let error = error {
                            completion(.failure(error))
                        }
                        // Result comes via WKScriptMessageHandler
                    }
                }
            }
        }
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
            sdkReadyCompletion?()
            sdkReadyCompletion = nil
        case "token":
            let success = json["success"] as? Bool ?? false
            if success, let tokenObj = json["token"] as? [String: Any] {
                tokenCompletion?(.success(tokenObj))
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
                tokenCompletion?(.failure(ConektaError.apiError(
                    message: message,
                    code: raw["code"] as? String,
                    type: raw["type"] as? String,
                    param: raw["param"] as? String,
                    raw: raw
                )))
            }
            tokenCompletion = nil
        default:
            break
        }
    }
}

enum ConektaError: LocalizedError {
    case publicKeyNotSet
    case webViewNotReady
    case apiError(message: String, code: String?, type: String?, param: String?, raw: [String: Any])

    var errorDescription: String? {
        switch self {
        case .publicKeyNotSet:
            return "Public key not set. Call setPublicKey() before createToken()."
        case .webViewNotReady:
            return "Conekta WebView is not ready."
        case .apiError(let message, _, _, _, _):
            return message
        }
    }
}
