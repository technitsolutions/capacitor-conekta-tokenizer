import Foundation

public class ConektaTokenizer {
    private static let apiBase = "https://api.conekta.io"
    private var publicKey: String?

    public func setPublicKey(_ publicKey: String) {
        self.publicKey = publicKey
    }

    public func createToken(
        name: String,
        cardNumber: String,
        expMonth: String,
        expYear: String,
        cvc: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let publicKey = self.publicKey else {
            completion(.failure(ConektaError.publicKeyNotSet))
            return
        }

        guard let url = URL(string: "\(ConektaTokenizer.apiBase)/tokens") else {
            completion(.failure(ConektaError.invalidURL))
            return
        }

        let body: [String: Any] = [
            "card": [
                "number": cardNumber,
                "name": name,
                "cvc": cvc,
                "exp_month": expMonth,
                "exp_year": expYear
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.failure(ConektaError.serializationFailed))
            return
        }

        let credentials = "\(publicKey):"
        guard let credentialData = credentials.data(using: .utf8) else {
            completion(.failure(ConektaError.serializationFailed))
            return
        }
        let base64Credentials = credentialData.base64EncodedString()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.conekta-v2.2.0+json", forHTTPHeaderField: "Accept")
        request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(ConektaError.emptyResponse))
                return
            }

            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(.failure(ConektaError.invalidResponse))
                    return
                }

                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                    let message = (json["details"] as? [[String: Any]])?.first?["message"] as? String
                        ?? json["message"] as? String
                        ?? "Conekta API error: \(httpResponse.statusCode)"
                    completion(.failure(ConektaError.apiError(message)))
                    return
                }

                guard let tokenId = json["id"] as? String else {
                    completion(.failure(ConektaError.invalidResponse))
                    return
                }

                completion(.success(tokenId))
            } catch {
                completion(.failure(error))
            }
        }

        task.resume()
    }
}

enum ConektaError: LocalizedError {
    case publicKeyNotSet
    case invalidURL
    case serializationFailed
    case emptyResponse
    case invalidResponse
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .publicKeyNotSet:
            return "Public key not set. Call setPublicKey() before createToken()."
        case .invalidURL:
            return "Invalid Conekta API URL."
        case .serializationFailed:
            return "Failed to serialize request data."
        case .emptyResponse:
            return "Empty response from Conekta API."
        case .invalidResponse:
            return "Invalid response from Conekta API."
        case .apiError(let message):
            return message
        }
    }
}
