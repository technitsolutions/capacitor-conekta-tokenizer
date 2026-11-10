import { WebPlugin } from '@capacitor/core';

import type {
  ConektaRawError,
  ConektaToken,
  ConektaTokenError,
  ConektaTokenizerPlugin,
  CreateTokenOptions,
  CreateTokenResult,
  IsReadyResult,
  SetPublicKeyOptions,
} from './definitions';

declare const Conekta: {
  setPublicKey(key: string): void;
  setLanguage(lang: string): void;
  Token: {
    create(
      params: { card: Record<string, string> },
      success: (token: ConektaToken) => void,
      error: (err: ConektaRawError) => void,
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
      // A failed load must not be cached: forget it so the next call retries once the
      // network is back, instead of rejecting with the same error until a page reload.
      const fail = () => {
        script.remove();
        this.sdkLoading = null;
        const e = new Error('Conekta SDK not loaded') as ConektaTokenError;
        e.code = 'sdk_not_loaded';
        reject(e);
      };
      script.onload = () => {
        if (typeof Conekta === 'undefined' || !Conekta?.Token) {
          fail();
          return;
        }
        this.sdkLoaded = true;
        resolve();
      };
      script.onerror = fail;
      document.head.appendChild(script);
    });

    return this.sdkLoading;
  }

  async warmUp(): Promise<IsReadyResult> {
    await this.loadSdk();
    return { ready: true };
  }

  async isReady(): Promise<IsReadyResult> {
    return { ready: this.sdkLoaded };
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
        (err) => {
          const raw: ConektaRawError = err ?? {};
          const message = raw.message_to_purchaser || raw.message || 'Conekta token error';
          const e = new Error(message) as ConektaTokenError;
          if (typeof raw.code === 'string') e.code = raw.code;
          if (typeof raw.type === 'string') e.type = raw.type;
          if (typeof raw.param === 'string') e.param = raw.param;
          e.conektaError = raw;
          reject(e);
        },
      );
    });
  }
}
