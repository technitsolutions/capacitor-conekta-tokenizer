package com.technit.capacitor.conekta

import com.getcapacitor.JSObject
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin

@CapacitorPlugin(name = "ConektaTokenizer")
class ConektaTokenizerPlugin : Plugin() {

    private val implementation = ConektaTokenizer()

    override fun load() {
        implementation.setup(activity)
    }

    @PluginMethod
    fun setPublicKey(call: PluginCall) {
        val publicKey = call.getString("publicKey")
        if (publicKey == null) {
            call.reject("publicKey is required")
            return
        }
        implementation.setPublicKey(publicKey)
        call.resolve()
    }

    @PluginMethod
    fun createToken(call: PluginCall) {
        val name = call.getString("name")
        val cardNumber = call.getString("cardNumber")
        val expMonth = call.getString("expMonth")
        val expYear = call.getString("expYear")
        val cvc = call.getString("cvc")

        if (name == null || cardNumber == null || expMonth == null || expYear == null || cvc == null) {
            call.reject("All card fields are required: name, cardNumber, expMonth, expYear, cvc")
            return
        }

        implementation.createToken(
            name = name,
            cardNumber = cardNumber,
            expMonth = expMonth,
            expYear = expYear,
            cvc = cvc,
            onSuccess = { tokenObj ->
                val ret = JSObject()
                ret.put("token", JSObject(tokenObj.toString()))
                call.resolve(ret)
            },
            onError = { raw ->
                val message = when {
                    raw.has("message_to_purchaser") -> raw.optString("message_to_purchaser")
                    raw.has("message") -> raw.optString("message")
                    else -> "Token creation failed"
                }
                val code = if (raw.has("code")) raw.optString("code") else null
                val data = JSObject().apply {
                    put("conektaError", JSObject(raw.toString()))
                    if (raw.has("type")) put("type", raw.optString("type"))
                    if (raw.has("param")) put("param", raw.optString("param"))
                }
                call.reject(message, code, null, data)
            }
        )
    }
}
