import { useEffect, useRef, useState } from 'react'
import { Alert, Button } from './Form'
import { formattedPrice } from '../lib/offers'
import { pb, errorMessage } from '../lib/pb'
import { parseDate, type Subscription } from '../lib/account'

export function BillingCard({ subscription, userId, onRefresh }: { subscription: Subscription; userId: string; onRefresh: () => Promise<void> }) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const alive = useRef(true)
  useEffect(() => { alive.current = true; return () => { alive.current = false } }, [])
  const ended = ['canceled', 'incomplete_expired'].includes(subscription.status)
  const trial = subscription.status === 'trialing'
  const needsPayment = ['past_due', 'unpaid', 'incomplete'].includes(subscription.status)
  const date = parseDate(subscription.cancel_at || (trial ? subscription.trial_through : subscription.paid_through))
  const nextCharge = ended || subscription.cancel_at_period_end || subscription.access_held ? null
    : parseDate(trial ? subscription.trial_through : subscription.current_period_end)
  const manage = async () => {
    if (busy) return
    setBusy(true); setError(null)
    try {
      const response = await pb.send<{ url: string }>('/api/macmint/billing/portal', { method: 'POST' })
      if (!alive.current || pb.authStore.record?.id !== userId) return
      const destination = new URL(response.url)
      if (destination.origin !== 'https://billing.stripe.com' || destination.username || destination.password) {
        setError('Billing address could not be verified. Retry or contact support@macmint.co.'); return
      }
      window.location.assign(destination.href)
    } catch (err) {
      if (alive.current && pb.authStore.record?.id === userId) setError(errorMessage(err, 'Billing could not be opened. Retry or contact support@macmint.co.'))
    } finally { if (alive.current) setBusy(false) }
  }
  return <section aria-label="Subscription billing" className="mt-5 space-y-3 border-t border-slate-200 pt-5 dark:border-slate-700">
    <h3 className="font-semibold">{ended ? 'Previous subscription' : 'Your subscription'}</h3>
    <p>{formattedPrice(subscription)} / {subscription.billing_interval} · Up to {subscription.max_devices} {subscription.max_devices === 1 ? 'Mac' : 'Macs'}</p>
    {ended ? <p>Your subscription has ended. Local scanning, History and Restore remain available.</p>
      : subscription.cancel_at_period_end ? <p>Renewal is canceled.{date ? ` Access ends ${date.toLocaleDateString(undefined, { dateStyle: 'long' })}.` : ' Refresh your account to check the access end date.'}</p>
      : trial ? <p>Your free trial{date ? ` ends ${date.toLocaleDateString(undefined, { dateStyle: 'long' })}` : ' is active'}. After the trial, billing starts at {formattedPrice(subscription)} per {subscription.billing_interval}. Cancel before it ends to avoid the first charge.</p>
      : <p>Renews automatically each {subscription.billing_interval}.{date ? ` Paid through ${date.toLocaleDateString(undefined, { dateStyle: 'long' })}.` : ''}</p>}
    {nextCharge && <p data-testid="next-charge">Next charge: <strong className="font-semibold">{formattedPrice(subscription)}</strong> on {nextCharge.toLocaleDateString(undefined, { dateStyle: 'long' })}</p>}
    {subscription.access_held && !ended && (subscription.hold_reason === 'duplicate_trial'
      ? <Alert>This account has already used its free trial, so access for this new subscription is paused until support reviews it. Contact support@macmint.co; don't start another subscription.</Alert>
      : <Alert>Access for this subscription is paused after a refund or payment dispute. Contact support@macmint.co; renewals don't restore it automatically, and don't start another subscription.</Alert>)}
    {needsPayment && <Alert>Payment needs attention. Open billing to update your payment method or review your invoice. Do not start another subscription.</Alert>}
    {error && <Alert>{error}</Alert>}
    <div className="flex flex-wrap gap-3">
      <Button variant="secondary" onClick={manage} busy={busy}>{ended ? 'View billing history' : 'Manage billing or cancel'}</Button>
      <Button variant="secondary" onClick={onRefresh}>Refresh subscription</Button>
    </div>
    <p className="text-xs text-slate-500 dark:text-slate-400">Payment details, invoices and renewal cancellation open securely in Stripe.</p>
  </section>
}
