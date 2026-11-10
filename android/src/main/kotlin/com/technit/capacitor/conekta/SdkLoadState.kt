package com.technit.capacitor.conekta

/**
 * Lifecycle of the hidden page that hosts `conekta.js`, kept apart from the WebView so the
 * reload rules can be unit-tested. The tokenizer feeds it events and carries out the action
 * each one returns. Mirrors `SdkLoadState.swift`.
 *
 * Why it exists: the page's `load` event fires even when `conekta.js` itself failed to load
 * (offline at app start, a slow network, a CDN hiccup). Treating `load` as "ready" left the
 * tokenizer ready forever with `Conekta` undefined, so every attempt failed instantly with
 * `sdk_not_loaded` until the app was killed. Now the page reports `not_loaded` in that case,
 * and the next attempt reloads it so it can recover once the network is back.
 */
class SdkLoadState {
    enum class Phase {
        /** A page load is in progress; waiters keep waiting. */
        LOADING,
        /** `conekta.js` loaded and `Conekta` is defined. */
        READY,
        /** The page loaded but `Conekta` is undefined. The next `onEnsureReady` reloads. */
        NOT_LOADED,
        /** The page could not be loaded or never answered in time. The next `onEnsureReady` reloads. */
        FAILED,
    }

    sealed class Action {
        object None : Action()
        object Reload : Action()
        object SucceedWaiters : Action()
        data class FailWaiters(val code: String) : Action()
    }

    var phase: Phase = Phase.LOADING
        private set

    /** One automatic reload per attempt; reset once the SDK is ready. */
    var hasAttemptedReload: Boolean = false
        private set

    val isReady: Boolean get() = phase == Phase.READY

    /** The page posted `ready`: `Conekta` is defined. */
    fun onReady(): Action {
        phase = Phase.READY
        hasAttemptedReload = false
        return Action.SucceedWaiters
    }

    /**
     * The page loaded without `Conekta` (or a token request found it missing). With someone
     * waiting, reload once right away; if that reload also comes back without the SDK, fail
     * them now with `sdk_not_loaded` instead of letting them sit until the load timeout.
     */
    fun onNotLoaded(hasWaiters: Boolean): Action {
        if (hasWaiters && !hasAttemptedReload) {
            hasAttemptedReload = true
            phase = Phase.LOADING
            return Action.Reload
        }
        phase = Phase.NOT_LOADED
        return if (hasWaiters) Action.FailWaiters(SDK_NOT_LOADED) else Action.None
    }

    /** The main-frame navigation failed. */
    fun onNavigationFailure(): Action {
        if (!hasAttemptedReload) {
            hasAttemptedReload = true
            phase = Phase.LOADING
            return Action.Reload
        }
        phase = Phase.FAILED
        return Action.FailWaiters(WEBVIEW_NOT_READY)
    }

    /**
     * Someone needs the SDK (`warmUp` or `createToken`); called after they were queued. A page
     * that loaded without the SDK, or failed, gets a fresh load: this is what lets the
     * tokenizer recover once the network is back, without restarting the app.
     */
    fun onEnsureReady(): Action = when (phase) {
        Phase.READY -> Action.SucceedWaiters
        Phase.LOADING -> Action.None
        Phase.NOT_LOADED, Phase.FAILED -> {
            // This load is the attempt's one reload: if it also misses the SDK, fail fast.
            hasAttemptedReload = true
            phase = Phase.LOADING
            Action.Reload
        }
    }

    /**
     * The ready wait timed out. A load still pending by now is treated as failed so the next
     * attempt starts a new one rather than waiting on it forever.
     */
    fun onReadyTimeout() {
        if (phase == Phase.LOADING) phase = Phase.FAILED
    }

    companion object {
        const val SDK_NOT_LOADED = "sdk_not_loaded"
        const val WEBVIEW_NOT_READY = "webview_not_ready"
    }
}
