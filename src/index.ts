import { registerPlugin } from '@capacitor/core';

import type { ConektaTokenizerPlugin } from './definitions';

const ConektaTokenizer = registerPlugin<ConektaTokenizerPlugin>(
  'ConektaTokenizer',
  {
    web: () => import('./web').then((m) => new m.ConektaTokenizerWeb()),
  },
);

export * from './definitions';
export { ConektaTokenizer };
