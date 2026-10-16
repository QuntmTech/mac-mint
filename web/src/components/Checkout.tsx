import { useEffect, useState } from 'react'
import { Button, Alert } from './Form'
import { pb, errorMessage } from '../lib/pb'

type Offer = { enabled: boolean; duration_days?: number; max_devices?: number }

export const Checkout = ({ userId, verified }: { userId: string; verified: boolean }) => {
  const [offer, setOffer] = useState<Offer | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  useEffect(() => {
    let active = true
    pb.send<Offer>('/api/macmint/checkout/config', { method: 'GET' })
      .then(value => { if (active) setOffer(value) })
      .catch(() => { if (active) setOffer({ enabled: false }) })
    return () => { active = false }
  }, [])
  if (!offer?.enabled) return <p className="text-sm text-slate-500">Checkout is not open yet. Local scanning and recovery do not require a paid plan.</p>
  const purchase = async () => {
    setBusy(true)
    setError(null)
    try {
      const storageKey = `mm_checkout_${userId}`
      const requestKey = sessionStorage.getItem(storageKey) ?? crypto.randomUUID()
      sessionStorage.setItem(storageKey, requestKey)
      const result = await pb.send<{ url: string }>('/api/macmint/checkout', {
        method: 'POST', body: JSON.stringify({ request_key: requestKey }),
        headers: { 'Content-Type': 'application/json' },
      })
      const destination = new URL(result.url)
      if (destination.protocol !== 'https:' || destination.hostname !== 'checkout.stripe.com') throw new Error('Checkout address could not be verified.')
      window.location.assign(destination.href)
    } catch (err) {
      setError(errorMessage(err, 'Checkout could not be opened. Retry to resume the same payment session.'))
      setBusy(false)
    }
  }
  return <div className="mt-5 space-y-3 border-t border-slate-200 pt-5 dark:border-slate-800">
    <p>{offer.duration_days ? `${offer.duration_days} days of access` : 'Lifetime access'} · Up to {offer.max_devices} Macs</p>
    <p className="text-sm text-slate-500">One payment. Review the price and payment details in secure Stripe checkout before confirming. Your plan activates after payment confirmation.</p>
    {!verified && <p className="text-sm text-amber-700">Verify your account email before purchasing.</p>}
    {error && <Alert>{error}</Alert>}
    <Button onClick={purchase} busy={busy} disabled={!verified}>Continue to checkout</Button>
    {error && <button className="block text-sm underline" onClick={() => { sessionStorage.removeItem(`mm_checkout_${userId}`); setError(null) }}>Start a new checkout attempt</button>}
  </div>
}
