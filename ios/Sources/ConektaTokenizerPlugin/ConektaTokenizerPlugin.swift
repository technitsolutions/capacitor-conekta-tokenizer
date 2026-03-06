import Foundation
import Capacitor

@objc(ConektaTokenizerPlugin)
public class ConektaTokenizerPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "ConektaTokenizerPlugin"
    public let jsName = "ConektaTokenizer"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "setPublicKey", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "createToken", returnType: CAPPluginReturnPromise)
    ]

    private let implementation = ConektaTokenizer()

    override public func load() {
        implementation.setup()
    }

    @objc func setPublicKey(_ call: CAPPluginCall) {
        guard let publicKey = call.getString("publicKey") else {
            call.reject("publicKey is required")
            return
        }
        implementation.setPublicKey(publicKey)
        call.resolve()
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
                call.reject(error.localizedDescription)
            }
        }
    }
}
