import { Link } from 'react-router-dom'

export const LogoMark = ({ className = 'size-8' }: { className?: string }) => (
  <svg viewBox="0 0 64 64" className={className} aria-hidden="true">
    <defs>
      <linearGradient id="mm-logo" x1="0" y1="0" x2="1" y2="1">
        <stop offset="0" stopColor="#34d399" />
        <stop offset="1" stopColor="#059669" />
      </linearGradient>
    </defs>
    <rect width="64" height="64" rx="18" fill="url(#mm-logo)" />
    <path
      d="M44 18c-14 0-24 8-24 20 0 3 1 6 2 8 2-8 8-14 16-17-6 4-10 9-12 17 2 1 4 1 6 1 12 0 16-12 12-29z"
      fill="#fff"
    />
  </svg>
)

export const Logo = () => (
  <Link to="/" className="flex items-center gap-2.5 font-semibold tracking-tight">
    <LogoMark />
    <span className="text-lg">MacMint</span>
  </Link>
)
