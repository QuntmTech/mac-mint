import { useEffect, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { Alert } from '../components/Form'
import { LogoMark } from '../components/Logo'
import { useAuth } from '../hooks/useAuth'
import { formatBytes } from '../lib/account'
import { fetchDownload, type Download as Installer } from '../lib/funnel'

const steps = (email: string | null) => [
  ['Open MacMint.dmg', 'Double-click the downloaded disk image in your Downloads folder.'],
  ['Drag MacMint to Applications', 'In the window that opens, drag the MacMint icon onto the Applications folder.'],
  ['Open MacMint', 'Open it from Applications or Launchpad. The first time, macOS asks you to confirm you want to open an app downloaded from the internet.'],
  ['Sign in with your email', `In MacMint, choose Sign In and use ${email ?? 'the email and password of your MacMint account'}. Your Mac activates on your plan automatically.`],
]

export const Download = () => {
  const { user } = useAuth()
  const [params] = useSearchParams()
  const [installer, setInstaller] = useState<Installer | null>(null)
  const [failed, setFailed] = useState(false)
  const [revision, setRevision] = useState(0)
  const email = user?.email ? String(user.email) : null

  useEffect(() => {
    document.querySelector('meta[name="referrer"]')?.setAttribute('content', 'no-referrer')
    let active = true
    fetchDownload().then(value => { if (active) setInstaller(value) }).catch(() => { if (active) setFailed(true) })
    return () => { active = false }
  }, [revision])

  const minOS = installer?.min_os ? installer.min_os.replace(/\.0$/, '') : '14'
  return (
    <div className="mx-auto max-w-3xl px-4 py-10 sm:px-6 sm:py-14">
      {params.get('welcome') === '1' && user && <div className="mb-6"><Alert tone="success">Your account is ready and your free trial has started. Download MacMint to get going.</Alert></div>}
      <section className="rounded-2xl border border-slate-200 bg-white p-6 text-center shadow-sm sm:p-10 dark:border-slate-800 dark:bg-slate-900">
        <LogoMark className="mx-auto size-16" />
        <h1 className="mt-4 text-3xl font-semibold tracking-tight">Download MacMint for Mac</h1>
        {failed ? (
          <div className="mx-auto mt-6 max-w-md"><Alert>The download could not be checked. <button type="button" className="font-semibold underline" onClick={() => { setFailed(false); setRevision(value => value + 1) }}>Try again</button></Alert></div>
        ) : !installer ? (
          <div className="mx-auto mt-6 h-12 w-64 animate-pulse rounded-xl bg-slate-100 dark:bg-slate-800" aria-busy="true" />
        ) : installer.source === 'none' ? (
          <p className="mx-auto mt-4 max-w-md text-slate-500 dark:text-slate-400">The installer isn’t published yet. Your account and trial are ready; check back here soon, or contact support@macmint.co.</p>
        ) : (
          <>
            <a href={installer.url} className="mt-6 inline-flex items-center justify-center gap-2 rounded-xl bg-emerald-600 px-6 py-3.5 text-base font-semibold text-white shadow-sm hover:bg-emerald-500 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-emerald-600">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="size-5" aria-hidden="true"><path d="M12 4v11m0 0l-4-4m4 4l4-4M5 20h14" /></svg>
              Download MacMint for Mac
            </a>
            <p className="mt-3 text-sm text-slate-500 dark:text-slate-400" data-testid="download-details">
              Version {installer.version}{installer.size_bytes ? ` · ${formatBytes(installer.size_bytes)}` : ''} · MacMint.dmg
            </p>
          </>
        )}
        <ul className="mx-auto mt-6 flex max-w-lg flex-wrap justify-center gap-x-6 gap-y-2 text-sm text-slate-600 dark:text-slate-300">
          <li>Requires macOS {minOS} or later</li>
          <li>Apple Silicon and Intel</li>
        </ul>
      </section>

      <section aria-labelledby="install-heading" className="mt-6 rounded-2xl border border-slate-200 bg-white p-6 shadow-sm dark:border-slate-800 dark:bg-slate-900">
        <h2 id="install-heading" className="text-lg font-semibold tracking-tight">Install in four steps</h2>
        <ol className="mt-4 space-y-4">
          {steps(email).map(([title, detail], index) => (
            <li key={title} className="flex gap-3">
              <span aria-hidden="true" className="flex size-7 shrink-0 items-center justify-center rounded-full bg-emerald-50 text-sm font-semibold text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300">{index + 1}</span>
              <div><p className="font-medium">{title}</p><p className="mt-0.5 text-sm leading-relaxed text-slate-600 dark:text-slate-400">{detail}</p></div>
            </li>
          ))}
        </ol>
        {installer && installer.source !== 'none' && !installer.notarized && (
          <div className="mt-5" data-testid="gatekeeper-note">
            <Alert tone="info">
              <p className="font-medium">If macOS says MacMint “can’t be opened”</p>
              <p className="mt-1">This build isn’t notarized by Apple yet. Open System Settings → Privacy &amp; Security, scroll to Security and click <strong>Open Anyway</strong> next to MacMint, then confirm. You only need to do this once.</p>
            </Alert>
          </div>
        )}
      </section>
      <p className="mt-6 text-center text-sm text-slate-500 dark:text-slate-400">
        {user ? <Link to="/account" className="font-semibold text-emerald-600 hover:text-emerald-500">Go to your account</Link>
          : <>Have an account? <Link to="/login?next=/download" className="font-semibold text-emerald-600 hover:text-emerald-500">Sign in</Link></>}
      </p>
    </div>
  )
}
