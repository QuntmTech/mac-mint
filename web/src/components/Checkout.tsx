import { useCallback, useEffect, useRef, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { Button, Alert } from './Form'
import { pb, errorMessage } from '../lib/pb'

import { formattedPrice, validOfferTerms, type Offer } from '../lib/offers'

type OrderStatus = { state: 'created' | 'pending' | 'fulfilled' | 'failed' | 'expired' | 'not_found'; can_start_new: boolean; offer?: Omit<Offer, 'enabled'> }
const terminalStates = new Set(['failed', 'expired'])
const restartableStates = new Set(['failed', 'expired', 'fulfilled'])

export const Checkout = ({ userId, verified, hasPlan, returnState, onRefresh }: {
  userId: string; verified: boolean; hasPlan: boolean; returnState: string | null; onRefresh: () => Promise<void>
}) => {
  const [, setParams] = useSearchParams()
  const storageKey = `mm_checkout_${userId}`
  const [stored] = useState(() => {
    try { return { key: sessionStorage.getItem(storageKey), error: false } }
    catch { return { key: null, error: true } }
  })
  const [requestKey, setRequestKey] = useState(stored.key)
  const [storageError, setStorageError] = useState(stored.error)
  const [offer, setOffer] = useState<Offer | null>(null)
  const [configError, setConfigError] = useState(false)
  const [configRevision, setConfigRevision] = useState(0)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [completed, setCompleted] = useState(false)
  const [attention, setAttention] = useState(false)
  const [status, setStatus] = useState<OrderStatus | null>(null)
  const [statusBusy, setStatusBusy] = useState(false)
  const [statusError, setStatusError] = useState<string | null>(null)
  const [automaticChecksFinished, setAutomaticChecksFinished] = useState(false)
  const alive = useRef(true)
  const statusGeneration = useRef(0)
  const purchaseInFlight = useRef(false)
  const shouldPoll = returnState === 'processing' || completed
  const processing = (shouldPoll || status?.state === 'fulfilled') && !status?.can_start_new

  const invalidateStatus = useCallback(() => { statusGeneration.current++ }, [])
  const close = useCallback(() => { alive.current = false; invalidateStatus() }, [invalidateStatus])
  useEffect(() => {
    alive.current = true
    return close
  }, [close])

  useEffect(() => {
    let active = true
    pb.send<Offer>('/api/macmint/checkout/config', { method: 'GET' })
      .then(value => {
        if (!active) return
        if (value.enabled !== false && (value.enabled !== true || !validOfferTerms(value))) throw Error('Invalid offer')
        setOffer(value)
      })
      .catch(() => { if (active) setConfigError(true) })
    return () => { active = false }
  }, [configRevision])

  const checkStatus = useCallback(async (key = requestKey) => {
    if (!key) return null
    const generation = ++statusGeneration.current
    setStatusBusy(true)
    setStatusError(null)
    try {
      const result = await pb.send<OrderStatus>('/api/macmint/checkout/status', { method: 'GET', query: { request_key: key } })
      if (!['created', 'pending', 'fulfilled', 'failed', 'expired', 'not_found'].includes(result.state) ||
          typeof result.can_start_new !== 'boolean' || (result.can_start_new && !restartableStates.has(result.state))) throw Error('Invalid checkout status')
      if (!alive.current || generation !== statusGeneration.current || pb.authStore.record?.id !== userId) return null
      setStatus(result)
      if (result.state === 'fulfilled') { setStatusBusy(false); await onRefresh() }
      return result
    } catch (err) {
      if (alive.current && generation === statusGeneration.current) setStatusError(errorMessage(err, 'Payment status could not be checked. Keep this tab open and retry the same checkout.'))
      return null
    } finally {
      if (alive.current && generation === statusGeneration.current) setStatusBusy(false)
    }
  }, [requestKey, userId, onRefresh])

  useEffect(() => {
    if (!requestKey || hasPlan) return
    let active = true
    let timer: ReturnType<typeof setTimeout> | undefined
    let attempts = 0
    let running = false
    let finished = false
    const check = async () => {
      if (!active || running || finished || attempts >= 6 || document.visibilityState === 'hidden') return
      running = true
      attempts++
      const result = await checkStatus()
      running = false
      if (!active) return
      if (result?.state === 'fulfilled' || (result && terminalStates.has(result.state))) { finished = true; return }
      if (shouldPoll && attempts < 6) timer = setTimeout(check, 3000)
      else if (shouldPoll) setAutomaticChecksFinished(true)
    }
    const visibilityChanged = () => {
      clearTimeout(timer)
      if (shouldPoll && document.visibilityState === 'visible') void check()
    }
    document.addEventListener('visibilitychange', visibilityChanged)
    void Promise.resolve().then(check)
    return () => {
      active = false; clearTimeout(timer); invalidateStatus()
      document.removeEventListener('visibilitychange', visibilityChanged)
    }
  }, [requestKey, hasPlan, shouldPoll, checkStatus, invalidateStatus])

  const refresh = async () => {
    const result = await checkStatus()
    if (result?.state !== 'fulfilled') await onRefresh()
  }

  const purchase = async () => {
    if (purchaseInFlight.current || processing || hasPlan) return
    purchaseInFlight.current = true
    setBusy(true)
    setError(null)
    setAutomaticChecksFinished(false)
    const key = requestKey ?? crypto.randomUUID()
    try {
      // A durable retry identity is required before asking the server to create a payment.
      try { sessionStorage.setItem(storageKey, key) }
      catch { setStorageError(true); return }
      setRequestKey(key)
      const result = await pb.send<{ url: string }>('/api/macmint/checkout', {
        method: 'POST', body: JSON.stringify({ request_key: key }), headers: { 'Content-Type': 'application/json' },
      })
      if (!alive.current || pb.authStore.record?.id !== userId) return
      const destination = new URL(result.url)
      if (destination.origin !== 'https://checkout.stripe.com' || destination.username || destination.password) throw new Error('Checkout address could not be verified.')
      window.location.assign(destination.href)
    } catch (err) {
      if (!alive.current || pb.authStore.record?.id !== userId) return
      const response = (err as { response?: { error?: string; request_key?: string } })?.response
      const code = response?.error
      if (code === 'checkout_in_progress') {
        const canonical = response?.request_key ?? ''
        if (/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(canonical)) {
          try { sessionStorage.setItem(storageKey, canonical); setRequestKey(canonical); setStatus(null) }
          catch { setStorageError(true) }
        } else setAttention(true)
      }
      if (code === 'checkout_attention') setAttention(true)
      if (code === 'plan_exists') { setAttention(true); await onRefresh() }
      setCompleted(code === 'checkout_complete')
      setError(errorMessage(err, 'Checkout could not be opened. Retry to resume the same payment session.'))
      // The status endpoint alone authorizes replacing a failed/expired attempt.
      if (code === 'checkout_expired') void checkStatus(key)
    } finally {
      purchaseInFlight.current = false
      if (alive.current) setBusy(false)
    }
  }

  const startNew = () => {
    if (!status?.can_start_new || !restartableStates.has(status.state)) return
    try { sessionStorage.removeItem(storageKey) }
    catch { setStorageError(true); return }
    statusGeneration.current++
    setRequestKey(null); setStatus(null); setError(null); setCompleted(false); setAttention(false); setStatusError(null); setAutomaticChecksFinished(false)
    setOffer(null); setConfigError(false)
    setConfigRevision(value => value + 1)
    setParams(params => { params.delete('checkout'); return params }, { replace: true })
  }

  if (hasPlan && returnState !== 'processing' && returnState !== 'cancelled') return null
  const canStartNew = status?.can_start_new === true && restartableStates.has(status.state)
  const checkingExisting = Boolean(requestKey && !status && !statusError)
  const blocked = !verified || processing || hasPlan || canStartNew || checkingExisting || storageError || attention
  const displayedOffer = requestKey ? status?.offer : offer
  const hasOfferTerms = displayedOffer && validOfferTerms(displayedOffer)

  return <div className="mt-5 space-y-3 border-t border-slate-200 pt-5 dark:border-slate-800">
    {hasPlan ? <Alert tone="success">Your plan is active. Sign in to MacMint on your Mac to use paid features.</Alert> : <>
      {processing && !canStartNew && <Alert tone="info">
        {status?.state === 'fulfilled' ? 'Payment is confirmed. Refresh your account if your plan has not appeared yet. Do not pay again.' : 'Payment confirmation is processing. Your plan is granted by the server after Stripe confirms payment.'}
        {!requestKey && <p className="mt-1">This tab cannot identify the original checkout. Refresh your account or return to the browser tab where you started.</p>}
        {automaticChecksFinished && <p className="mt-1">Automatic checks have paused. You can refresh your account below; do not start another payment while confirmation is pending.</p>}
      </Alert>}
      {returnState === 'cancelled' && !processing && <Alert tone="info">Checkout was closed. Resume the same checkout below. No access is granted until payment is confirmed.</Alert>}
      {storageError && <Alert>Checkout needs browser session storage to resume safely. Allow storage for this site and reload before purchasing.</Alert>}
      {statusError && <Alert>{statusError}</Alert>}
      {canStartNew && <Alert tone="info">{status!.state === 'fulfilled' ? 'Your previous subscription has ended. You can start a new subscription.' : `This checkout ${status!.state === 'failed' ? 'failed' : 'expired'}. You can start a new attempt.`}</Alert>}
      {error && <Alert>{error}</Alert>}
      {configError ? <div><p className="text-sm text-slate-500 dark:text-slate-400">Purchase availability could not be checked.</p><button className="mt-2 text-sm underline" onClick={() => { setConfigError(false); setOffer(null); setConfigRevision(value => value + 1) }}>Check purchase availability again</button></div>
        : !offer ? <p role="status" className="text-sm text-slate-500 dark:text-slate-400">Checking purchase availability…</p>
        : !offer.enabled ? <p className="text-sm text-slate-500 dark:text-slate-400">Checkout is not open yet. Local scanning and recovery do not require a paid plan.</p>
        : <>
          {requestKey && <p className="text-sm text-slate-500 dark:text-slate-400">Resume your existing checkout. Review its saved price and payment details in Stripe before confirming.</p>}
          {hasOfferTerms && <>
            <p className="text-lg font-semibold">{displayedOffer.trial_days ? `${displayedOffer.trial_days} days free, then ` : ''}{formattedPrice(displayedOffer)}{displayedOffer.billing_mode === 'subscription' ? ` / ${displayedOffer.billing_interval}` : ''} <span className="text-sm font-normal uppercase">{displayedOffer.currency}</span></p>
            <p>{displayedOffer.billing_mode === 'subscription' ? 'Recurring subscription' : displayedOffer.duration_days ? `${displayedOffer.duration_days} days of access` : 'Lifetime access'} · Up to {displayedOffer.max_devices} {displayedOffer.max_devices === 1 ? 'Mac' : 'Macs'}</p>
            {displayedOffer.billing_mode === 'subscription' && <p className="text-sm text-slate-500 dark:text-slate-400">Renews automatically each {displayedOffer.billing_interval}. Manage payment details or cancel renewal from your account. Cancellation keeps access until the paid period ends.</p>}
            {Boolean(displayedOffer.trial_days) && <p className="text-sm text-slate-500 dark:text-slate-400">A payment method is required. Cancel before the trial ends to avoid the first charge. One free trial per account.</p>}
          </>}
          <p className="text-sm text-slate-500 dark:text-slate-400">Review the final price and payment details in secure Stripe checkout before confirming. {displayedOffer?.trial_days ? 'Your trial activates after Stripe confirms checkout.' : 'Access activates after payment confirmation.'}</p>
          {!verified && <p className="text-sm text-amber-700 dark:text-amber-300">Verify your account email before purchasing.</p>}
          <Button onClick={purchase} busy={busy} disabled={blocked}>{requestKey ? 'Resume checkout' : 'Continue to checkout'}</Button>
        </>}
      {(processing || requestKey || statusError) && <Button variant="secondary" onClick={refresh} busy={statusBusy}>Refresh account</Button>}
      {canStartNew && <button className="block text-sm underline" onClick={startNew}>Start a new checkout attempt</button>}
    </>}
  </div>
}
