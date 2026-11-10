import UIKit
import WebKit
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
        XCTAssertEqual(ConektaError.tokenRequestTimeout(requestSent: false).code, "token_request_timeout")
        XCTAssertEqual(ConektaError.tokenRequestTimeout(requestSent: true).code, "token_request_timeout")
        XCTAssertEqual(ConektaError.sdkNotLoaded.code, "sdk_not_loaded")
        XCTAssertEqual(ConektaError.requestInFlight.code, "request_in_flight")
        XCTAssertEqual(ConektaError.webViewNotReady.code, "webview_not_ready")
        XCTAssertEqual(ConektaError.publicKeyNotSet.code, "public_key_not_set")
        XCTAssertEqual(
            ConektaError.evaluationFailed(underlying: NSError(domain: "test", code: 0)).code,
            "webview_eval_failed"
        )
    }

    func testUnsupportedResultTypeIsNotFatal() {
        let error = NSError(
            domain: WKError.errorDomain,
            code: WKError.javaScriptResultTypeIsUnsupported.rawValue
        )
        XCTAssertFalse(ConektaTokenizer.isFatalEvaluationError(error))
    }

    func testOtherEvaluationErrorsAreFatal() {
        let jsException = NSError(
            domain: WKError.errorDomain,
            code: WKError.javaScriptExceptionOccurred.rawValue
        )
        XCTAssertTrue(ConektaTokenizer.isFatalEvaluationError(jsException))

        let processGone = NSError(
            domain: WKError.errorDomain,
            code: WKError.webContentProcessTerminated.rawValue
        )
        XCTAssertTrue(ConektaTokenizer.isFatalEvaluationError(processGone))

        // Same numeric code in a different domain must not be mistaken for the WebKit one.
        let unrelated = NSError(
            domain: NSURLErrorDomain,
            code: WKError.javaScriptResultTypeIsUnsupported.rawValue
        )
        XCTAssertTrue(ConektaTokenizer.isFatalEvaluationError(unrelated))
    }

    func testJSLiteralEscapesQuotesBackslashesAndNewlines() {
        XCTAssertEqual(ConektaTokenizer.jsLiteral("O'Brien"), "\"O'Brien\"")
        XCTAssertEqual(ConektaTokenizer.jsLiteral("a\"b"), "\"a\\\"b\"")
        XCTAssertEqual(ConektaTokenizer.jsLiteral("a\\b"), "\"a\\\\b\"")
        XCTAssertEqual(ConektaTokenizer.jsLiteral("a\nb"), "\"a\\nb\"")
        XCTAssertEqual(ConektaTokenizer.jsLiteral("a\u{2028}b"), "\"a\\u2028b\"")
        XCTAssertEqual(ConektaTokenizer.jsLiteral(""), "\"\"")
    }

    func testIsReadyDefaultsFalse() {
        let tokenizer = ConektaTokenizer()
        XCTAssertFalse(tokenizer.isReady())
    }

    func testSetupAttachesHiddenWebViewToHostView() {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.makeKeyAndVisible()
        let host = UIView(frame: window.bounds)
        window.addSubview(host)

        let tokenizer = ConektaTokenizer()
        tokenizer.setup(hostView: host)

        let attached = expectation(description: "web view is parented to the host view")
        // `setup` hops to the main queue, so assert after it has run.
        DispatchQueue.main.async {
            guard let wv = host.subviews.first(where: { $0 is WKWebView }) else {
                XCTFail("expected the hidden web view to be a subview of the host")
                return
            }
            XCTAssertNotNil(wv.window, "a web view outside a window gets its process suspended")
            XCTAssertFalse(wv.isHidden, "a hidden view counts as not visible to WebKit")
            XCTAssertFalse(wv.isUserInteractionEnabled)
            XCTAssertEqual(wv.frame, ConektaTokenizer.hiddenFrame)
            XCTAssertEqual(wv.alpha, ConektaTokenizer.hiddenAlpha, accuracy: 0.0001)
            attached.fulfill()
        }
        wait(for: [attached], timeout: 1.0)
    }

    func testResolveHostPrefersAWindowOverAnOffscreenHost() {
        let window = UIWindow(frame: UIScreen.main.bounds)

        // A view controller's view during `load()`: built, but not in a window yet. Parenting to
        // it there would leave the content process unscheduled.
        let detached = UIView(frame: .zero)
        XCTAssertTrue(
            ConektaTokenizer.resolveHost(preferred: detached, fallbackWindow: window) === window
        )

        window.addSubview(detached)
        XCTAssertTrue(
            ConektaTokenizer.resolveHost(preferred: detached, fallbackWindow: window) === detached
        )
    }

    func testResolveHostKeepsTheOffscreenHostWhenThereIsNoWindowYet() {
        let detached = UIView(frame: .zero)
        XCTAssertTrue(
            ConektaTokenizer.resolveHost(preferred: detached, fallbackWindow: nil) === detached,
            "the web view must not be left orphaned; a later attach moves it into a window"
        )
        XCTAssertNil(ConektaTokenizer.resolveHost(preferred: nil, fallbackWindow: nil))
    }

    func testWebContentProcessTerminationCode() {
        XCTAssertEqual(
            ConektaError.webContentProcessTerminated.code,
            "webview_process_terminated"
        )
    }

    // MARK: - SDK load recovery (`load` fired but `Conekta` undefined)

    func testLoadStateReadyOnlyAfterReadyMessage() {
        var state = SdkLoadState()
        XCTAssertFalse(state.isReady)
        XCTAssertEqual(state.onReady(), .succeedWaiters)
        XCTAssertTrue(state.isReady)
    }

    func testLoadStateNotLoadedWithoutWaitersWaitsForNextAttempt() {
        var state = SdkLoadState()
        XCTAssertEqual(state.onNotLoaded(hasWaiters: false), .none)
        XCTAssertEqual(state.phase, .notLoaded)
        XCTAssertFalse(state.isReady)
        // The next warmUp/createToken reloads the page.
        XCTAssertEqual(state.onEnsureReady(), .reload)
        XCTAssertEqual(state.phase, .loading)
        // While that load is in progress, further callers just wait.
        XCTAssertEqual(state.onEnsureReady(), .none)
    }

    func testLoadStateReloadsOnceThenFailsFastWithSdkNotLoaded() {
        var state = SdkLoadState()
        XCTAssertEqual(state.onNotLoaded(hasWaiters: true), .reload)
        XCTAssertEqual(state.onNotLoaded(hasWaiters: true), .failWaiters(code: "sdk_not_loaded"))
        XCTAssertEqual(state.phase, .notLoaded)
        // A later attempt still gets a fresh load.
        XCTAssertEqual(state.onEnsureReady(), .reload)
        XCTAssertEqual(state.onReady(), .succeedWaiters)
        // Once ready, a later miss is allowed its own reload again.
        XCTAssertEqual(state.onNotLoaded(hasWaiters: true), .reload)
    }

    func testLoadStateTimeoutMakesNextAttemptReload() {
        var state = SdkLoadState()
        state.onReadyTimeout()
        XCTAssertEqual(state.phase, .failed)
        XCTAssertEqual(state.onEnsureReady(), .reload)
        // A timeout after ready changes nothing.
        _ = state.onReady()
        state.onReadyTimeout()
        XCTAssertTrue(state.isReady)
    }

    func testLoadStateNavigationFailureReloadsOnceThenFails() {
        var state = SdkLoadState()
        XCTAssertEqual(state.onNavigationFailure(), .reload)
        XCTAssertEqual(state.onNavigationFailure(), .failWaiters(code: "webview_not_ready"))
        XCTAssertEqual(state.onEnsureReady(), .reload)
    }

    func testLoadFiredWithoutConektaIsNotReadyAndNextWarmUpReloadsAndRecovers() {
        let tokenizer = ConektaTokenizer()
        tokenizer.pageLoaderOverride = {}

        // App start offline: the page loads but conekta.js does not.
        tokenizer.handleMessage(#"{"type":"not_loaded"}"#)
        XCTAssertFalse(tokenizer.isReady(), "a page without Conekta must not count as ready")
        XCTAssertEqual(tokenizer.pageLoadCount, 0)

        // Network is back; the user opens the payment screen.
        var result: Result<Void, Error>?
        tokenizer.warmUp { result = $0 }
        XCTAssertEqual(tokenizer.pageLoadCount, 1, "warmUp must reload a page that loaded without the SDK")
        XCTAssertNil(result, "waits for the reloaded page")

        tokenizer.handleMessage(#"{"type":"ready"}"#)
        guard case .success = result else {
            return XCTFail("expected warmUp to succeed after the reload, got \(String(describing: result))")
        }
        XCTAssertTrue(tokenizer.isReady())
    }

    func testReloadThatStillMissesConektaFailsWithSdkNotLoaded() {
        let tokenizer = ConektaTokenizer()
        tokenizer.pageLoaderOverride = {}

        var result: Result<Void, Error>?
        tokenizer.warmUp { result = $0 }
        XCTAssertEqual(tokenizer.pageLoadCount, 0, "the first load is still in progress")

        tokenizer.handleMessage(#"{"type":"not_loaded"}"#)
        XCTAssertEqual(tokenizer.pageLoadCount, 1, "one automatic reload")
        XCTAssertNil(result)

        tokenizer.handleMessage(#"{"type":"not_loaded"}"#)
        guard case .failure(let error) = result, case ConektaError.sdkNotLoaded = error else {
            return XCTFail("expected sdkNotLoaded, got \(String(describing: result))")
        }
        XCTAssertEqual(tokenizer.pageLoadCount, 1, "fails fast instead of reloading in a loop")
        XCTAssertFalse(tokenizer.isReady())
    }
}
