package com.technit.capacitor.conekta

import org.junit.Test
import org.junit.Assert.*

class ConektaTokenizerTest {
    @Test
    fun setPublicKey_doesNotThrow() {
        val tokenizer = ConektaTokenizer()
        tokenizer.setPublicKey("key_test_123")
    }
}
