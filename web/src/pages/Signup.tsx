import { useEffect, useState, type FormEvent } from 'react'
import { Link, Navigate, useNavigate, useSearchParams } from 'react-router-dom'
import { Alert, AuthCard, Button, Field } from '../components/Form'
import { useAuth } from '../hooks/useAuth'
import { errorMessage, pb } from '../lib/pb'
import { track } from '../lib/track'

export const Signup = () => {
  const [params] = useSearchParams()
  const navigate = useNavigate()
  const { isSignedIn } = useAuth()
  const [name, setName] = useState('')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const code = params.get('code')
  const destination = code ? `/account?code=${encodeURIComponent(code)}` : '/account'

  useEffect(() => track('signup_view'), [])

  if (isSignedIn) return <Navigate to={destination} replace />

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    if (password.length < 8) {
      setError('Use at least 8 characters for your password.')
      return
    }
    setBusy(true)
    setError(null)
    try {
      const trimmedEmail = email.trim()
      await pb.collection('users').create({ name: name.trim(), email: trimmedEmail, password, passwordConfirm: password })
      await pb.collection('users').authWithPassword(trimmedEmail, password)
      track('signup')
      pb.collection('users').requestVerification(trimmedEmail).catch(() => undefined)
      navigate(destination, { replace: true })
    } catch (err) {
      setError(errorMessage(err, "We couldn't create your account."))
    } finally {
      setBusy(false)
    }
  }

  return (
    <AuthCard
      title="Create your account"
      subtitle={code ? 'Create an account to redeem your MacMint code.' : 'You’ll use this account to sign in to MacMint on your Mac.'}
      footer={
        <>
          Already have an account?{' '}
          <Link to={`/login${params.toString() ? `?${params}` : ''}`} className="font-semibold text-emerald-600 hover:text-emerald-500">
            Sign in
          </Link>
        </>
      }
    >
      <form onSubmit={submit} className="space-y-4">
        {error && <Alert>{error}</Alert>}
        <Field label="Name" autoComplete="name" value={name} onChange={(e) => setName(e.target.value)} />
        <Field label="Email" type="email" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
        <Field
          label="Password"
          type="password"
          autoComplete="new-password"
          required
          minLength={8}
          hint="At least 8 characters."
          value={password}
          onChange={(e) => setPassword(e.target.value)}
        />
        <Button type="submit" busy={busy} className="w-full">
          Create account
        </Button>
      </form>
    </AuthCard>
  )
}
