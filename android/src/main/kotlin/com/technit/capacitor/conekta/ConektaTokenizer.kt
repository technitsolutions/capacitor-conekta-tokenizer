package com.technit.capacitor.conekta

import android.annotation.SuppressLint
import android.app.Activity
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.webkit.JavascriptInterface
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import org.json.JSONObject

class ConektaTokenizer {
    companion object {
        private const val TAG = "ConektaTokenizer"
        const val SDK_READY_TIMEOUT_MS: Long = 15_000
        const val TOKEN_REQUEST_TIMEOUT_MS: Long = 20_000

        private val HTML = """
            <!DOCTYPE html>
            <html>
            <head>
            <script src="https://cdn.conekta.io/js/latest/conekta.js"></script>
            <script>
            window.addEventListener('load', function() {
                ConektaBridge.onResult(JSON.stringify({type:'ready'}));
            });
            function initConekta(publicKey) {
                try {
                    if (typeof Conekta === 'undefined' || !Conekta) {
                        ConektaBridge.onResult(JSON.stringify({
                            type:'token', success:false,
                            error: { message_to_purchaser: 'Conekta SDK not loaded', code: 'sdk_not_loaded' }
                        }));
                        return;
                    }
                    Conekta.setPublicKey(publicKey);
                    Conekta.setLanguage('es');
                } catch (e) {
                    ConektaBridge.onResult(JSON.stringify({
                        type:'token', success:false,
                        error: { message_to_purchaser: (e && e.message) || 'initConekta threw', code: 'js_exception' }
                    }));
                }
            }
            function createToken(name, number, cvc, expMonth, expYear) {
                try {
                    if (typeof Conekta === 'undefined' || !Conekta || !Conekta.Token) {
                        ConektaBridge.onResult(JSON.stringify({
                            type:'token', success:false,
                            error: { message_to_purchaser: 'Conekta SDK not loaded', code: 'sdk_not_loaded' }
                        }));
                        return;
                    }
                    Conekta.Token.create({
                        card: { name: name, number: number, cvc: cvc, exp_month: expMonth, exp_year: expYear }
                    }, function(token) {
                        ConektaBridge.onResult(JSON.stringify({type:'token', success:true, token:token}));
                    }, function(error) {
                        ConektaBridge.onResult(JSON.stringify({type:'token', success:false, error: error || {message_to_purchaser: 'Token creation failed'}}));
                    });
                } catch (e) {
                    ConektaBridge.onResult(JSON.stringify({
                        type:'token', success:false,
                        error: { message_to_purchaser: (e && e.message) || 'createToken threw', code: 'js_exception' }
                    }));
                }
            }
            </script>
            </head>
            <body></body>
            </html>
        """.trimIndent()
    }

    data class ConektaFailure(val raw: JSONObject, val code: String?)

    private var webView: WebView? = null
    private var publicKey: String? = null
    private var sdkReady = false
    private var sdkReadyWaiters: MutableList<(Boolean, ConektaFailure?) -> Unit> = mutableListOf()
    private var tokenSuccess: ((JSONObject) -> Unit)? = null
    private var tokenError: ((ConektaFailure) -> Unit)? = null
    private var sdkReadyTimeout: Runnable? = null
    private var tokenTimeout: Runnable? = null
    private var hasAttemptedReload = false
    private lateinit var mainHandler: Handler

    @SuppressLint("SetJavaScriptEnabled")
    fun setup(activity: Activity) {
        mainHandler = Handler(Looper.getMainLooper())
        mainHandler.post {
            if (webView != null) return@post
            val wv = WebView(activity)
            wv.settings.javaScriptEnabled = true
            wv.settings.domStorageEnabled = true
            wv.addJavascriptInterface(this, "ConektaBridge")
            wv.webViewClient = object : WebViewClient() {
                override fun onReceivedError(
                    view: WebView,
                    request: WebResourceRequest,
                    error: WebResourceError
                ) {
                    if (request.isForMainFrame) {
                        handleNavigationFailure()
                    }
                }
            }
            wv.loadDataWithBaseURL("https://conekta.com", HTML, "text/html", "UTF-8", null)
            webView = wv
        }
    }

    fun setPublicKey(publicKey: String) {
        this.publicKey = publicKey
    }

    fun isReady(): Boolean = sdkReady

    fun warmUp(
        activity: Activity,
        onSuccess: () -> Unit,
        onError: (ConektaFailure) -> Unit
    ) {
        if (!::mainHandler.isInitialized) setup(activity)
        ensureReady { ok, failure ->
            if (ok) onSuccess() else onError(failure ?: sdkTimeoutFailure())
        }
    }

    private fun ensureReady(callback: (Boolean, ConektaFailure?) -> Unit) {
        if (sdkReady) {
            callback(true, null)
            return
        }
        sdkReadyWaiters.add(callback)
        if (sdkReadyTimeout == null) {
            val r = Runnable { flushReadyWaiters(false, sdkTimeoutFailure()) }
            sdkReadyTimeout = r
            mainHandler.postDelayed(r, SDK_READY_TIMEOUT_MS)
        }
    }

    private fun flushReadyWaiters(ok: Boolean, failure: ConektaFailure?) {
        sdkReadyTimeout?.let { mainHandler.removeCallbacks(it) }
        sdkReadyTimeout = null
        val waiters = sdkReadyWaiters.toList()
        sdkReadyWaiters.clear()
        for (w in waiters) w(ok, failure)
    }

    private fun sdkTimeoutFailure(): ConektaFailure {
        val raw = JSONObject()
            .put("message_to_purchaser", "Conekta SDK did not load in time.")
            .put("code", "sdk_load_timeout")
        return ConektaFailure(raw, "sdk_load_timeout")
    }

    private fun tokenTimeoutFailure(): ConektaFailure {
        val raw = JSONObject()
            .put("message_to_purchaser", "Conekta token request timed out.")
            .put("code", "token_request_timeout")
        return ConektaFailure(raw, "token_request_timeout")
    }

    fun createToken(
        name: String,
        cardNumber: String,
        expMonth: String,
        expYear: String,
        cvc: String,
        onSuccess: (JSONObject) -> Unit,
        onError: (ConektaFailure) -> Unit
    ) {
        val key = publicKey
        if (key == null) {
            val raw = JSONObject()
                .put("message_to_purchaser", "Public key not set. Call setPublicKey() before createToken().")
                .put("code", "public_key_not_set")
            onError(ConektaFailure(raw, "public_key_not_set"))
            return
        }

        if (tokenSuccess != null || tokenError != null) {
            val raw = JSONObject()
                .put("message_to_purchaser", "A Conekta token request is already in flight.")
                .put("code", "request_in_flight")
            onError(ConektaFailure(raw, "request_in_flight"))
            return
        }

        tokenSuccess = onSuccess
        tokenError = onError

        ensureReady { ok, failure ->
            if (!ok) {
                finishTokenError(failure ?: sdkTimeoutFailure())
                return@ensureReady
            }
            mainHandler.post {
                val wv = webView
                if (wv == null) {
                    val raw = JSONObject()
                        .put("message_to_purchaser", "Conekta WebView is not ready.")
                        .put("code", "webview_not_ready")
                    finishTokenError(ConektaFailure(raw, "webview_not_ready"))
                    return@post
                }

                val escapedKey = key.replace("'", "\\'")
                val escapedName = name.replace("'", "\\'")

                armTokenTimeout()

                wv.evaluateJavascript("initConekta('$escapedKey')", null)
                wv.evaluateJavascript(
                    "createToken('$escapedName', '$cardNumber', '$cvc', '$expMonth', '$expYear')",
                    null
                )
            }
        }
    }

    private fun armTokenTimeout() {
        tokenTimeout?.let { mainHandler.removeCallbacks(it) }
        val r = Runnable { finishTokenError(tokenTimeoutFailure()) }
        tokenTimeout = r
        mainHandler.postDelayed(r, TOKEN_REQUEST_TIMEOUT_MS)
    }

    private fun finishTokenSuccess(tokenObj: JSONObject) {
        tokenTimeout?.let { mainHandler.removeCallbacks(it) }
        tokenTimeout = null
        val success = tokenSuccess
        tokenSuccess = null
        tokenError = null
        success?.invoke(tokenObj)
    }

    private fun finishTokenError(failure: ConektaFailure) {
        tokenTimeout?.let { mainHandler.removeCallbacks(it) }
        tokenTimeout = null
        val err = tokenError
        tokenSuccess = null
        tokenError = null
        err?.invoke(failure)
    }

    private fun handleNavigationFailure() {
        if (!hasAttemptedReload) {
            hasAttemptedReload = true
            webView?.loadDataWithBaseURL("https://conekta.com", HTML, "text/html", "UTF-8", null)
            return
        }
        val raw = JSONObject()
            .put("message_to_purchaser", "Conekta WebView is not ready.")
            .put("code", "webview_not_ready")
        flushReadyWaiters(false, ConektaFailure(raw, "webview_not_ready"))
        finishTokenError(ConektaFailure(raw, "webview_not_ready"))
    }

    @JavascriptInterface
    fun onResult(jsonStr: String) {
        mainHandler.post {
            try {
                val json = JSONObject(jsonStr)
                when (json.optString("type")) {
                    "ready" -> {
                        sdkReady = true
                        flushReadyWaiters(true, null)
                    }
                    "token" -> {
                        val success = json.optBoolean("success", false)
                        if (success) {
                            val tokenObj = json.optJSONObject("token") ?: JSONObject()
                            finishTokenSuccess(tokenObj)
                        } else {
                            val raw = json.optJSONObject("error")
                                ?: JSONObject().put(
                                    "message_to_purchaser",
                                    json.optString("error", "Token creation failed")
                                )
                            val code = if (raw.has("code")) raw.optString("code") else null
                            finishTokenError(ConektaFailure(raw, code))
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error parsing WebView result", e)
                val raw = JSONObject().put("message_to_purchaser", e.message ?: "Unknown error")
                finishTokenError(ConektaFailure(raw, null))
            }
        }
    }
}
