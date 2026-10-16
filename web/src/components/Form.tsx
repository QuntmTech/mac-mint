import type { ButtonHTMLAttributes, InputHTMLAttributes, ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { LogoMark } from './Logo'

export const AuthCard = ({ title, subtitle, children, footer }: {
  title: string
  subtitle?: ReactNode
  children: ReactNode
  footer?: ReactNode
}) => (
  <div className="mx-auto flex w-full max-w-md flex-col px-4 py-16 sm:py-24">
    <Link to="/" className="mx-auto mb-6" aria-label="MacMint home">
      <LogoMark className="size-12" />
    </Link>
    <div className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm sm:p-8 dark:border-slate-800 dark:bg-slate-900">
      <h1 className="text-2xl font-semibold tracking-tight">{title}</h1>
      {subtitle && <p className="mt-1.5 text-sm text-slate-500 dark:text-slate-400">{subtitle}</p>}
      <div className="mt-6">{children}</div>
    </div>
    {footer && <div className="mt-6 text-center text-sm text-slate-500 dark:text-slate-400">{footer}</div>}
  </div>
)

export const Field = ({ label, hint, className = '', ...props }: InputHTMLAttributes<HTMLInputElement> & {
  label: string
  hint?: string
}) => (
  <label className="block">
    <span className="text-sm font-medium text-slate-700 dark:text-slate-300">{label}</span>
    <input
      {...props}
      className={`mt-1.5 block w-full rounded-lg border border-slate-300 bg-white px-3 py-2.5 text-slate-900 shadow-xs outline-none placeholder:text-slate-400 focus:border-emerald-500 focus:ring-2 focus:ring-emerald-500/30 disabled:opacity-60 dark:border-slate-700 dark:bg-slate-950 dark:text-slate-100 ${className}`}
    />
    {hint && <span className="mt-1 block text-xs text-slate-500 dark:text-slate-400">{hint}</span>}
  </label>
)

export const Button = ({ busy, variant = 'primary', children, className = '', ...props }:
  ButtonHTMLAttributes<HTMLButtonElement> & { busy?: boolean; variant?: 'primary' | 'secondary' | 'danger' }) => {
  const styles = {
    primary: 'bg-emerald-600 text-white hover:bg-emerald-500 focus-visible:outline-emerald-600',
    secondary:
      'border border-slate-300 bg-white text-slate-700 hover:bg-slate-50 dark:border-slate-700 dark:bg-slate-900 dark:text-slate-200 dark:hover:bg-slate-800',
    danger:
      'border border-red-200 bg-white text-red-600 hover:bg-red-50 dark:border-red-900/60 dark:bg-transparent dark:text-red-400 dark:hover:bg-red-950/40',
  }
  return (
    <button
      {...props}
      disabled={busy || props.disabled}
      className={`inline-flex items-center justify-center gap-2 rounded-lg px-4 py-2.5 text-sm font-semibold transition focus-visible:outline-2 focus-visible:outline-offset-2 disabled:cursor-not-allowed disabled:opacity-60 ${styles[variant]} ${className}`}
    >
      {busy && <span className="size-4 animate-spin rounded-full border-2 border-current border-t-transparent" aria-hidden="true" />}
      {children}
    </button>
  )
}

export const Alert = ({ tone = 'error', children }: { tone?: 'error' | 'success' | 'info'; children: ReactNode }) => {
  const styles = {
    error: 'border-red-200 bg-red-50 text-red-700 dark:border-red-900/60 dark:bg-red-950/40 dark:text-red-300',
    success: 'border-emerald-200 bg-emerald-50 text-emerald-800 dark:border-emerald-900/60 dark:bg-emerald-950/40 dark:text-emerald-300',
    info: 'border-slate-200 bg-slate-50 text-slate-700 dark:border-slate-800 dark:bg-slate-900 dark:text-slate-300',
  }
  return (
    <div role={tone === 'error' ? 'alert' : 'status'} className={`rounded-lg border px-3.5 py-2.5 text-sm ${styles[tone]}`}>
      {children}
    </div>
  )
}
