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
            function post(message) {
                ConektaBridge.onResult(JSON.stringify(message));
            }
            function sdkAvailable() {
                return typeof Conekta !== 'undefined' && !!Conekta && !!Conekta.Token;
            }
            // `load` also fires when conekta.js failed to load (offline, slow network), so it
            // only means "ready" when the SDK is actually there.
            window.addEventListener('load', function() {
                post({type: sdkAvailable() ? 'ready' : 'not_loaded'});
            });
            function initConekta(publicKey, id) {
                try {
                    if (!sdkAvailable()) {
                        post({
                            type:'token', id:id, success:false,
                            error: { message_to_purchaser: 'Conekta SDK not loaded', code: 'sdk_not_loaded' }
                        });
                        return;
                    }
                    Conekta.setPublicKey(publicKey);
                    Conekta.setLanguage('es');
                } catch (e) {
                    post({
                        type:'token', id:id, success:false,
                        error: { message_to_purchaser: (e && e.message) || 'initConekta threw', code: 'js_exception' }
                    });
                }
            }
            function createToken(id, name, number, cvc, expMonth, expYear) {
                try {
                    if (!sdkAvailable()) {
                        post({
                            type:'token', id:id, success:false,
                            error: { message_to_purchaser: 'Conekta SDK not loaded', code: 'sdk_not_loaded' }
                        });
                        return;
                    }
                    // Tells native the page ran and handed the request to conekta.js, so a
                    // timeout can say whether nothing ran or Conekta was slow to answer.
                    post({type:'request_sent', id:id});
                    Conekta.Token.create({
                        card: { name: name, number: number, cvc: cvc, exp_month: expMonth, exp_year: expYear }
                    }, function(token) {
                        post({type:'token', id:id, success:true, token:token});
                    }, function(error) {
                        post({type:'token', id:id, success:false, error: error || {message_to_purchaser: 'Token creation failed'}});
                    });
                } catch (e) {
                    post({
                        type:'token', id:id, success:false,
                        error: { message_to_purchaser: (e && e.message) || 'createToken threw', code: 'js_exception' }
                    });
                }
            }
            </script>
            </head>
            <body></body>
            </html>
        """.trimIndent()

        private const val HEX = "0123456789abcdef"

        /**
         * Encodes [value] as a double-quoted JS string literal that is also valid JSON, so card
         * data can never break or alter the script it is placed in. 1.4.0 and earlier only
         * escaped `'`, so a backslash or a line break in the cardholder name produced a syntax
         * error (or a different string) instead of a token, and the other fields were not
         * escaped at all.
         *
         * Everything outside printable ASCII is written as a `\uXXXX` escape (one per UTF-16
         * unit, which JS and JSON both rejoin), and so are `<`, `>` and `&`. That covers line
         * breaks, U+2028/U+2029 (line terminators inside a string literal before ES2019), other
         * control characters and `</script>`-like sequences, and keeps the output identical on
         * every Android version. `org.json`'s `JSONObject.quote` is not used because Android's
         * copy leaves U+2028/U+2029 raw and is only a stub in local unit tests, so the tests
         * could not exercise the code that ships.
         */
        internal fun jsLiteral(value: String): String {
            val out = StringBuilder(value.length + 2)
            out.append('"')
            for (c in value) {
                when {
                    c == '"' -> out.append("\\\"")
                    c == '\\' -> out.append("\\\\")
                    c == '<' || c == '>' || c == '&' || c < ' ' || c > '~' -> {
                        val code = c.code
                        out.append("\\u")
                            .append(HEX[(code shr 12) and 0xF])
                            .append(HEX[(code shr 8) and 0xF])
                            .append(HEX[(code shr 4) and 0xF])
                            .append(HEX[code and 0xF])
                    }
                    else -> out.append(c)
                }
            }
            out.append('"')
            return out.toString()
        }

        /** Script that points conekta.js at [publicKey] for request [requestId]. */
        internal fun initScript(publicKey: String, requestId: Int): String =
            "initConekta(${jsLiteral(publicKey)}, $requestId)"

        /** Script that asks the page to tokenize the card for request [requestId]. */
        internal fun createTokenScript(
            requestId: Int,
            name: String,
            cardNumber: String,
            cvc: String,
            expMonth: String,
            expYear: String
        ): String = "createToken($requestId, ${jsLiteral(name)}, ${jsLiteral(cardNumber)}, " +
            "${jsLiteral(cvc)}, ${jsLiteral(expMonth)}, ${jsLiteral(expYear)})"
    }

    /**
     * @property requestSent only for `token_request_timeout`: whether the page reported handing
     *   the request to conekta.js (`false` = nothing ran, `true` = Conekta did not answer in time).
     */
    data class ConektaFailure(val raw: JSONObject, val code: String?, val requestSent: Boolean? = null)

    private var webView: WebView? = null
    private var publicKey: String? = null
    private val loadState = SdkLoadState()
    private var sdkReadyWaiters: MutableList<(Boolean, ConektaFailure?) -> Unit> = mutableListOf()
    private var tokenSuccess: ((JSONObject) -> Unit)? = null
    private var tokenError: ((ConektaFailure) -> Unit)? = null
    private var sdkReadyTimeout: Runnable? = null
    private var tokenTimeout: Runnable? = null
    /**
     * Identifies the request in flight. The page echoes it on every message, so a late answer
     * to a request that already timed out can never complete (or fail) the retry that follows.
     */
    private var currentRequestId = 0
    /** Whether the page reported `request_sent` for the request in flight. */
    private var requestSent = false
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
            webView = wv
            loadPage()
        }
    }

    private fun loadPage() {
        webView?.loadDataWithBaseURL("https://conekta.com", HTML, "text/html", "UTF-8", null)
    }

    fun setPublicKey(publicKey: String) {
        this.publicKey = publicKey
    }

    fun isReady(): Boolean = loadState.isReady

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
        if (loadState.isReady) {
            callback(true, null)
            return
        }
        sdkReadyWaiters.add(callback)
        if (sdkReadyTimeout == null) {
            val r = Runnable {
                loadState.onReadyTimeout()
                flushReadyWaiters(false, sdkTimeoutFailure())
            }
            sdkReadyTimeout = r
            mainHandler.postDelayed(r, SDK_READY_TIMEOUT_MS)
        }
        // A page that loaded without the SDK (or failed) is reloaded here, which is what lets a
        // later attempt recover once the network is back. The page must be touched on the main
        // thread, where every caller of ensureReady already runs except the plugin call itself.
        mainHandler.post { apply(loadState.onEnsureReady()) }
    }

    private fun apply(action: SdkLoadState.Action) {
        when (action) {
            SdkLoadState.Action.None -> Unit
            SdkLoadState.Action.Reload -> loadPage()
            SdkLoadState.Action.SucceedWaiters -> flushReadyWaiters(true, null)
            is SdkLoadState.Action.FailWaiters -> flushReadyWaiters(false, loadFailure(action.code))
        }
    }

    private fun loadFailure(code: String): ConektaFailure {
        val message = if (code == SdkLoadState.SDK_NOT_LOADED) {
            "Conekta SDK not loaded"
        } else {
            "Conekta WebView is not ready."
        }
        val raw = JSONObject().put("message_to_purchaser", message).put("code", code)
        return ConektaFailure(raw, code)
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
            .put("requestSent", requestSent)
        return ConektaFailure(raw, "token_request_timeout", requestSent)
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

                currentRequestId += 1
                requestSent = false
                val requestId = currentRequestId
                armTokenTimeout()

                wv.evaluateJavascript(initScript(key, requestId), null)
                wv.evaluateJavascript(
                    createTokenScript(requestId, name, cardNumber, cvc, expMonth, expYear),
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
        val action = loadState.onNavigationFailure()
        apply(action)
        if (action is SdkLoadState.Action.FailWaiters) {
            finishTokenError(loadFailure(SdkLoadState.WEBVIEW_NOT_READY))
        }
    }

    @JavascriptInterface
    fun onResult(jsonStr: String) {
        mainHandler.post {
            try {
                val json = JSONObject(jsonStr)
                // Messages about an older request (one that already timed out) must not touch
                // the current one. Messages without an id predate request ids.
                if (json.has("id") && json.optInt("id", -1) != currentRequestId) {
                    return@post
                }
                when (json.optString("type")) {
                    "ready" -> apply(loadState.onReady())
                    "not_loaded" -> apply(loadState.onNotLoaded(hasWaiters = sdkReadyWaiters.isNotEmpty()))
                    "request_sent" -> requestSent = true
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
                            if (code == SdkLoadState.SDK_NOT_LOADED) {
                                // The SDK went missing after `ready`: mark it so the next
                                // attempt reloads instead of failing the same way.
                                apply(loadState.onNotLoaded(hasWaiters = false))
                            }
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
