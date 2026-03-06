import { WebPlugin } from '@capacitor/core';

import type {
  ConektaTokenizerPlugin,
  CreateTokenOptions,
  CreateTokenResult,
  SetPublicKeyOptions,
} from './definitions';

const CONEKTA_API_BASE = 'https://api.conekta.io';

export class ConektaTokenizerWeb
  extends WebPlugin
  implements ConektaTokenizerPlugin
{
  private publicKey: string | null = null;

  async setPublicKey(options: SetPublicKeyOptions): Promise<void> {
    if (!options.publicKey) {
      throw new Error('publicKey is required');
    }
    this.publicKey = options.publicKey;
  }

  async createToken(options: CreateTokenOptions): Promise<CreateTokenResult> {
    if (!this.publicKey) {
      throw new Error(
        'Public key not set. Call setPublicKey() before createToken().',
      );
    }

    const { name, cardNumber, expMonth, expYear, cvc } = options;
    if (!name || !cardNumber || !expMonth || !expYear || !cvc) {
      throw new Error(
        'All card fields are required: name, cardNumber, expMonth, expYear, cvc',
      );
    }

    const body = JSON.stringify({
      card: {
        number: cardNumber,
        name,
        cvc,
        exp_month: expMonth,
        exp_year: expYear,
      },
    });

    const response = await fetch(`${CONEKTA_API_BASE}/tokens`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Accept: 'application/vnd.conekta-v2.2.0+json',
        Authorization: `Basic ${btoa(this.publicKey + ':')}`,
      },
      body,
    });

    if (!response.ok) {
      const error = await response.json().catch(() => ({}));
      const message =
        error?.details?.[0]?.message ||
        error?.message ||
        `Conekta API error: ${response.status}`;
      throw new Error(message);
    }

    const data = await response.json();

    if (!data.id) {
      throw new Error('Invalid response from Conekta API: missing token id');
    }

    return { token: data.id };
  }
}
