import { useState, type FormEvent } from 'react'
import { Link } from 'react-router-dom'
import { Alert, AuthCard, Button, Field } from '../components/Form'
import { errorMessage, pb } from '../lib/pb'

export const ForgotPassword = () => {
  const [email, setEmail] = useState('')
  const [busy, setBusy] = useState(false)
  const [sent, setSent] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    setBusy(true)
    setError(null)
    try {
      await pb.collection('users').requestPasswordReset(email.trim())
      setSent(true)
    } catch (err) {
      setError(errorMessage(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <AuthCard
      title="Reset your password"
      subtitle="We’ll email you a link to choose a new password."
      footer={<Link to="/login" className="font-semibold text-emerald-600 hover:text-emerald-500">Back to sign in</Link>}
    >
      {sent ? (
        <Alert tone="success">If an account exists for {email.trim()}, a reset link is on its way. Check your inbox.</Alert>
      ) : (
        <form onSubmit={submit} className="space-y-4">
          {error && <Alert>{error}</Alert>}
          <Field label="Email" type="email" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
          <Button type="submit" busy={busy} className="w-full">
            Send reset link
          </Button>
        </form>
      )}
    </AuthCard>
  )
}
