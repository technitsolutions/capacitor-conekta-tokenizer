import { WebPlugin } from '@capacitor/core';

import type {
  ConektaToken,
  ConektaTokenizerPlugin,
  CreateTokenOptions,
  CreateTokenResult,
  SetPublicKeyOptions,
} from './definitions';

declare const Conekta: {
  setPublicKey(key: string): void;
  setLanguage(lang: string): void;
  Token: {
    create(
      params: { card: Record<string, string> },
      success: (token: ConektaToken) => void,
      error: (err: { message_to_purchaser: string }) => void,
    ): void;
  };
};

export class ConektaTokenizerWeb extends WebPlugin implements ConektaTokenizerPlugin {
  private sdkLoaded = false;
  private sdkLoading: Promise<void> | null = null;

  private loadSdk(): Promise<void> {
    if (this.sdkLoaded) return Promise.resolve();
    if (this.sdkLoading) return this.sdkLoading;

    this.sdkLoading = new Promise<void>((resolve, reject) => {
      const script = document.createElement('script');
      script.src = 'https://cdn.conekta.io/js/latest/conekta.js';
      script.async = true;
      script.onload = () => {
        this.sdkLoaded = true;
        resolve();
      };
      script.onerror = () => reject(new Error('Failed to load Conekta JS SDK'));
      document.head.appendChild(script);
    });

    return this.sdkLoading;
  }

  async setPublicKey(options: SetPublicKeyOptions): Promise<void> {
    if (!options.publicKey) {
      throw new Error('publicKey is required');
    }
    await this.loadSdk();
    Conekta.setPublicKey(options.publicKey);
    Conekta.setLanguage('es');
  }

  async createToken(options: CreateTokenOptions): Promise<CreateTokenResult> {
    await this.loadSdk();

    const { name, cardNumber, expMonth, expYear, cvc } = options;
    if (!name || !cardNumber || !expMonth || !expYear || !cvc) {
      throw new Error('All card fields are required: name, cardNumber, expMonth, expYear, cvc');
    }

    return new Promise<CreateTokenResult>((resolve, reject) => {
      Conekta.Token.create(
        {
          card: {
            name,
            number: cardNumber,
            cvc,
            exp_month: expMonth,
            exp_year: expYear,
          },
        },
        (token) => resolve({ token }),
        (err) => reject(new Error(err.message_to_purchaser)),
      );
    });
  }
}
