export interface ConektaTokenizerPlugin {
  /**
   * Set the Conekta public API key for tokenization.
   *
   * @since 1.0.0
   */
  setPublicKey(options: SetPublicKeyOptions): Promise<void>;

  /**
   * Create a payment token from card details.
   *
   * Sends card data directly to the Conekta API (`POST https://api.conekta.io/tokens`)
   * and returns a single-use token ID.
   *
   * @since 1.0.0
   */
  createToken(options: CreateTokenOptions): Promise<CreateTokenResult>;
}

export interface SetPublicKeyOptions {
  /**
   * Your Conekta public API key (e.g., `key_xxxxxxxx`).
   *
   * @since 1.0.0
   */
  publicKey: string;
}

export interface CreateTokenOptions {
  /**
   * Cardholder name as it appears on the card.
   *
   * @since 1.0.0
   */
  name: string;

  /**
   * Card number (digits only, no spaces or dashes).
   *
   * @since 1.0.0
   */
  cardNumber: string;

  /**
   * Expiration month (e.g., `"01"` for January).
   *
   * @since 1.0.0
   */
  expMonth: string;

  /**
   * Expiration year (e.g., `"25"` or `"2025"`).
   *
   * @since 1.0.0
   */
  expYear: string;

  /**
   * Card verification code (3 or 4 digits).
   *
   * @since 1.0.0
   */
  cvc: string;
}

export interface ConektaToken {
  /**
   * The single-use payment token ID (e.g., `tok_xxxxxxxx`).
   *
   * @since 1.0.0
   */
  id: string;

  /**
   * Whether this token was created in live mode.
   *
   * @since 1.1.0
   */
  livemode: boolean;

  /**
   * Whether this token has already been used.
   *
   * @since 1.1.0
   */
  used: boolean;

  /**
   * Object type (always `"token"`).
   *
   * @since 1.1.0
   */
  object: string;

  /**
   * Additional fields returned by the Conekta API.
   */
  [key: string]: unknown;
}

export interface CreateTokenResult {
  /**
   * The full Conekta token object.
   *
   * @since 1.1.0
   */
  token: ConektaToken;
}

/**
 * Raw error envelope as returned by `conekta.js`.
 *
 * All fields are optional because the shape varies by failure class
 * (client-side validation, issuer rejection, API error, etc.). Log this
 * object to your observability tool (e.g. Sentry `extra`) to preserve
 * full diagnostic context.
 *
 * @since 1.3.0
 */
export interface ConektaRawError {
  object?: string;
  type?: string;
  code?: string;
  param?: string;
  message?: string;
  message_to_purchaser?: string;
  [key: string]: unknown;
}

/**
 * Error rejected by `createToken` when Conekta rejects the card.
 *
 * Extends the standard `Error` with structured fields mirrored from
 * `conektaError` for ergonomic destructuring. On native platforms the
 * same fields are surfaced through Capacitor's error payload.
 *
 * @since 1.3.0
 */
export interface ConektaTokenError extends Error {
  /**
   * Conekta error code when available (e.g., `conekta_js.invalid_expiration`).
   */
  code?: string;

  /**
   * Conekta error type (e.g., `parameter_validation_error`).
   */
  type?: string;

  /**
   * Offending parameter name when Conekta reports one.
   */
  param?: string;

  /**
   * Full raw error envelope as returned by `conekta.js`.
   */
  conektaError?: ConektaRawError;
}
