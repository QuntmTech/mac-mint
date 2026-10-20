import { useEffect, useState, type FormEvent, type ReactNode } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { Alert, Button, Field } from '../components/Form'
import { LogoMark } from '../components/Logo'
import { useAuth } from '../hooks/useAuth'
import { fetchPlans, monthlyMinor, savingsPercent, startTrial, type Tier } from '../lib/funnel'
import { formatMinor } from '../lib/offers'
import { errorMessage } from '../lib/pb'

const EMAIL_KEY = 'mm_start_email'
const readEmail = () => { try { return sessionStorage.getItem(EMAIL_KEY) ?? '' } catch { return '' } }
const saveEmail = (value: string) => { try { sessionStorage.setItem(EMAIL_KEY, value) } catch { /* storage is optional here */ } }
const devicesLabel = (count: number) => `${count} ${count === 1 ? 'Mac' : 'Macs'}`
const period = (tier: Tier) => tier.billing_interval === 'year' ? 'year' : 'month'

const Icon = ({ path }: { path: string }) => (
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" className="size-5 shrink-0 text-emerald-600 dark:text-emerald-400" aria-hidden="true">
    <path d={path} />
  </svg>
)
const trust: [string, string, string][] = [
  ['Cancel anytime', 'From your account, before the trial ends', 'M4 12a8 8 0 0 1 14-5.3M20 12a8 8 0 0 1-14 5.3M18 3v4h-4M6 21v-4h4'],
  ['Secure payment', 'Card details stay with Stripe', 'M12 3l7 3v6c0 4.5-3 7.5-7 9-4-1.5-7-4.5-7-9V6l7-3z'],
  ['Instant activation', 'Sign in on your Mac right after checkout', 'M13 3L4 14h7l-1 7 9-11h-7l1-7z'],
]

const Row = ({ label, children }: { label: string; children: ReactNode }) => (
  <div className="flex flex-col gap-1 border-t border-slate-200 py-4 sm:flex-row sm:items-center sm:justify-between dark:border-slate-800">
    <span className="text-sm font-medium text-slate-500 dark:text-slate-400">{label}</span>
    <div>{children}</div>
  </div>
)

export const Start = () => {
  const { user } = useAuth()
  const [params, setParams] = useSearchParams()
  const [tiers, setTiers] = useState<Tier[] | null>(null)
  const [closed, setClosed] = useState(false)
  const [loadError, setLoadError] = useState(false)
  const [revision, setRevision] = useState(0)
  const [email, setEmail] = useState(() => readEmail() || String(user?.email ?? ''))
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [refusal, setRefusal] = useState<'trial_used' | 'active_plan' | null>(null)
  const [today] = useState(() => Date.now())

  useEffect(() => {
    let active = true
    fetchPlans()
      .then(plans => { if (!active) return; if (plans.enabled) setTiers(plans.tiers!); else setClosed(true) })
      .catch(() => { if (active) setLoadError(true) })
    return () => { active = false }
  }, [revision])

  const selected = tiers?.find(tier => tier.tier === params.get('tier')) ?? tiers?.[0]
  const choose = (tier: Tier) => {
    setRefusal(null); setError(null)
    // Keeps the tier in the address so returning from Stripe lands on the same choice.
    setParams(current => { current.set('tier', tier.tier); return current }, { replace: true })
  }

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    if (!selected || busy) return
    setBusy(true); setError(null); setRefusal(null)
    const address = email.trim()
    saveEmail(address)
    try {
      window.location.assign(await startTrial(address, selected.tier))
    } catch (err) {
      const code = (err as { response?: { error?: string } })?.response?.error
      if (code === 'trial_used' || code === 'active_plan') setRefusal(code)
      else setError(errorMessage(err, 'Checkout could not be opened. Please try again.'))
      setBusy(false)
    }
  }

  const trialEnds = selected ? new Date(today + selected.trial_days * 86400000).toLocaleDateString(undefined, { dateStyle: 'long' }) : ''
  const price = selected && formatMinor(selected.amount_minor, selected.currency)
  const monthly = selected && formatMinor(monthlyMinor(selected), selected.currency)

  return (
    <div className="mx-auto max-w-5xl px-4 py-10 sm:px-6 sm:py-14">
      <div className="text-center">
        <p className="text-sm font-semibold text-emerald-600 dark:text-emerald-400">MacMint Pro</p>
        <h1 className="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl">Let’s choose your plan</h1>
        <p className="mt-2 text-slate-500 dark:text-slate-400">Try every Pro feature free for 7 days. Local scanning and Restore stay free.</p>
      </div>

      {loadError ? (
        <div className="mx-auto mt-10 max-w-md"><Alert>Plans could not be loaded. <button type="button" className="font-semibold underline" onClick={() => { setLoadError(false); setRevision(value => value + 1) }}>Try again</button></Alert></div>
      ) : closed ? (
        <div className="mx-auto mt-10 max-w-md"><Alert tone="info">Checkout isn’t open yet. Local scanning, History and Restore don’t need a paid plan.</Alert></div>
      ) : !tiers || !selected ? (
        <div className="mx-auto mt-10 grid max-w-4xl gap-6 lg:grid-cols-[1fr_380px]" aria-busy="true">
          <div className="h-80 animate-pulse rounded-2xl bg-slate-100 dark:bg-slate-900" />
          <div className="h-80 animate-pulse rounded-2xl bg-slate-100 dark:bg-slate-900" />
        </div>
      ) : (
        <form onSubmit={submit} className="mx-auto mt-10 grid max-w-4xl items-start gap-6 lg:grid-cols-[1fr_380px]">
          <section aria-label="Plan" className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm dark:border-slate-800 dark:bg-slate-900">
            <div className="flex items-center gap-4 pb-4">
              <LogoMark className="size-12" />
              <div>
                <h2 className="text-lg font-semibold tracking-tight">MacMint Pro, Annual</h2>
                <p className="text-sm text-slate-500 dark:text-slate-400">Reviewed cleanup, app removal and recovery for your Macs</p>
              </div>
            </div>
            <Row label="Plan type"><span className="font-medium">One-year subscription</span></Row>
            <fieldset className="border-t border-slate-200 pt-4 dark:border-slate-800">
              <legend className="float-left mb-3 w-full text-sm font-medium text-slate-500 dark:text-slate-400">Number of devices</legend>
              <div className="clear-both grid gap-3 sm:grid-cols-3">
                {tiers.map(tier => {
                  const saving = savingsPercent(tier, tiers[0])
                  const checked = tier.tier === selected.tier
                  return (
                    <label key={tier.tier} className={`relative flex cursor-pointer flex-col rounded-xl border p-4 transition focus-within:ring-2 focus-within:ring-emerald-500/40 ${checked
                      ? 'border-emerald-500 bg-emerald-50/70 dark:border-emerald-500 dark:bg-emerald-950/30' : 'border-slate-200 hover:border-slate-300 dark:border-slate-700 dark:hover:border-slate-600'}`}>
                      <input type="radio" name="tier" value={tier.tier} checked={checked} onChange={() => choose(tier)} className="sr-only"
                        aria-label={`${devicesLabel(tier.devices)}, ${formatMinor(tier.amount_minor, tier.currency)} per ${period(tier)}`} />
                      <span className="text-base font-semibold">{devicesLabel(tier.devices)}</span>
                      <span className="mt-1 text-sm">{formatMinor(tier.amount_minor, tier.currency)}/{tier.billing_interval === 'year' ? 'yr' : 'mo'}</span>
                      {tier.billing_interval === 'year' && <span className="text-xs text-slate-500 dark:text-slate-400">≈ {formatMinor(monthlyMinor(tier), tier.currency)}/mo</span>}
                      {saving > 0 && <span className="mt-2 inline-flex w-fit whitespace-nowrap rounded-full bg-emerald-600 px-2 py-0.5 text-[11px] font-semibold text-white">Save {saving}% per Mac</span>}
                      {checked && <span className="absolute right-3 top-3 flex size-5 items-center justify-center rounded-full bg-emerald-600 text-white" aria-hidden="true">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" className="size-3"><path d="M5 12l5 5L20 7" /></svg>
                      </span>}
                    </label>
                  )
                })}
              </div>
            </fieldset>
            <ul className="mt-6 grid gap-4 border-t border-slate-200 pt-5 dark:border-slate-800" aria-label="Why MacMint">
              {trust.map(([title, detail, path]) => (
                <li key={title} className="flex gap-3 text-sm">
                  <Icon path={path} />
                  <span><span className="block font-medium">{title}</span><span className="text-slate-500 dark:text-slate-400">{detail}</span></span>
                </li>
              ))}
            </ul>
          </section>

          <section aria-label="Order summary" className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm lg:sticky lg:top-24 dark:border-slate-800 dark:bg-slate-900">
            <div className="flex items-baseline justify-between">
              <span className="text-sm font-medium text-slate-500 dark:text-slate-400">Pay now</span>
              <span data-testid="pay-now" className="text-3xl font-semibold tracking-tight">{formatMinor(0, selected.currency)}</span>
            </div>
            <p data-testid="after-trial" className="mt-2 text-sm text-slate-600 dark:text-slate-300">
              After {selected.trial_days}-day trial: <strong className="font-semibold text-slate-900 dark:text-white">{price}/{period(selected)}</strong>
              {selected.billing_interval === 'year' && <> (≈ {monthly}/month), billed annually</>}
            </p>
            <p className="mt-1 text-xs text-slate-500 dark:text-slate-400">{devicesLabel(selected.devices)} · {selected.currency.toUpperCase()}</p>
            <div className="mt-6 space-y-4">
              <Field label="Email" type="email" autoComplete="email" required maxLength={254} value={email}
                hint="We’ll fill it in at Stripe. It becomes your MacMint sign-in." onChange={event => setEmail(event.target.value)} />
              {refusal && <Alert tone="info">
                {refusal === 'trial_used' ? 'This email has already used its free trial.' : 'This email already has an active MacMint plan.'}{' '}
                <Link to="/login?next=/account" className="font-semibold underline">Sign in</Link>
                {refusal === 'trial_used' ? ' to buy MacMint Pro without a trial.' : ' to manage it.'}
              </Alert>}
              {error && <Alert>{error}</Alert>}
              <Button type="submit" busy={busy} className="w-full py-3 text-base">Start free trial</Button>
            </div>
            <p data-testid="fine-print" className="mt-4 text-xs leading-relaxed text-slate-500 dark:text-slate-400">
              A card is required to start your free trial. You won’t be charged today. Unless you cancel before {trialEnds}, your subscription
              renews automatically and {price} per {period(selected)} is charged to your card each {period(selected)} until you cancel.
              Cancel anytime in your account under Manage billing. Taxes may apply. One free trial per person.
            </p>
          </section>
        </form>
      )}
      <p className="mt-10 text-center text-sm text-slate-500 dark:text-slate-400">
        Already have an account? <Link to="/login?next=/account" className="font-semibold text-emerald-600 hover:text-emerald-500">Sign in</Link>
      </p>
    </div>
  )
}
