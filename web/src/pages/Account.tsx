import { InstallationSteps } from '../components/InstallationSteps'
import { BillingCard } from '../components/BillingCard'
import { useCallback, useEffect, useRef, useState, type FormEvent, type ReactNode } from 'react'
import { Navigate, useLocation, useSearchParams } from 'react-router-dom'
import { Alert, Button, Field } from '../components/Form'
import { useAuth } from '../hooks/useAuth'
import {
  fetchAccount,
  fetchLatestRelease,
  formatBytes,
  parseDate,
  redeemCode,
  removeDevice,
  type AccountSnapshot,
  type Device,
  type Entitlement,
  type Release,
} from '../lib/account'
import { errorMessage, pb } from '../lib/pb'
import { track } from '../lib/track'
import { Checkout } from '../components/Checkout'

const Card = ({ title, action, children }: { title: string; action?: ReactNode; children: ReactNode }) => (
  <section className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm dark:border-slate-800 dark:bg-slate-900">
    <div className="mb-4 flex items-center justify-between gap-4">
      <h2 className="text-lg font-semibold tracking-tight">{title}</h2>
      {action}
    </div>
    {children}
  </section>
)

const planSummary = (entitlement: Entitlement) => {
  if (entitlement.active) {
    const expires = parseDate(entitlement.expires_at)
    return {
      label: 'MacMint Pro',
      detail: expires ? `${entitlement.source === 'subscription_trial' ? 'Trial ends' : 'Active until'} ${expires.toLocaleDateString(undefined, { dateStyle: 'long' })}`
        : entitlement.expires_at === null ? 'Lifetime access' : 'Refresh your account to check the access end date',
      tone: 'active' as const,
    }
  }
  if (entitlement.plan === 'pro' && entitlement.status === 'expired') {
    return { label: 'Pro expired', detail: 'Choose paid access below or redeem another code. Local scanning and recovery remain available.', tone: 'inactive' as const }
  }
  return { label: 'No active plan', detail: 'Check purchase availability below or redeem an existing code. Local scanning and recovery remain available.', tone: 'inactive' as const }
}

const PlanCard = ({ account, checkoutResult, onRefresh }: { account: AccountSnapshot; checkoutResult: string | null; onRefresh: () => Promise<void> }) => {
  const plan = planSummary(account.entitlement)
  const limit = Math.max(account.entitlement.max_devices, account.entitlement.active ? 1 : 0)
  const subscription = account.billing?.subscription
  const heldSubscription = Boolean(subscription?.access_held) && !['canceled', 'incomplete_expired'].includes(subscription?.status ?? '')
  return (
    <Card title="Plan">
      <div className="flex flex-wrap items-center justify-between gap-4">
        <div>
          <div className="flex items-center gap-2">
            <span className={`size-2.5 rounded-full ${plan.tone === 'active' ? 'bg-emerald-500' : 'bg-amber-500'}`} aria-hidden="true" />
            <p className="text-xl font-semibold">{plan.label}</p>
          </div>
          <p className="mt-1 text-sm text-slate-500 dark:text-slate-400">{plan.detail}</p>
        </div>
        {account.entitlement.active && (
          <p className="text-sm text-slate-500 dark:text-slate-400">
            <span className="font-semibold text-slate-900 dark:text-white">{account.devices.length}</span> of {limit} Macs in use
          </p>
        )}
      </div>
      {/* An ongoing subscription held after a refund or dispute cannot be replaced by a new payment. */}
      <Checkout key={account.user.id} userId={account.user.id} verified={account.user.verified} hasPlan={account.entitlement.active || heldSubscription} returnState={checkoutResult} onRefresh={onRefresh} />
      {account.billing?.subscription && <BillingCard key={'billing-' + account.user.id} subscription={account.billing.subscription} userId={account.user.id} onRefresh={onRefresh} />}
    </Card>
  )
}

const VerificationCard = ({ email, onRefresh }: { email: string; onRefresh: () => void }) => {
  const [busy, setBusy] = useState(false)
  const [requested, setRequested] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const resend = async () => {
    setBusy(true)
    setError(null)
    setRequested(false)
    try {
      await pb.collection('users').requestVerification(email)
      setRequested(true)
    } catch (err) {
      setError(errorMessage(err, 'We could not request a verification email. Please try again later.'))
    } finally {
      setBusy(false)
    }
  }
  return <Card title="Verify your email">
    <div className="space-y-3">
      <p>Verify {email} before purchasing. Local scanning and recovery remain available.</p>
      {requested && <Alert tone="info">Verification email requested. Check your inbox and spam folder, then open the link.</Alert>}
      {error && <Alert>{error}</Alert>}
      <div className="flex flex-wrap gap-3">
        <Button onClick={resend} busy={busy}>Send verification email</Button>
        <Button variant="secondary" onClick={onRefresh}>Refresh verification status</Button>
      </div>
    </div>
  </Card>
}

const RedeemCard = ({ initialCode, onRedeemed, hasPlan }: {
  initialCode: string
  onRedeemed: (snapshot: AccountSnapshot) => void
  hasPlan: boolean
}) => {
  const [code, setCode] = useState(initialCode)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [success, setSuccess] = useState<string | null>(null)

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    setBusy(true)
    setError(null)
    setSuccess(null)
    try {
      const result = await redeemCode(code.trim())
      onRedeemed(result)
      if (!result.already_redeemed) track('redeem')
      setSuccess('Code redeemed — MacMint Pro is unlocked. Sign in on your Mac to start cleaning.')
      setCode('')
    } catch (err) {
      setError(errorMessage(err, 'That code could not be redeemed.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <Card title={hasPlan ? 'Redeem another code' : 'Redeem your code'}>
      <form onSubmit={submit} className="space-y-4">
        {error && <Alert>{error}</Alert>}
        {success && <Alert tone="success">{success}</Alert>}
        <div className="flex flex-col gap-3 sm:flex-row sm:items-end">
          <div className="flex-1">
            <Field
              label="Redemption code"
              placeholder="MINT-XXXX-XXXX-XXXX-XXXX"
              autoComplete="off"
              spellCheck={false}
              className="font-mono uppercase"
              value={code}
              onChange={(e) => setCode(e.target.value)}
              required
            />
          </div>
          <Button type="submit" busy={busy} className="sm:mb-px">
            Redeem
          </Button>
        </div>
        <p className="text-xs text-slate-500 dark:text-slate-400">
          Have a redemption code? Enter it here. Codes can only be used on one account; direct checkout activates this account automatically.
        </p>
      </form>
    </Card>
  )
}

const DownloadCard = ({ release }: { release: Release | null }) => (
  <Card title="Download MacMint">
    {release?.download_url ? (
      <div>
      <div className="flex flex-wrap items-center justify-between gap-4">
        <div>
          <p className="font-medium">Version {release.version}</p>
          <p className="text-sm text-slate-500 dark:text-slate-400">
            Requires macOS {release.min_os || '14'} or later{release.size_bytes ? ` • ${formatBytes(release.size_bytes)}` : ''}
          </p>
        </div>
        <a
          href={release.download_url}

          className={`inline-flex items-center justify-center rounded-lg px-4 py-2.5 text-sm font-semibold text-white ${
            'bg-emerald-600 hover:bg-emerald-500'
          }`}
        >
          Download for Mac
        </a>
      </div>
      <InstallationSteps downloadUrl={release.download_url} />
      </div>
    ) : (
      <p className="text-sm text-slate-500 dark:text-slate-400">
        A validated consumer build is not available yet. Check back here for the download.
      </p>
    )}
    <p className="mt-3 text-xs text-slate-500 dark:text-slate-400">Scanning, exclusions, History and Restore remain available without paid access.</p>
    <a href="/download" className="mt-3 inline-block text-sm font-semibold text-emerald-600 hover:text-emerald-500">Download page and installation guide</a>
  </Card>
)

const DevicesCard = ({ devices, onRemoved }: { devices: Device[]; onRemoved: () => void }) => {
  const [removing, setRemoving] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  const remove = async (device: Device) => {
    if (!window.confirm(`Remove “${device.name}”? MacMint on that Mac will ask to sign in again.`)) return
    setRemoving(device.device_id)
    setError(null)
    try {
      await removeDevice(device.device_id)
      onRemoved()
    } catch (err) {
      setError(errorMessage(err))
    } finally {
      setRemoving(null)
    }
  }

  return (
    <Card title="Your Macs">
      {error && <div className="mb-4"><Alert>{error}</Alert></div>}
      {devices.length === 0 ? (
        <p className="text-sm text-slate-500 dark:text-slate-400">
          No Macs yet. Open MacMint and sign in — your Mac appears here automatically.
        </p>
      ) : (
        <ul className="divide-y divide-slate-200 dark:divide-slate-800">
          {devices.map((device) => {
            const seen = parseDate(device.last_seen)
            return (
              <li key={device.id} className="flex flex-wrap items-center justify-between gap-3 py-3">
                <div className="min-w-0">
                  <p className="truncate font-medium">{device.name}</p>
                  <p className="text-sm text-slate-500 dark:text-slate-400">
                    {[device.model, device.app_version && `MacMint ${device.app_version}`, seen && `last seen ${seen.toLocaleDateString()}`]
                      .filter(Boolean)
                      .join(' • ')}
                  </p>
                </div>
                <Button variant="danger" busy={removing === device.device_id} onClick={() => remove(device)}>
                  Remove
                </Button>
              </li>
            )
          })}
        </ul>
      )}
    </Card>
  )
}

const PasswordCard = ({ email }: { email: string }) => {
  const [current, setCurrent] = useState('')
  const [next, setNext] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [done, setDone] = useState(false)

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    if (next.length < 8) return setError('Use at least 8 characters for your new password.')
    const userId = pb.authStore.record?.id
    if (!userId) return
    setBusy(true)
    setError(null)
    setDone(false)
    try {
      await pb.collection('users').update(userId, { oldPassword: current, password: next, passwordConfirm: next })
      // Changing the password invalidates existing tokens; sign back in with the new one.
      await pb.collection('users').authWithPassword(email, next)
      setCurrent('')
      setNext('')
      setDone(true)
    } catch (err) {
      setError(errorMessage(err, 'Could not change your password.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <Card title="Password">
      <form onSubmit={submit} className="space-y-4">
        {error && <Alert>{error}</Alert>}
        {done && <Alert tone="success">Password updated. Your Macs will ask you to sign in again.</Alert>}
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Current password" type="password" autoComplete="current-password" required value={current} onChange={(e) => setCurrent(e.target.value)} />
          <Field label="New password" type="password" autoComplete="new-password" required minLength={8} value={next} onChange={(e) => setNext(e.target.value)} />
        </div>
        <Button type="submit" variant="secondary" busy={busy}>
          Change password
        </Button>
      </form>
    </Card>
  )
}

export const Account = () => {
  const { user, isSignedIn, signOut } = useAuth()
  const location = useLocation()
  const [params] = useSearchParams()
  const [account, setAccount] = useState<AccountSnapshot | null>(null)
  const [release, setRelease] = useState<Release | null>(null)
  const [error, setError] = useState<string | null>(null)

  const accountGeneration = useRef(0)
  const invalidateAccount = useCallback(() => { accountGeneration.current++ }, [])
  const userId = user?.id
  const load = useCallback(async () => {
    const generation = ++accountGeneration.current
    try {
      const snapshot = await fetchAccount()
      if (generation !== accountGeneration.current || pb.authStore.record?.id !== userId || snapshot.user.id !== userId) return
      setAccount(snapshot)
      setError(null)
    } catch (err) {
      if (generation !== accountGeneration.current || pb.authStore.record?.id !== userId) return
      if ((err as { status?: number })?.status === 401) signOut()
      else setError(errorMessage(err, 'Could not load your account.'))
    }
  }, [signOut, userId])

  const checkoutResult = params.get('checkout')
  useEffect(() => {
    if (!isSignedIn) return
    let active = true
    // Start independent requests together; stale account replies cannot replace a new session.
    void Promise.resolve().then(() => { if (active) return load() })
    fetchLatestRelease().then(value => { if (active) setRelease(value) })
    return () => { active = false; invalidateAccount() }
  }, [isSignedIn, load, invalidateAccount])


  const visibleAccount = account?.user.id === userId ? account : null

  if (!isSignedIn) {
    return <Navigate to={`/login?next=${encodeURIComponent(location.pathname + location.search)}`} replace />
  }

  return (
    <div className="mx-auto max-w-3xl px-4 py-10 sm:px-6 sm:py-14">
      <div className="mb-8 flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="text-3xl font-semibold tracking-tight">Your account</h1>
          <p className="mt-1 text-slate-500 dark:text-slate-400">{visibleAccount?.user.email ?? pb.authStore.record?.email}</p>
        </div>
        <Button variant="secondary" onClick={signOut}>
          Sign out
        </Button>
      </div>

      {error && (
        <div className="mb-6">
          <Alert>
            {error}{' '}
            <button type="button" onClick={load} className="font-semibold underline">
              Try again
            </button>
          </Alert>
        </div>
      )}

      {!visibleAccount && !error ? (
        <div className="space-y-4" aria-busy="true">
          {[0, 1, 2].map((i) => (
            <div key={i} className="h-32 animate-pulse rounded-2xl bg-slate-100 dark:bg-slate-900" />
          ))}
        </div>
      ) : visibleAccount ? (
        <div className="space-y-6">
          {!visibleAccount.user.verified && <VerificationCard email={visibleAccount.user.email} onRefresh={load} />}
          <PlanCard account={visibleAccount} checkoutResult={checkoutResult} onRefresh={load} />
          <RedeemCard key={visibleAccount.user.id} initialCode={params.get('code') ?? ''} hasPlan={visibleAccount.entitlement.active} onRedeemed={snapshot => {
            if (snapshot.user.id !== userId || pb.authStore.record?.id !== userId) return
            accountGeneration.current++; setAccount(snapshot)
          }} />
          <DownloadCard release={release} />
          <DevicesCard devices={visibleAccount.devices} onRemoved={load} />
          <PasswordCard email={visibleAccount.user.email} />
        </div>
      ) : null}
    </div>
  )
}
