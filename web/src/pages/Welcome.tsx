import { useEffect, useRef, useState, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { Alert, AuthCard, Button, Field } from '../components/Form'
import { useAuth } from '../hooks/useAuth'
import { attachPurchase, claimPurchase, fetchClaim, refreshBilling, type ClaimStatus } from '../lib/funnel'
import { formatMinor } from '../lib/offers'
import { errorMessage, pb } from '../lib/pb'

const SESSION_KEY = 'mm_welcome_session'
const SESSION = /^cs_[A-Za-z0-9_]{8,200}$/
const POLL_MILLIS = 2000
const POLL_LIMIT = 30

// Stripe's success redirect carries ?session_id=. Keep it in this tab only and remove it
// from the address bar so it is not bookmarked, shared or kept in history.
const takeSession = () => {
  const fromUrl = new URLSearchParams(window.location.search).get('session_id') ?? ''
  try {
    if (SESSION.test(fromUrl)) sessionStorage.setItem(SESSION_KEY, fromUrl)
    const stored = sessionStorage.getItem(SESSION_KEY) ?? ''
    if (fromUrl) window.history.replaceState(window.history.state, '', '/welcome')
    return SESSION.test(stored) ? stored : ''
  } catch {
    return SESSION.test(fromUrl) ? fromUrl : ''
  }
}
const forget = () => { try { sessionStorage.removeItem(SESSION_KEY) } catch { /* ignore */ } }

const SignInLink = ({ children = 'Sign in' }: { children?: string }) =>
  <Link to="/login?next=/download" className="font-semibold text-emerald-600 hover:text-emerald-500">{children}</Link>

export const Welcome = () => {
  const navigate = useNavigate()
  const { user } = useAuth()
  const [sessionId] = useState(takeSession)
  const [status, setStatus] = useState<ClaimStatus | null>(null)
  const [stalled, setStalled] = useState(false)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [otherEmail, setOtherEmail] = useState(false)
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [linkedEmail, setLinkedEmail] = useState<string | null>(null)
  const [revision, setRevision] = useState(0)
  const alive = useRef(true)

  useEffect(() => {
    // No third-party requests start here, and this page never sends a referrer.
    const meta = document.querySelector('meta[name="referrer"]') ?? Object.assign(document.head.appendChild(document.createElement('meta')), { name: 'referrer' })
    meta.setAttribute('content', 'no-referrer')
    alive.current = true
    return () => { alive.current = false }
  }, [])

  useEffect(() => {
    if (!sessionId) return
    let active = true, attempts = 0
    let timer: ReturnType<typeof setTimeout> | undefined
    const poll = async () => {
      attempts++
      try {
        const result = await fetchClaim(sessionId)
        if (!active) return
        setLoadError(null)
        setStatus(result)
        // The webhook may land after Stripe's redirect: keep checking briefly.
        if (result.state === 'processing') {
          if (attempts < POLL_LIMIT) timer = setTimeout(poll, POLL_MILLIS)
          else setStalled(true)
        }
      } catch (err) {
        if (!active) return
        if (attempts < 3) timer = setTimeout(poll, POLL_MILLIS)
        else setLoadError(errorMessage(err, 'Your purchase could not be checked.'))
      }
    }
    void poll()
    return () => { active = false; clearTimeout(timer) }
  }, [sessionId, revision])

  const finish = async (syncPending: boolean) => {
    forget()
    if (syncPending) {
      for (let attempt = 0; attempt < 3; attempt++) {
        try { await refreshBilling(); break } catch { await new Promise(resolve => setTimeout(resolve, 1500)) }
      }
    }
    if (alive.current) navigate('/download?welcome=1', { replace: true })
  }

  const attach = async () => {
    if (busy) return
    setBusy(true); setError(null)
    try {
      const result = await attachPurchase(sessionId)
      if (alive.current) await finish(result.sync_pending)
    } catch (err) {
      if (alive.current) setError(errorMessage(err, 'The purchase could not be added. Please try again.'))
    } finally {
      if (alive.current) setBusy(false)
    }
  }

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    if (busy) return
    if (password.length < 8) return setError('Use at least 8 characters for your password.')
    if (password !== confirm) return setError('The passwords don’t match.')
    setBusy(true); setError(null)
    try {
      const result = await claimPurchase(sessionId, password, otherEmail ? email.trim() : undefined)
      if (!alive.current) return
      if ('state' in result) { forget(); setLinkedEmail(result.email); return }
      pb.authStore.save(result.token, result.record as never)
      await finish(result.meta.sync_pending)
    } catch (err) {
      if (!alive.current) return
      const code = (err as { response?: { error?: string } })?.response?.error
      if (code === 'already_claimed') setStatus(current => current && { ...current, state: 'claimed' })
      else if (code === 'expired') setStatus(current => current && { ...current, state: 'expired' })
      else if (code === 'attention') setStatus(current => current && { ...current, state: 'attention' })
      else if (code === 'unverified_owner') { setStatus(current => current && { ...current, owner_unverified: true }); setOtherEmail(true) }
      setError(errorMessage(err, 'Your account could not be created. Please try again.'))
    } finally {
      if (alive.current) setBusy(false)
    }
  }

  if (!sessionId) return <AuthCard title="Setup link incomplete" subtitle="This page needs the link Stripe opened after checkout.">
    <p className="text-sm">If you’ve already set a password, <SignInLink>sign in</SignInLink>. Otherwise contact support@macmint.co with your Stripe receipt.</p>
  </AuthCard>

  if (linkedEmail || status?.state === 'existing_account') return <AuthCard title="Your trial is on your account" subtitle={`We added this purchase to the MacMint account for ${linkedEmail ?? status?.email}.`}>
    <div className="space-y-4">
      <Alert tone="success">No new account was created. Sign in with your existing password to download MacMint and activate your Mac.</Alert>
      <Link to="/login?next=/download" className="inline-flex w-full items-center justify-center rounded-lg bg-emerald-600 px-4 py-2.5 text-sm font-semibold text-white hover:bg-emerald-500">Sign in</Link>
      <p className="text-xs text-slate-500 dark:text-slate-400">Forgot it? Use “Forgot password?” on the sign-in page.</p>
    </div>
  </AuthCard>

  if (loadError) return <AuthCard title="We couldn’t check your purchase">
    <div className="space-y-4"><Alert>{loadError}</Alert><Button className="w-full" onClick={() => { setLoadError(null); setStalled(false); setRevision(value => value + 1) }}>Try again</Button></div>
  </AuthCard>

  if (!status || status.state === 'processing') return <AuthCard title="Finishing your purchase…" subtitle="Stripe is confirming your free trial. This usually takes a few seconds.">
    <div className="space-y-4" role="status">
      {!stalled ? <div className="flex items-center gap-3 text-sm"><span className="size-5 animate-spin rounded-full border-2 border-emerald-600 border-t-transparent" aria-hidden="true" />Checking with Stripe</div>
        : <><Alert tone="info">This is taking longer than usual. Your card hasn’t been charged for the trial. Check again in a minute, and don’t start another checkout.</Alert>
          <Button className="w-full" onClick={() => { setStalled(false); setRevision(value => value + 1) }}>Check again</Button></>}
    </div>
  </AuthCard>

  if (status.state !== 'ready') {
    const copy = {
      claimed: ['This purchase is already set up', 'An account was created from this link. Sign in with the email and password you chose.'],
      expired: ['This setup link has expired', 'Links stay valid for 72 hours. Contact support@macmint.co with your Stripe receipt and we’ll connect your purchase.'],
      attention: ['We need to check this purchase', 'Something about this purchase needs a quick manual review. Contact support@macmint.co. Don’t pay again.'],
      not_found: ['We couldn’t find this purchase', 'This link doesn’t match a MacMint checkout. If you were charged, contact support@macmint.co.'],
    }[status.state]
    return <AuthCard title={copy[0]}>
      <div className="space-y-4"><p className="text-sm">{copy[1]}</p>{status.state === 'claimed' && <SignInLink />}</div>
    </AuthCard>
  }

  const plan = status.plan
  const ownsBillingEmail = Boolean(user && user.verified && String(user.email ?? '').toLowerCase() === status.email)
  return <AuthCard title="Create your password" subtitle="Your free trial is active. Set a password to finish your MacMint account.">
    <form onSubmit={submit} className="space-y-4">
      {status.owner_unverified && <Alert tone="info">
        An unverified MacMint account already uses {status.email}, so this purchase wasn’t added to it. Create your account with a different sign-in email below,
        or sign in to that account, verify its email and come back to this page to add the purchase.
      </Alert>}
      {status.owner_unverified && ownsBillingEmail && <Button type="button" variant="secondary" busy={busy} className="w-full" onClick={attach}>Add this purchase to my account</Button>}
      {plan && <div className="rounded-lg border border-emerald-200 bg-emerald-50 px-3.5 py-2.5 text-sm text-emerald-900 dark:border-emerald-900/60 dark:bg-emerald-950/40 dark:text-emerald-200">
        MacMint Pro for {plan.devices} {plan.devices === 1 ? 'Mac' : 'Macs'} · {plan.trial_days}-day trial, then {formatMinor(plan.amount_minor, plan.currency)}/{plan.billing_interval}
      </div>}
      <div>
        <p className="text-sm font-medium text-slate-700 dark:text-slate-300">Email</p>
        <p className="mt-1 break-all font-medium" data-testid="billing-email">{status.email}</p>
        {!otherEmail ? <button type="button" className="mt-1 text-sm font-medium text-emerald-600 hover:text-emerald-500" onClick={() => setOtherEmail(true)}>Use a different sign-in email</button>
          : <p className="mt-1 text-xs text-slate-500 dark:text-slate-400">Receipts and billing stay with {status.email}.</p>}
      </div>
      {otherEmail && <Field label="Sign-in email" type="email" autoComplete="email" required maxLength={254} value={email} onChange={event => setEmail(event.target.value)}
        hint="We’ll ask you to verify this address once email delivery is available." />}
      <Field label="Password" type="password" autoComplete="new-password" required minLength={8} maxLength={71} value={password} onChange={event => setPassword(event.target.value)} />
      <Field label="Confirm password" type="password" autoComplete="new-password" required minLength={8} maxLength={71} value={confirm} onChange={event => setConfirm(event.target.value)} />
      {error && <Alert>{error}</Alert>}
      <Button type="submit" busy={busy} className="w-full">Create account and continue</Button>
      <p className="text-xs text-slate-500 dark:text-slate-400">Already have a MacMint account? <SignInLink /> instead — purchases for your account email are added automatically.</p>
    </form>
  </AuthCard>
}
