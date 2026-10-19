export type Offer = { enabled: boolean; plan?: string; amount_minor?: number; currency?: string; duration_days?: number; max_devices?: number; billing_mode?: 'payment' | 'subscription'; billing_interval?: 'month' | 'year'; billing_interval_count?: number; trial_days?: number }
export type Subscription = {
  status: string; paid_through: string | null; current_period_end: string | null;
  cancel_at_period_end: boolean; cancel_at: string | null; trial_through: string | null; trial_days: number;
  billing_mode: 'subscription'; billing_interval: 'month' | 'year'; billing_interval_count: number;
  amount_minor: number; currency: string; duration_days: number; max_devices: number
}
// Stripe's minor-unit conventions differ from ISO/Intl for a few currencies.
const zeroDecimal = new Set(['BIF', 'CLP', 'DJF', 'GNF', 'JPY', 'KMF', 'KRW', 'MGA', 'PYG', 'RWF', 'VND', 'VUV', 'XAF', 'XOF', 'XPF'])

export const formattedPrice = (offer: Omit<Offer, 'enabled'>) => {
  if (!Number.isSafeInteger(offer.amount_minor) || offer.amount_minor! <= 0 || !/^[a-z]{3}$/i.test(offer.currency ?? '')) return null
  try {
    const currency = offer.currency!.toUpperCase()
    if (['ISK', 'UGX'].includes(currency) && offer.amount_minor! % 100 !== 0) return null
    const formatter = new Intl.NumberFormat(undefined, { style: 'currency', currency })
    const exponent = zeroDecimal.has(currency) ? 0 : ['ISK', 'UGX'].includes(currency) ? 2 : (formatter.resolvedOptions().maximumFractionDigits ?? 2)
    return formatter.format(offer.amount_minor! / 10 ** exponent)
  } catch { return null }
}
export const validOfferTerms = (offer: Omit<Offer, 'enabled'>) => Boolean(formattedPrice(offer) && Number.isInteger(offer.duration_days) && offer.duration_days! >= 0 && Number.isInteger(offer.max_devices) && offer.max_devices! >= 1 && offer.max_devices! <= 100 &&
  (!offer.billing_mode || offer.billing_mode === 'payment' || offer.billing_mode === 'subscription' && offer.duration_days === 0 && ['month', 'year'].includes(offer.billing_interval ?? '') && offer.billing_interval_count === 1 &&
    (offer.trial_days === undefined || Number.isInteger(offer.trial_days) && offer.trial_days >= 0 && offer.trial_days <= 30)))
