# @technitsolutions/capacitor-conekta-tokenizer

Capacitor 8 plugin for Conekta card tokenization. Creates single-use payment tokens from card details via direct API calls to Conekta, bypassing iframe/SDK compatibility issues on mobile platforms.

> Based on [capacitor-conketa](https://gitlab.com/jorge.enriquez/capacitor-conketa) by [Jorge Enriquez](https://gitlab.com/jorge.enriquez). Modernized for Capacitor 8 with direct HTTP tokenization (no deprecated SDK dependencies).

## Why This Plugin?

Conekta's web tokenizer (`ConektaCheckoutComponents.Card()`) uses a zoid-based iframe that **does not work on iOS** because Capacitor uses the `capacitor://` custom URL scheme, and zoid's cross-origin iframe communication fails with non-standard schemes. Setting `iosScheme: 'https'` is also not viable because WKWebView rejects registering scheme handlers for standard schemes.

This plugin solves the problem by making **direct HTTP POST requests** to the Conekta tokenization API (`https://api.conekta.io/tokens`) from native code, completely bypassing iframe and WebView limitations.

## Platform Support

| Platform | Min Version | Implementation |
| -------- | ----------- | -------------- |
| iOS      | 15.0+       | URLSession     |
| Android  | API 23+     | HttpURLConnection |
| Web      | Modern browsers | fetch() |

## Install

```bash
npm install @technitsolutions/capacitor-conekta-tokenizer
npx cap sync
```

## Usage

```typescript
import { ConektaTokenizer } from '@technitsolutions/capacitor-conekta-tokenizer';

// 1. Set your Conekta public key
await ConektaTokenizer.setPublicKey({ publicKey: 'key_xxxxxxxxxxxxxxxx' });

// 2. Create a token from card details
const { token } = await ConektaTokenizer.createToken({
  name: 'John Doe',
  cardNumber: '4242424242424242',
  expMonth: '12',
  expYear: '25',
  cvc: '123',
});

console.log('Token:', token); // tok_xxxxxxxx
```

## API

<docgen-index>

* [`setPublicKey(...)`](#setpublickey)
* [`createToken(...)`](#createtoken)
* [Interfaces](#interfaces)

</docgen-index>

<docgen-api>
<!--Update the source file JSDoc comments and rerun docgen to update the docs below-->

### setPublicKey(...)

```typescript
setPublicKey(options: SetPublicKeyOptions) => Promise<void>
```

Set the Conekta public API key for tokenization.

| Param         | Type                                                                |
| ------------- | ------------------------------------------------------------------- |
| **`options`** | <code><a href="#setpublickeyoptions">SetPublicKeyOptions</a></code> |

**Since:** 1.0.0

--------------------


### createToken(...)

```typescript
createToken(options: CreateTokenOptions) => Promise<CreateTokenResult>
```

Create a payment token from card details.

Sends card data directly to the Conekta API (`POST https://api.conekta.io/tokens`)
and returns a single-use token ID.

| Param         | Type                                                              |
| ------------- | ----------------------------------------------------------------- |
| **`options`** | <code><a href="#createtokenoptions">CreateTokenOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#createtokenresult">CreateTokenResult</a>&gt;</code>

**Since:** 1.0.0

--------------------


### Interfaces


#### SetPublicKeyOptions

| Prop            | Type                | Description                                         | Since |
| --------------- | ------------------- | --------------------------------------------------- | ----- |
| **`publicKey`** | <code>string</code> | Your Conekta public API key (e.g., `key_xxxxxxxx`). | 1.0.0 |


#### CreateTokenResult

| Prop        | Type                | Description                                                       | Since |
| ----------- | ------------------- | ----------------------------------------------------------------- | ----- |
| **`token`** | <code>string</code> | The generated single-use payment token ID (e.g., `tok_xxxxxxxx`). | 1.0.0 |


#### CreateTokenOptions

| Prop             | Type                | Description                                     | Since |
| ---------------- | ------------------- | ----------------------------------------------- | ----- |
| **`name`**       | <code>string</code> | Cardholder name as it appears on the card.      | 1.0.0 |
| **`cardNumber`** | <code>string</code> | Card number (digits only, no spaces or dashes). | 1.0.0 |
| **`expMonth`**   | <code>string</code> | Expiration month (e.g., `"01"` for January).    | 1.0.0 |
| **`expYear`**    | <code>string</code> | Expiration year (e.g., `"25"` or `"2025"`).     | 1.0.0 |
| **`cvc`**        | <code>string</code> | Card verification code (3 or 4 digits).         | 1.0.0 |

</docgen-api>

## iOS Setup

No additional setup required. The plugin uses `URLSession` for direct HTTP calls.

## Android Setup

No additional setup required. The plugin uses `HttpURLConnection` for direct HTTP calls. The `INTERNET` permission is declared in the plugin's manifest.

### Register the Plugin

In your Capacitor app's `MainActivity.java` or `MainActivity.kt`:

```kotlin
import com.technit.capacitor.conekta.ConektaTokenizerPlugin

class MainActivity : BridgeActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        registerPlugin(ConektaTokenizerPlugin::class.java)
        super.onCreate(savedInstanceState)
    }
}
```

## How It Works

Instead of using Conekta's iframe tokenizer or deprecated native SDKs, this plugin makes a direct `POST` request to:

```
POST https://api.conekta.io/tokens
Authorization: Basic {base64(publicKey + ":")}
Content-Type: application/json

{
  "card": {
    "number": "4242424242424242",
    "name": "John Doe",
    "cvc": "123",
    "exp_month": "12",
    "exp_year": "25"
  }
}
```

This approach works reliably across all platforms without iframe or WebView restrictions.

## Acknowledgments

This plugin is based on the original [capacitor-conketa](https://gitlab.com/jorge.enriquez/capacitor-conketa) by **Jorge Enriquez**, which provided the foundational architecture for Conekta card tokenization in Capacitor applications. The original plugin targeted Capacitor 2 with native Conekta SDKs.

This modernized version was created and is maintained by **[Technit Solutions](https://github.com/technitsolutions)**.

## License

MIT - See [LICENSE](./LICENSE) for details.
