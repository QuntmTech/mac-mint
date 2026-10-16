import { Link } from 'react-router-dom'

export const NotFound = () => (
  <div className="mx-auto max-w-md px-4 py-28 text-center">
    <p className="text-sm font-semibold text-emerald-600">404</p>
    <h1 className="mt-2 text-3xl font-semibold tracking-tight">Page not found</h1>
    <Link to="/" className="mt-8 inline-block font-semibold text-emerald-600 hover:text-emerald-500">
      Back to MacMint
    </Link>
  </div>
)
