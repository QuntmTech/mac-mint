import { useEffect, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { Alert, AuthCard } from '../components/Form'
import { errorMessage, pb } from '../lib/pb'

export const VerifyEmail = () => {
  const [params] = useSearchParams()
  const token = params.get('token') ?? ''
  const [state, setState] = useState<'working' | 'done' | 'error'>(token ? 'working' : 'error')
  const [error, setError] = useState('This verification link is missing its token.')

  useEffect(() => {
    if (!token) return
    pb.collection('users')
      .confirmVerification(token)
      .then(() => setState('done'))
      .catch((err) => {
        setError(errorMessage(err, 'This verification link is invalid or has expired.'))
        setState('error')
      })
  }, [token])

  return (
    <AuthCard title="Verify your email">
      {state === 'working' && <Alert tone="info">Verifying…</Alert>}
      {state === 'done' && <Alert tone="success">Your email is verified. Thanks!</Alert>}
      {state === 'error' && <Alert>{error}</Alert>}
      <Link to="/account" className="mt-4 block text-center font-semibold text-emerald-600 hover:text-emerald-500">
        Go to my account
      </Link>
    </AuthCard>
  )
}
