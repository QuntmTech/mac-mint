import { Sparkles } from "lucide-react";
export function Brand({ small = false }: { small?: boolean }) {
  return <span className={`brand ${small ? "brand-small" : ""}`}><span className="brand-icon"><Sparkles strokeWidth={1.8} aria-hidden="true" /></span><span>MacMint<span className="brand-dot">.</span></span></span>;
}
