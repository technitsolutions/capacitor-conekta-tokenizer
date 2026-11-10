import Foundation

/// Lifecycle of the hidden page that hosts `conekta.js`, kept apart from WebKit so the
/// reload rules can be unit-tested. The tokenizer feeds it events and carries out the action
/// each one returns.
///
/// Why it exists: the page's `load` event fires even when `conekta.js` itself failed to load
/// (offline at app start, a slow network, a CDN hiccup). Treating `load` as "ready" left the
/// tokenizer ready forever with `Conekta` undefined, so every attempt failed instantly with
/// `sdk_not_loaded` until the app was killed. Now the page reports `not_loaded` in that case,
/// and the next attempt reloads it so it can recover once the network is back.
struct SdkLoadState: Equatable {
    enum Phase: Equatable {
        /// A page load is in progress; waiters keep waiting.
        case loading
        /// `conekta.js` loaded and `Conekta` is defined.
        case ready
        /// The page loaded but `Conekta` is undefined. The next `ensureReady` reloads.
        case notLoaded
        /// The page itself could not be loaded or never answered in time. The next
        /// `ensureReady` reloads.
        case failed
    }

    enum Action: Equatable {
        case none
        case reload
        case succeedWaiters
        case failWaiters(code: String)
    }

    private(set) var phase: Phase = .loading
    /// One automatic reload per attempt. Reset once the SDK is ready so a later failure can
    /// reload again.
    private(set) var hasAttemptedReload = false

    var isReady: Bool { phase == .ready }

    /// The page posted `ready`: `Conekta` is defined.
    mutating func onReady() -> Action {
        phase = .ready
        hasAttemptedReload = false
        return .succeedWaiters
    }

    /// The page loaded without `Conekta` (or a token request found it missing). With someone
    /// waiting, reload once right away; if that reload also comes back without the SDK, fail
    /// them now with `sdk_not_loaded` instead of letting them sit until the load timeout.
    mutating func onNotLoaded(hasWaiters: Bool) -> Action {
        if hasWaiters && !hasAttemptedReload {
            hasAttemptedReload = true
            phase = .loading
            return .reload
        }
        phase = .notLoaded
        return hasWaiters ? .failWaiters(code: "sdk_not_loaded") : .none
    }

    /// The main-frame navigation failed.
    mutating func onNavigationFailure() -> Action {
        if !hasAttemptedReload {
            hasAttemptedReload = true
            phase = .loading
            return .reload
        }
        phase = .failed
        return .failWaiters(code: "webview_not_ready")
    }

    /// Someone needs the SDK (`warmUp` or `createToken`); called after they were queued.
    /// A page that loaded without the SDK, or failed, gets a fresh load: this is what lets
    /// the tokenizer recover once the network is back, without restarting the app.
    mutating func onEnsureReady() -> Action {
        switch phase {
        case .ready:
            return .succeedWaiters
        case .loading:
            return .none
        case .notLoaded, .failed:
            // This load is the attempt's one reload: if it also misses the SDK, fail fast.
            hasAttemptedReload = true
            phase = .loading
            return .reload
        }
    }

    /// The ready wait timed out. A load still pending by now is treated as failed so the
    /// next attempt starts a new one rather than waiting on it forever.
    mutating func onReadyTimeout() {
        if phase == .loading {
            phase = .failed
        }
    }

    /// The content process died with the page; start over.
    mutating func onProcessTerminated() -> Action {
        phase = .loading
        hasAttemptedReload = false
        return .reload
    }
}
