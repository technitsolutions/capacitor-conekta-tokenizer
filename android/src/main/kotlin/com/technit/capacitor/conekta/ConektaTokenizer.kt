package com.technit.capacitor.conekta

import android.util.Base64
import android.util.Log
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL

class ConektaTokenizer {
    companion object {
        private const val TAG = "ConektaTokenizer"
        private const val API_BASE = "https://api.conekta.io"
    }

    private var publicKey: String? = null

    fun setPublicKey(publicKey: String) {
        this.publicKey = publicKey
    }

    fun createToken(
        name: String,
        cardNumber: String,
        expMonth: String,
        expYear: String,
        cvc: String,
        onSuccess: (String) -> Unit,
        onError: (String) -> Unit
    ) {
        val key = publicKey
        if (key == null) {
            onError("Public key not set. Call setPublicKey() before createToken().")
            return
        }

        Thread {
            try {
                val url = URL("$API_BASE/tokens")
                val connection = url.openConnection() as HttpURLConnection
                connection.requestMethod = "POST"
                connection.setRequestProperty("Content-Type", "application/json")
                connection.setRequestProperty("Accept", "application/vnd.conekta-v2.2.0+json")

                val credentials = "$key:"
                val encoded = Base64.encodeToString(credentials.toByteArray(), Base64.NO_WRAP)
                connection.setRequestProperty("Authorization", "Basic $encoded")

                connection.doOutput = true

                val card = JSONObject().apply {
                    put("number", cardNumber)
                    put("name", name)
                    put("cvc", cvc)
                    put("exp_month", expMonth)
                    put("exp_year", expYear)
                }

                val body = JSONObject().apply {
                    put("card", card)
                }

                val writer = OutputStreamWriter(connection.outputStream)
                writer.write(body.toString())
                writer.flush()
                writer.close()

                val responseCode = connection.responseCode
                val stream = if (responseCode == HttpURLConnection.HTTP_OK) {
                    connection.inputStream
                } else {
                    connection.errorStream
                }

                val reader = BufferedReader(InputStreamReader(stream))
                val response = reader.readText()
                reader.close()
                connection.disconnect()

                val json = JSONObject(response)

                if (responseCode != HttpURLConnection.HTTP_OK) {
                    val message = try {
                        json.optJSONArray("details")?.optJSONObject(0)?.optString("message")
                            ?: json.optString("message", "Conekta API error: $responseCode")
                    } catch (e: Exception) {
                        "Conekta API error: $responseCode"
                    }
                    onError(message)
                    return@Thread
                }

                val tokenId = json.optString("id", "")
                if (tokenId.isEmpty()) {
                    onError("Invalid response from Conekta API: missing token id")
                    return@Thread
                }

                onSuccess(tokenId)
            } catch (e: Exception) {
                Log.e(TAG, "Error creating token", e)
                onError(e.message ?: "Unknown error creating token")
            }
        }.start()
    }
}
