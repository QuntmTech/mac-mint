export const LogoMark = ({ className = 'size-8' }: { className?: string }) => (
  <img src="/mark.svg" alt="" aria-hidden="true" className={className} />
)

export const Logo = () => (
  <a href="/" className="flex items-center gap-2.5 font-semibold tracking-tight" aria-label="MacMint home">
    <LogoMark />
    <span className="text-lg">MacMint</span>
  </a>
)
