import Foundation
import Capacitor

@objc(ConektaTokenizerPlugin)
public class ConektaTokenizerPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "ConektaTokenizerPlugin"
    public let jsName = "ConektaTokenizer"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "setPublicKey", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "createToken", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "warmUp", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "isReady", returnType: CAPPluginReturnPromise)
    ]

    private let implementation = ConektaTokenizer()

    override public func load() {
        // The hidden web view has to live in the app's view hierarchy or WebKit suspends its
        // content process and tokenization hangs; give it the bridge's view to parent to.
        implementation.setup(hostView: bridge?.viewController?.view)
    }

    @objc func setPublicKey(_ call: CAPPluginCall) {
        guard let publicKey = call.getString("publicKey") else {
            call.reject("publicKey is required")
            return
        }
        implementation.setPublicKey(publicKey)
        call.resolve()
    }

    @objc func isReady(_ call: CAPPluginCall) {
        call.resolve(["ready": implementation.isReady()])
    }

    @objc func warmUp(_ call: CAPPluginCall) {
        implementation.warmUp { result in
            switch result {
            case .success:
                call.resolve(["ready": true])
            case .failure(let error):
                self.rejectWithConektaError(call: call, error: error)
            }
        }
    }

    @objc func createToken(_ call: CAPPluginCall) {
        guard let name = call.getString("name"),
              let cardNumber = call.getString("cardNumber"),
              let expMonth = call.getString("expMonth"),
              let expYear = call.getString("expYear"),
              let cvc = call.getString("cvc") else {
            call.reject("All card fields are required: name, cardNumber, expMonth, expYear, cvc")
            return
        }

        implementation.createToken(
            name: name,
            cardNumber: cardNumber,
            expMonth: expMonth,
            expYear: expYear,
            cvc: cvc
        ) { result in
            switch result {
            case .success(let tokenObj):
                call.resolve(["token": tokenObj])
            case .failure(let error):
                self.rejectWithConektaError(call: call, error: error)
            }
        }
    }

    private func rejectWithConektaError(call: CAPPluginCall, error: Error) {
        if case let ConektaError.apiError(message, code, type, param, raw) = error {
            var data: [String: Any] = ["conektaError": raw]
            if let type = type { data["type"] = type }
            if let param = param { data["param"] = param }
            call.reject(message, code, error, data)
            return
        }
        if let conektaError = error as? ConektaError, case let .evaluationFailed(underlying) = conektaError {
            // Keep the WebKit specifics in `data` for crash reporting — the message stays a
            // stable, translatable sentence instead of a raw `NSError.localizedDescription`.
            let nsError = underlying as NSError
            call.reject(
                conektaError.errorDescription ?? "Conekta error",
                conektaError.code,
                underlying,
                [
                    "underlyingDomain": nsError.domain,
                    "underlyingCode": nsError.code,
                    "underlyingMessage": nsError.localizedDescription
                ]
            )
            return
        }
        if let conektaError = error as? ConektaError {
            call.reject(conektaError.errorDescription ?? "Conekta error", conektaError.code, error)
            return
        }
        // Never reject without a code: a `nil` code reaches crash reporting as "unknown".
        call.reject(error.localizedDescription, "unexpected_error", error)
    }
}
