import { useState, type FormEvent } from 'react'
import { Link, Navigate, useNavigate, useSearchParams } from 'react-router-dom'
import { Alert, AuthCard, Button, Field } from '../components/Form'
import { useAuth } from '../hooks/useAuth'
import { errorMessage, pb } from '../lib/pb'
import { track } from '../lib/track'

const safeNext = (value: string | null) => (value && value.startsWith('/') && !value.startsWith('//') ? value : '/account')

export const Login = () => {
  const [params] = useSearchParams()
  const navigate = useNavigate()
  const { isSignedIn } = useAuth()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const next = safeNext(params.get('next'))

  if (isSignedIn) return <Navigate to={next} replace />

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    setBusy(true)
    setError(null)
    try {
      await pb.collection('users').authWithPassword(email.trim(), password)
      track('login')
      navigate(next, { replace: true })
    } catch (err) {
      const status = (err as { status?: number })?.status
      setError(status === 400 ? 'Incorrect email or password.' : errorMessage(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <AuthCard
      title="Sign in"
      subtitle="Use the same account you sign in with on your Mac."
      footer={
        <>
          New to MacMint?{' '}
          <Link to={`/signup${params.toString() ? `?${params}` : ''}`} className="font-semibold text-emerald-600 hover:text-emerald-500">
            Create an account
          </Link>
        </>
      }
    >
      <form onSubmit={submit} className="space-y-4">
        {error && <Alert>{error}</Alert>}
        <Field label="Email" type="email" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
        <Field label="Password" type="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)} />
        <div className="flex justify-end">
          <Link to="/forgot-password" className="text-sm font-medium text-emerald-600 hover:text-emerald-500">
            Forgot password?
          </Link>
        </div>
        <Button type="submit" busy={busy} className="w-full">
          Sign in
        </Button>
      </form>
    </AuthCard>
  )
}
