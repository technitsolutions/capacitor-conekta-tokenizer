import XCTest
@testable import ConektaTokenizerPlugin

class ConektaTokenizerTests: XCTestCase {
    func testSetPublicKey() {
        let tokenizer = ConektaTokenizer()
        tokenizer.setPublicKey("key_test_123")
    }

    func testCreateTokenWithoutPublicKeyRejects() {
        let tokenizer = ConektaTokenizer()
        let expectation = self.expectation(description: "createToken rejects without public key")
        tokenizer.createToken(
            name: "Test",
            cardNumber: "4242424242424242",
            expMonth: "12",
            expYear: "30",
            cvc: "123"
        ) { result in
            if case .failure(let error) = result,
               case ConektaError.publicKeyNotSet = error {
                expectation.fulfill()
            } else {
                XCTFail("expected publicKeyNotSet failure")
            }
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testSecondCreateTokenWhileInFlightRejects() {
        let tokenizer = ConektaTokenizer()
        tokenizer.setPublicKey("key_test_123")

        let first = self.expectation(description: "first in flight")
        first.isInverted = true
        tokenizer.createToken(
            name: "A", cardNumber: "4242", expMonth: "12", expYear: "30", cvc: "123"
        ) { _ in first.fulfill() }

        let second = self.expectation(description: "second rejects as requestInFlight")
        tokenizer.createToken(
            name: "B", cardNumber: "4242", expMonth: "12", expYear: "30", cvc: "123"
        ) { result in
            if case .failure(let error) = result,
               case ConektaError.requestInFlight = error {
                second.fulfill()
            } else {
                XCTFail("expected requestInFlight failure, got \(result)")
            }
        }

        wait(for: [second], timeout: 1.0)
        wait(for: [first], timeout: 0.1)
    }

    func testConektaErrorCodes() {
        XCTAssertEqual(ConektaError.sdkLoadTimeout.code, "sdk_load_timeout")
        XCTAssertEqual(ConektaError.tokenRequestTimeout.code, "token_request_timeout")
        XCTAssertEqual(ConektaError.requestInFlight.code, "request_in_flight")
        XCTAssertEqual(ConektaError.webViewNotReady.code, "webview_not_ready")
        XCTAssertEqual(ConektaError.publicKeyNotSet.code, "public_key_not_set")
    }

    func testIsReadyDefaultsFalse() {
        let tokenizer = ConektaTokenizer()
        XCTAssertFalse(tokenizer.isReady())
    }
}
