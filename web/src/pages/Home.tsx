import { Link } from 'react-router-dom'
import { useEffect, useState } from 'react'
import { fetchLatestRelease, type Release } from '../lib/account'
import { LogoMark } from '../components/Logo'

// Placeholder landing page. The full marketing homepage (Claude Design) replaces this component.
const features = [
  { title: 'Trash-first, always', body: 'Reviewed files go to Trash with receipts. Restore verified items while they remain there; library photos use Photos recovery.' },
  { title: 'Explains the consequences', body: 'Review rebuildable caches and logs before they move. Personal files need your explicit choice.' },
  { title: 'Complete uninstalls', body: 'Removes apps with their leftovers — without touching data shared with other apps.' },
  { title: 'Exact duplicates', body: 'Finds byte-for-byte copies and re-checks them before anything moves.' },
]

export const Home = () => {
  const [release, setRelease] = useState<Release | null>(null)
  useEffect(() => {
    let active = true
    fetchLatestRelease().then(value => { if (active) setRelease(value) })
    return () => { active = false }
  }, [])
  return (
  <div>
    <section className="mx-auto max-w-6xl px-4 pt-20 pb-16 text-center sm:px-6 sm:pt-28">
      <LogoMark className="mx-auto size-16" />
      <h1 className="mx-auto mt-8 max-w-3xl text-4xl font-semibold tracking-tight text-balance sm:text-6xl">
        A cleaner Mac, without the guesswork.
      </h1>
      <p className="mx-auto mt-6 max-w-2xl text-lg text-pretty text-slate-600 dark:text-slate-300">
        See what uses your storage, inspect recommendations, and review what moves to Trash. Useful local scanning works before sign-in; AI is optional.
      </p>
      <div className="mt-10 flex flex-col items-center justify-center gap-3 sm:flex-row">
        <a href={release?.download_url ?? '#pricing'} className="w-full rounded-lg bg-emerald-600 px-6 py-3 font-semibold text-white hover:bg-emerald-500 sm:w-auto">
          {release?.download_url ? 'Download for Mac' : 'Check availability'}
        </a>
        <Link to="/login" className="w-full rounded-lg border border-slate-300 px-6 py-3 font-semibold hover:bg-slate-50 sm:w-auto dark:border-slate-700 dark:hover:bg-slate-900">
          I have a code
        </Link>
      </div>
    </section>

    <section className="mx-auto grid max-w-6xl gap-4 px-4 pb-20 sm:grid-cols-2 sm:px-6 lg:grid-cols-4">
      {features.map((feature) => (
        <div key={feature.title} className="rounded-2xl border border-slate-200 p-6 dark:border-slate-800">
          <h2 className="font-semibold">{feature.title}</h2>
          <p className="mt-2 text-sm text-slate-600 dark:text-slate-400">{feature.body}</p>
        </div>
      ))}
    </section>

    <section id="pricing" className="border-t border-slate-200 bg-slate-50 py-20 dark:border-slate-800 dark:bg-slate-900/40">
      <div className="mx-auto max-w-md px-4 text-center">
        <h2 className="text-3xl font-semibold tracking-tight">MacMint Pro</h2>
        <p className="mt-3 text-slate-600 dark:text-slate-400">
          Inspect your Mac before choosing paid access. Sign in to see purchase availability or redeem an existing code.
        </p>
        <Link to="/signup" className="mt-8 inline-block rounded-lg bg-emerald-600 px-6 py-3 font-semibold text-white hover:bg-emerald-500">
          Create account &amp; redeem
        </Link>
      </div>
    </section>
  </div>
)
}
