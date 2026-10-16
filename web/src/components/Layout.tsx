import { Link, Outlet } from 'react-router-dom'
import { useAuth } from '../hooks/useAuth'
import { Logo } from './Logo'

const copyrightYear = new Date().getFullYear()

export const Layout = () => {
  const { isSignedIn } = useAuth()

  return (
    <div className="flex min-h-dvh flex-col">
      <header className="sticky top-0 z-10 border-b border-slate-200/70 bg-white/80 backdrop-blur dark:border-slate-800 dark:bg-slate-950/80">
        <nav className="mx-auto flex h-16 max-w-6xl items-center justify-between px-4 sm:px-6">
          <Logo />
          <div className="flex items-center gap-2 text-sm font-medium">
            {isSignedIn ? (
              <Link to="/account" className="rounded-lg bg-emerald-600 px-4 py-2 text-white hover:bg-emerald-500">
                My account
              </Link>
            ) : (
              <>
                <Link to="/login" className="rounded-lg px-3 py-2 text-slate-600 hover:text-slate-900 dark:text-slate-300 dark:hover:text-white">
                  Sign in
                </Link>
                <Link to="/signup" className="rounded-lg bg-emerald-600 px-4 py-2 text-white hover:bg-emerald-500">
                  Create account
                </Link>
              </>
            )}
          </div>
        </nav>
      </header>

      <main className="flex-1">
        <Outlet />
      </main>

      <footer className="border-t border-slate-200 py-8 text-sm text-slate-500 dark:border-slate-800 dark:text-slate-400">
        <div className="mx-auto flex max-w-6xl flex-col gap-3 px-4 sm:flex-row sm:items-center sm:justify-between sm:px-6">
          <p>© {copyrightYear} MacMint. Made for macOS.</p>
          <a href="mailto:support@macmint.co" className="hover:text-slate-900 dark:hover:text-white">
            support@macmint.co
          </a>
        </div>
      </footer>
    </div>
  )
}
