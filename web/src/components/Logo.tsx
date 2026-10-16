import { Link } from 'react-router-dom'

export const LogoMark = ({ className = 'size-8' }: { className?: string }) => (
  <img src="/mark.svg" alt="" aria-hidden="true" className={className} />
)

export const Logo = () => (
  <Link to="/" className="flex items-center gap-2.5 font-semibold tracking-tight">
    <LogoMark />
    <span className="text-lg">MacMint</span>
  </Link>
)
