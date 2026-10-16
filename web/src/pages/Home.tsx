import { Link } from 'react-router-dom'
import { LogoMark } from '../components/Logo'

// Placeholder landing page. The full marketing homepage (Claude Design) replaces this component.
const features = [
  { title: 'Trash-first, always', body: 'Every cleanup goes to the Trash with a receipt, so anything can be restored.' },
  { title: 'Knows what’s safe', body: 'Caches and logs are cleaned automatically; personal files always need your review.' },
  { title: 'Complete uninstalls', body: 'Removes apps with their leftovers — without touching data shared with other apps.' },
  { title: 'Exact duplicates', body: 'Finds byte-for-byte copies and re-checks them before anything moves.' },
]

export const Home = () => (
  <div>
    <section className="mx-auto max-w-6xl px-4 pt-20 pb-16 text-center sm:px-6 sm:pt-28">
      <LogoMark className="mx-auto size-16" />
      <h1 className="mx-auto mt-8 max-w-3xl text-4xl font-semibold tracking-tight text-balance sm:text-6xl">
        A cleaner Mac, without the guesswork.
      </h1>
      <p className="mx-auto mt-6 max-w-2xl text-lg text-pretty text-slate-600 dark:text-slate-300">
        MacMint finds the junk slowing your Mac down, explains every item, and only ever moves things to the Trash.
      </p>
      <div className="mt-10 flex flex-col items-center justify-center gap-3 sm:flex-row">
        <a href="#pricing" className="w-full rounded-lg bg-emerald-600 px-6 py-3 font-semibold text-white hover:bg-emerald-500 sm:w-auto">
          Get MacMint
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
          Checkout is opening soon. Already purchased? Create an account and redeem the code from your email.
        </p>
        <Link to="/signup" className="mt-8 inline-block rounded-lg bg-emerald-600 px-6 py-3 font-semibold text-white hover:bg-emerald-500">
          Create account &amp; redeem
        </Link>
      </div>
    </section>
  </div>
)
