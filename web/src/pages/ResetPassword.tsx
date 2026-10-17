import { useState, type FormEvent } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { Alert, AuthCard, Button, Field } from '../components/Form'
import { errorMessage, pb } from '../lib/pb'

export const ResetPassword = () => {
  const [params] = useSearchParams()
  const token = params.get('token') ?? ''
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [busy, setBusy] = useState(false)
  const [done, setDone] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    if (password.length < 8) return setError('Use at least 8 characters.')
    if (password !== confirm) return setError('Passwords don’t match.')
    setBusy(true)
    setError(null)
    try {
      await pb.collection('users').confirmPasswordReset(token, password, confirm)
      setDone(true)
    } catch (err) {
      setError(errorMessage(err, 'This reset link is invalid or has expired. Request a new one.'))
    } finally {
      setBusy(false)
    }
  }

  if (!token) {
    return (
      <AuthCard title="Reset link missing">
        <Alert>Open the link from your reset email, or <Link to="/forgot-password" className="underline">request a new one</Link>.</Alert>
      </AuthCard>
    )
  }

  return (
    <AuthCard title="Choose a new password">
      {done ? (
        <div className="space-y-4">
          <Alert tone="success">Your password was updated. Sign in on the web or in the MacMint app.</Alert>
          <Link to="/login" className="block text-center font-semibold text-emerald-600 hover:text-emerald-500">Sign in</Link>
        </div>
      ) : (
        <form onSubmit={submit} className="space-y-4">
          {error && <Alert>{error} <Link to="/forgot-password" className="underline">Request a new link</Link>.</Alert>}
          <Field label="New password" type="password" autoComplete="new-password" required minLength={8} value={password} onChange={(e) => setPassword(e.target.value)} />
          <Field label="Confirm new password" type="password" autoComplete="new-password" required value={confirm} onChange={(e) => setConfirm(e.target.value)} />
          <Button type="submit" busy={busy} className="w-full">
            Update password
          </Button>
        </form>
      )}
    </AuthCard>
  )
}
