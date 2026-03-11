package com.technit.capacitor.conekta

import android.annotation.SuppressLint
import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.webkit.WebViewClient
import org.json.JSONObject

class ConektaTokenizer {
    companion object {
        private const val TAG = "ConektaTokenizer"
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
                Conekta.setPublicKey(publicKey);
                Conekta.setLanguage('es');
            }
            function createToken(name, number, cvc, expMonth, expYear) {
                Conekta.Token.create({
                    card: { name: name, number: number, cvc: cvc, exp_month: expMonth, exp_year: expYear }
                }, function(token) {
                    ConektaBridge.onResult(JSON.stringify({type:'token', success:true, token:token}));
                }, function(error) {
                    ConektaBridge.onResult(JSON.stringify({type:'token', success:false, error:error.message_to_purchaser || 'Token creation failed'}));
                });
            }
            </script>
            </head>
            <body></body>
            </html>
        """.trimIndent()
    }

    private var webView: WebView? = null
    private var publicKey: String? = null
    private var sdkReady = false
    private var sdkReadyCallback: (() -> Unit)? = null
    private var tokenSuccess: ((JSONObject) -> Unit)? = null
    private var tokenError: ((String) -> Unit)? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    @SuppressLint("SetJavaScriptEnabled")
    fun setup(activity: Activity) {
        mainHandler.post {
            val wv = WebView(activity)
            wv.settings.javaScriptEnabled = true
            wv.settings.domStorageEnabled = true
            wv.addJavascriptInterface(this, "ConektaBridge")
            wv.webViewClient = WebViewClient()
            wv.loadDataWithBaseURL("https://conekta.com", HTML, "text/html", "UTF-8", null)
            webView = wv
        }
    }

    fun setPublicKey(publicKey: String) {
        this.publicKey = publicKey
    }

    fun createToken(
        name: String,
        cardNumber: String,
        expMonth: String,
        expYear: String,
        cvc: String,
        onSuccess: (JSONObject) -> Unit,
        onError: (String) -> Unit
    ) {
        val key = publicKey
        if (key == null) {
            onError("Public key not set. Call setPublicKey() before createToken().")
            return
        }

        tokenSuccess = onSuccess
        tokenError = onError

        val doTokenize: () -> Unit = {
            mainHandler.post {
                val wv = webView
                if (wv == null) {
                    onError("Conekta WebView is not ready.")
                    return@post
                }

                val escapedKey = key.replace("'", "\\'")
                val escapedName = name.replace("'", "\\'")

                wv.evaluateJavascript("initConekta('$escapedKey')", null)
                wv.evaluateJavascript(
                    "createToken('$escapedName', '$cardNumber', '$cvc', '$expMonth', '$expYear')",
                    null
                )
            }
        }

        if (sdkReady) {
            doTokenize()
        } else {
            sdkReadyCallback = doTokenize
        }
    }

    @JavascriptInterface
    fun onResult(jsonStr: String) {
        try {
            val json = JSONObject(jsonStr)
            when (json.optString("type")) {
                "ready" -> {
                    sdkReady = true
                    sdkReadyCallback?.invoke()
                    sdkReadyCallback = null
                }
                "token" -> {
                    val success = json.optBoolean("success", false)
                    if (success) {
                        val tokenObj = json.optJSONObject("token") ?: JSONObject()
                        tokenSuccess?.invoke(tokenObj)
                    } else {
                        val error = json.optString("error", "Token creation failed")
                        tokenError?.invoke(error)
                    }
                    tokenSuccess = null
                    tokenError = null
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error parsing WebView result", e)
            tokenError?.invoke(e.message ?: "Unknown error")
            tokenError = null
            tokenSuccess = null
        }
    }
}
