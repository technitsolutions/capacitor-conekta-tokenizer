package com.technit.capacitor.conekta

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** `load` fired but `Conekta` undefined → not ready → the next attempt reloads and recovers. */
class SdkLoadStateTest {
    @Test
    fun readyOnlyAfterReadyMessage() {
        val state = SdkLoadState()
        assertFalse(state.isReady)
        assertEquals(SdkLoadState.Action.SucceedWaiters, state.onReady())
        assertTrue(state.isReady)
    }

    @Test
    fun notLoadedWithoutWaitersWaitsForNextAttemptThenRecovers() {
        val state = SdkLoadState()
        // App start offline: the page loads but conekta.js does not.
        assertEquals(SdkLoadState.Action.None, state.onNotLoaded(hasWaiters = false))
        assertEquals(SdkLoadState.Phase.NOT_LOADED, state.phase)
        assertFalse(state.isReady)
        // Network is back; warmUp/createToken reloads the page.
        assertEquals(SdkLoadState.Action.Reload, state.onEnsureReady())
        assertEquals(SdkLoadState.Phase.LOADING, state.phase)
        // While that load is in progress, further callers just wait.
        assertEquals(SdkLoadState.Action.None, state.onEnsureReady())
        assertEquals(SdkLoadState.Action.SucceedWaiters, state.onReady())
        assertTrue(state.isReady)
    }

    @Test
    fun reloadsOnceThenFailsFastWithSdkNotLoaded() {
        val state = SdkLoadState()
        assertEquals(SdkLoadState.Action.Reload, state.onNotLoaded(hasWaiters = true))
        assertEquals(
            SdkLoadState.Action.FailWaiters(SdkLoadState.SDK_NOT_LOADED),
            state.onNotLoaded(hasWaiters = true)
        )
        // A later attempt still gets a fresh load.
        assertEquals(SdkLoadState.Action.Reload, state.onEnsureReady())
        state.onReady()
        // Once ready, a later miss is allowed its own reload again.
        assertEquals(SdkLoadState.Action.Reload, state.onNotLoaded(hasWaiters = true))
    }

    @Test
    fun timeoutMakesNextAttemptReload() {
        val state = SdkLoadState()
        state.onReadyTimeout()
        assertEquals(SdkLoadState.Phase.FAILED, state.phase)
        assertEquals(SdkLoadState.Action.Reload, state.onEnsureReady())
        state.onReady()
        state.onReadyTimeout()
        assertTrue("a timeout after ready changes nothing", state.isReady)
    }

    @Test
    fun navigationFailureReloadsOnceThenFails() {
        val state = SdkLoadState()
        assertEquals(SdkLoadState.Action.Reload, state.onNavigationFailure())
        assertEquals(
            SdkLoadState.Action.FailWaiters(SdkLoadState.WEBVIEW_NOT_READY),
            state.onNavigationFailure()
        )
        assertEquals(SdkLoadState.Action.Reload, state.onEnsureReady())
    }
}
