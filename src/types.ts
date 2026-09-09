// SnapOG — shared types

export type Tier = 'free' | 'pro' | 'business';

export const TIER_LIMITS: Record<Tier, number> = {
  free: 100,
  pro: 10_000,
  business: 100_000,
};

export interface ApiKey {
  id: string;
  user_id: string;
  name: string;
  key_prefix: string;
  key_hash: string;
  tier: Tier;
  monthly_limit: number;
  usage_count: number;
  usage_reset_at: string;
  created_at: string;
  upgraded_at?: string | null;
}

// Larger allowances are never self-service — an operator grants them via
// POST /admin/upgrade. Signup can only ever mint a free key. Nothing is for
// sale: there is no billing, and these limits are not products.
export const SIGNUP_TIER: Tier = 'free';

export const PAID_TIERS: readonly Tier[] = ['pro', 'business'];

export function isPaidTier(value: string): value is Tier {
  return (PAID_TIERS as readonly string[]).includes(value);
}

// Without a ceiling, `POST /register` is a quota vending machine: the same email
// can mint an unlimited number of keys, each with a fresh monthly allowance, so
// the free plan's 100 images is really 100 × (however many times you click).
// Three keys covers the honest case (prod / staging / a throwaway) and stops the
// dishonest one.
export const MAX_KEYS_PER_EMAIL = 3;

export interface OGParams {
  title: string;
  description?: string;
  theme?: 'dark' | 'light';
  template?: 'default' | 'blog' | 'article';
  author?: string;
  domain?: string;
  tag?: string;
}

export interface Env {
  DB: D1Database;
  OG_CACHE: R2Bucket;
  ENVIRONMENT: string;
  AUTH_SECRET?: string;
}
