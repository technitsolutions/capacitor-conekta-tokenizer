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
