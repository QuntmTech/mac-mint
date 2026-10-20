import { pb } from './pb'
import { formatMinor } from './offers'

export type Tier = {
  tier: string
  devices: number
  amount_minor: number
  currency: string
  trial_days: number
  billing_interval: 'month' | 'year'
  billing_interval_count: number
}
export type Plans = { enabled: boolean; tiers?: Tier[] }
export type ClaimPlan = Pick<Tier, 'tier' | 'devices' | 'amount_minor' | 'currency' | 'trial_days' | 'billing_interval'>
export type ClaimState = 'processing' | 'ready' | 'existing_account' | 'claimed' | 'expired' | 'attention' | 'not_found'
export type ClaimStatus = { state: ClaimState; email?: string; plan?: ClaimPlan }
export type Download = {
  source: 'feed' | 'github' | 'none'
  version?: string
  url?: string
  size_bytes?: number | null
  sha256?: string | null
  min_os?: string
  notarized?: boolean
}

const json = { 'Content-Type': 'application/json' }

const validTier = (tier: Tier) => /^[a-z0-9][a-z0-9_-]{0,31}$/.test(tier.tier) && Number.isInteger(tier.devices) && tier.devices >= 1 &&
  tier.devices <= 100 && formatMinor(tier.amount_minor, tier.currency) !== null && tier.amount_minor > 0 &&
  Number.isInteger(tier.trial_days) && tier.trial_days >= 0 && tier.trial_days <= 30 && ['month', 'year'].includes(tier.billing_interval)

export const fetchPlans = async (): Promise<Plans> => {
  const plans = await pb.send<Plans>('/api/macmint/plans', { method: 'GET' })
  if (!plans.enabled) return { enabled: false }
  if (!Array.isArray(plans.tiers) || !plans.tiers.length || !plans.tiers.every(validTier)) throw new Error('Invalid plans')
  return { enabled: true, tiers: [...plans.tiers].sort((a, b) => a.devices - b.devices) }
}

/** The server builds the Payment Link URL; only Stripe-hosted links are followed. */
export const startTrial = async (email: string, tier: string) => {
  const result = await pb.send<{ url: string }>('/api/macmint/trial/start', { method: 'POST', headers: json, body: JSON.stringify({ email, tier }) })
  const destination = new URL(result.url)
  if (destination.origin !== 'https://buy.stripe.com' || destination.username || destination.password) throw new Error('Checkout address could not be verified.')
  return destination.href
}

export const fetchClaim = (sessionId: string) =>
  pb.send<ClaimStatus>('/api/macmint/purchase/claim', { method: 'GET', query: { session_id: sessionId } })

export type ClaimResult =
  | { state: 'existing_account'; email: string }
  | { token: string; record: { id: string; email: string; verified: boolean }; meta: { state: 'claimed'; sync_pending: boolean } }

export const claimPurchase = (sessionId: string, password: string, email?: string) =>
  pb.send<ClaimResult>('/api/macmint/purchase/claim', {
    method: 'POST', headers: json, body: JSON.stringify({ session_id: sessionId, password, ...(email ? { email } : {}) }),
  })

export const refreshBilling = () => pb.send<{ refreshed: number }>('/api/macmint/billing/refresh', { method: 'POST' })

const trustedDownload = (value: string) =>
  /^https:\/\/github\.com\/QuntmTech\/mac-mint\/releases\/download\/[A-Za-z0-9._-]+\/MacMint\.dmg$/.test(value) ||
  /^https:\/\/macmint\.co\/[A-Za-z0-9._~/+-]+\.dmg$/.test(value) && !value.split('/').some(part => part === '..' || part === '.')

export const fetchDownload = async (): Promise<Download> => {
  const value = await pb.send<Download>('/api/macmint/download', { method: 'GET' })
  if (value.source === 'none' || !value.url || !trustedDownload(value.url)) return { source: 'none' }
  return value
}

export const monthlyMinor = (tier: Pick<Tier, 'amount_minor' | 'billing_interval'>) =>
  tier.billing_interval === 'year' ? Math.round(tier.amount_minor / 12) : tier.amount_minor

/** Percentage saved per Mac relative to the single-device tier. */
export const savingsPercent = (tier: Tier, base: Tier | undefined) => {
  if (!base || tier.devices <= base.devices) return 0
  const saving = 1 - (tier.amount_minor / tier.devices) / (base.amount_minor / base.devices)
  return saving > 0 ? Math.round(saving * 100) : 0
}
