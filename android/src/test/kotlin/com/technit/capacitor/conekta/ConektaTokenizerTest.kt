package com.technit.capacitor.conekta

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.mozilla.javascript.Context
import org.mozilla.javascript.NativeArray
import org.mozilla.javascript.Scriptable

class ConektaTokenizerTest {
    @Test
    fun setPublicKey_doesNotThrow() {
        val tokenizer = ConektaTokenizer()
        tokenizer.setPublicKey("key_test_123")
    }

    // Values that broke (or altered) the 1.4.0 script, which only escaped `'`.
    private val awkwardValues = listOf(
        "Peña Núñez",
        "O'Brien",
        "Back\\slash",
        "trailing backslash\\",
        "say \"hi\"",
        "line\nbreak",
        "carriage\r\nreturn",
        "tab\there",
        "nul\u0000char",
        "line\u2028separator",
        "paragraph\u2029separator",
        "</script><script>alert(1)</script>",
        "emoji 💳🙂",
        "', alert(1), '",
        "\", alert(1), \"",
        "\\', alert(1), //",
        "",
    )

    @Test
    fun jsLiteral_outputIsQuotedPrintableAscii() {
        for (value in awkwardValues) {
            val literal = ConektaTokenizer.jsLiteral(value)
            assertTrue("not quoted: $literal", literal.startsWith("\"") && literal.endsWith("\""))
            for (c in literal) {
                assertTrue("raw char U+%04X in $literal".format(c.code), c in ' '..'~')
            }
            assertFalse("raw </ in $literal", literal.contains("</"))
        }
    }

    @Test
    fun jsLiteral_isValidJsonThatRoundTrips() {
        for (value in awkwardValues) {
            val literal = ConektaTokenizer.jsLiteral(value)
            assertEquals(value, evalString("JSON.parse(${jsQuote(literal)})"))
        }
    }

    @Test
    fun jsLiteral_escapesKnownCharacters() {
        assertEquals("\"Pe\\u00f1a N\\u00fa\\u00f1ez\"", ConektaTokenizer.jsLiteral("Peña Núñez"))
        assertEquals("\"a\\\\b\"", ConektaTokenizer.jsLiteral("a\\b"))
        assertEquals("\"a\\\"b\"", ConektaTokenizer.jsLiteral("a\"b"))
        assertEquals("\"O'Brien\"", ConektaTokenizer.jsLiteral("O'Brien"))
        assertEquals("\"a\\u000ab\"", ConektaTokenizer.jsLiteral("a\nb"))
        assertEquals("\"a\\u2028b\"", ConektaTokenizer.jsLiteral("a\u2028b"))
        assertEquals("\"\\ud83d\\udcb3\"", ConektaTokenizer.jsLiteral("💳"))
        assertEquals("\"\\u003c/script\\u003e\"", ConektaTokenizer.jsLiteral("</script>"))
    }

    @Test
    fun createTokenScript_passesEveryFieldIntact() {
        for (value in awkwardValues) {
            val args = runCreateToken(
                ConektaTokenizer.createTokenScript(7, value, value, value, value, value)
            )
            assertEquals(7.0, (args[0] as Number).toDouble(), 0.0)
            for (i in 1..5) {
                assertEquals("argument $i for ${ConektaTokenizer.jsLiteral(value)}", value, args[i])
            }
        }
    }

    @Test
    fun createTokenScript_keepsArgumentOrder() {
        val args = runCreateToken(
            ConektaTokenizer.createTokenScript(3, "Peña Núñez", "4242424242424242", "123", "12", "2030")
        )
        assertEquals(
            listOf(3.0, "Peña Núñez", "4242424242424242", "123", "12", "2030"),
            listOf((args[0] as Number).toDouble()) + args.drop(1)
        )
    }

    @Test
    fun initScript_passesKeyIntact() {
        for (value in awkwardValues) {
            val args = evalArray(
                "var captured;\n" +
                    "function initConekta(publicKey, id) { captured = [publicKey, id]; }\n" +
                    ConektaTokenizer.initScript(value, 42) + ";"
            )
            assertEquals(value, args[0])
            assertEquals(42.0, (args[1] as Number).toDouble(), 0.0)
        }
    }

    private fun runCreateToken(script: String): List<Any?> = evalArray(
        "var captured;\n" +
            "function createToken(id, name, number, cvc, expMonth, expYear) {\n" +
            "  captured = [id, name, number, cvc, expMonth, expYear];\n" +
            "}\n" +
            script + ";"
    )

    /** Runs [script] in a real JS engine and returns the `captured` array it fills. */
    private fun evalArray(script: String): List<Any?> = withScope { cx, scope ->
        cx.evaluateString(scope, script, "test", 1, null)
        val captured = scope.get("captured", scope) as NativeArray
        captured.map { if (it is CharSequence) it.toString() else it }
    }

    private fun evalString(expression: String): String = withScope { cx, scope ->
        Context.toString(cx.evaluateString(scope, expression, "test", 1, null))
    }

    private fun <T> withScope(block: (Context, Scriptable) -> T): T {
        val cx = Context.enter()
        try {
            cx.optimizationLevel = -1
            cx.languageVersion = Context.VERSION_ES6
            return block(cx, cx.initStandardObjects())
        } finally {
            Context.exit()
        }
    }

    /** Single-quoted JS literal for test scaffolding; its input is already printable ASCII. */
    private fun jsQuote(s: String): String = "'" + s.replace("\\", "\\\\").replace("'", "\\'") + "'"
}
