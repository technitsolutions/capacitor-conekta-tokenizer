import XCTest
@testable import ConektaTokenizerPlugin

class ConektaTokenizerTests: XCTestCase {
    func testSetPublicKey() {
        let tokenizer = ConektaTokenizer()
        tokenizer.setPublicKey("key_test_123")
        // No assertion needed — just verifying it doesn't throw
    }
}
