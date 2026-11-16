// Building blocks shared by every page, mirroring Components.swift: swatch badges, chips,
// checkboxes, segmented pills, page headers, empty and loading states, the selection bar.
import { useEffect, useId, useRef, useState, type CSSProperties, type ReactNode } from "react";
import { createPortal } from "react-dom";
import {
  AlertTriangle, Check, Eye, Lock, Minus, MoreHorizontal, RotateCw, Search, ShieldCheck, X, type LucideIcon,
} from "lucide-react";
import type { Risk } from "../api/types";
import { bytes as fmtBytes } from "../lib/format";
import type { Swatch } from "../lib/pages";

export const sw = (s: Swatch) => `sw-${s}`;

export function Badge({ icon: Icon, swatch, size = 24, glow = false, className = "" }: { icon: LucideIcon; swatch: Swatch; size?: number; glow?: boolean; className?: string }) {
  return (
    <span className={`badge ${sw(swatch)} ${glow ? "glow" : ""} ${className}`} style={{ width: size, height: size, borderRadius: size * 0.29 }} aria-hidden="true">
      <Icon size={Math.round(size * 0.52)} strokeWidth={2.2} />
    </span>
  );
}

export function TileIcon({ icon: Icon, swatch, size = 30 }: { icon: LucideIcon; swatch: Swatch; size?: number }) {
  return (
    <span className={`tile-icon ${sw(swatch)}`} style={{ width: size, height: size }} aria-hidden="true">
      <Icon size={Math.round(size * 0.5)} strokeWidth={2} />
    </span>
  );
}

export function Eyebrow({ children, color, style }: { children: ReactNode; color?: string; style?: CSSProperties }) {
  return <div className="eyebrow" style={{ color, ...style }}>{children}</div>;
}

export function Chip({ children, swatch = "slate", icon: Icon, title }: { children: ReactNode; swatch?: Swatch; icon?: LucideIcon; title?: string }) {
  return (
    <span className={`chip ${sw(swatch)}`} title={title}>
      {Icon && <Icon size={11} strokeWidth={2.6} aria-hidden="true" />}
      {children}
    </span>
  );
}

/** Safe is mint (it rebuilds), Review is amber (it needs a person), Protected is rose. */
export function RiskChip({ risk }: { risk: Risk }) {
  if (risk === "safe") return <Chip swatch="mint" icon={ShieldCheck} title="Rebuilds on its own">Safe</Chip>;
  if (risk === "review") return <Chip swatch="amber" icon={Eye} title="Look before it goes">Review</Chip>;
  return <Chip swatch="rose" icon={Lock} title="Belongs to Windows; MacMint only shows it">Protected</Chip>;
}

export function Checkbox({ state, onChange, label, disabled }: { state: boolean | "mixed"; onChange: (next: boolean) => void; label: string; disabled?: boolean }) {
  return (
    <button type="button" role="checkbox" className="check-hit" aria-checked={state} aria-label={label} disabled={disabled}
      onClick={() => onChange(state !== true)}>
      <span className="check" aria-checked={state} style={disabled ? { opacity: 0.4 } : undefined}>
        {state === true && <Check size={11} strokeWidth={3.5} />}
        {state === "mixed" && <Minus size={11} strokeWidth={3.5} />}
      </span>
    </button>
  );
}

export function Switch({ on, onChange, label, disabled }: { on: boolean; onChange: (next: boolean) => void; label: string; disabled?: boolean }) {
  return <button type="button" role="switch" className="switch" aria-checked={on} aria-label={label} disabled={disabled} onClick={() => onChange(!on)} />;
}

export interface SegOption<V> { value: V; label: string; dot?: string; count?: number }
export function Segmented<V extends string | number>({ value, options, onChange, label }: { value: V; options: SegOption<V>[]; onChange: (v: V) => void; label: string }) {
  return (
    <div className="seg" role="group" aria-label={label}>
      {options.map((o) => (
        <button key={String(o.value)} type="button" aria-pressed={o.value === value} onClick={() => onChange(o.value)}>
          {o.dot && <span className="dot" style={{ background: o.dot }} />}
          {o.label}
          {o.count !== undefined && <span className="count">{o.count}</span>}
        </button>
      ))}
    </div>
  );
}

export function SearchField({ value, onChange, placeholder }: { value: string; onChange: (v: string) => void; placeholder: string }) {
  const ref = useRef<HTMLInputElement>(null);
  return (
    <div className="search">
      <Search size={13} aria-hidden="true" />
      <input ref={ref} value={value} placeholder={placeholder} aria-label={placeholder} onChange={(e) => onChange(e.target.value)}
        onKeyDown={(e) => { if (e.key === "Escape" && value) { e.stopPropagation(); onChange(""); } }} />
      {value && (
        <button type="button" className="icon-btn" style={{ width: 20, height: 20 }} aria-label="Clear search" onClick={() => { onChange(""); ref.current?.focus(); }}>
          <X size={12} />
        </button>
      )}
    </div>
  );
}

export function PageHeader({ title, subtitle, icon, swatch, eyebrow, children }: { title: string; subtitle?: string; icon: LucideIcon; swatch: Swatch; eyebrow?: string; children?: ReactNode }) {
  return (
    <header className="page-header">
      <div className="heading">
        <Badge icon={icon} swatch={swatch} size={42} glow />
        <div className="col">
          {eyebrow && <Eyebrow color={`var(--${swatch}-text)`}>{eyebrow}</Eyebrow>}
          <h1>{title}</h1>
          {subtitle && <p className="subtitle">{subtitle}</p>}
        </div>
      </div>
      {children && <div className="actions">{children}</div>}
    </header>
  );
}

export const TRUST = {
  scanning: "Scanning only looks. Nothing moves until you review it.",
  promise: "We look · you decide · you can undo",
};

export function TrustLine({ text = TRUST.scanning }: { text?: string }) {
  return <span className="trust"><ShieldCheck size={13} aria-hidden="true" />{text}</span>;
}

export function EmptyState({ icon: Icon, title, detail, action, secondary, trust = TRUST.scanning, swatch }: {
  icon: LucideIcon; title: string; detail: string; action?: { label: string; onClick: () => void; disabled?: boolean };
  secondary?: { label: string; onClick: () => void }; trust?: string | null; swatch?: Swatch;
}) {
  return (
    <div className={`empty ${swatch ? sw(swatch) : ""}`}>
      <div className="empty-art" aria-hidden="true">
        <span className="blob" /><span className="tilt" />
        <span className="icon"><Icon size={32} strokeWidth={2} /></span>
      </div>
      <h2>{title}</h2>
      <p>{detail}</p>
      {(action || secondary) && (
        <div className="row" style={{ marginTop: 4 }}>
          {secondary && <button className="btn secondary" onClick={secondary.onClick}>{secondary.label}</button>}
          {action && <button className="btn area" onClick={action.onClick} disabled={action.disabled}>{action.label}</button>}
        </div>
      )}
      {trust && <TrustLine text={trust} />}
    </div>
  );
}

const TITLE_W = [180, 140, 210, 120, 160];
const DETAIL_W = [90, 120, 70, 110, 80];

/** What a page shows while its first results are on the way: never a blank page. */
export function LoadingState({ title, detail, icon = Search, swatch, progress, status, rows = 5, onCancel }: {
  title: string; detail: string; icon?: LucideIcon; swatch: Swatch; progress?: number | null; status?: string; rows?: number; onCancel?: () => void;
}) {
  return (
    <div className={`loading ${sw(swatch)}`} role="status" aria-live="polite">
      <div className="card stack" style={{ gap: 14 }}>
        <div className="loading-head">
          <Badge icon={icon} swatch={swatch} size={44} glow />
          <div className="col" style={{ flex: 1, gap: 4 }}>
            <div className="row"><strong style={{ fontSize: 17 }}>{title}</strong><span className="spinner" style={{ color: `var(--${swatch}-text)` }} /></div>
            <p className="muted">{detail}</p>
            {status && <span className="caption num" style={{ fontWeight: 600 }}>{status}</span>}
          </div>
          {onCancel && <button className="btn secondary sm" onClick={onCancel}>Cancel</button>}
        </div>
        {progress != null && (
          <div className="progress" role="progressbar" aria-valuenow={Math.round(progress * 100)} aria-valuemin={0} aria-valuemax={100} aria-label="Progress">
            <span style={{ width: `${Math.max(2, Math.min(100, progress * 100))}%` }} />
          </div>
        )}
      </div>
      {rows > 0 && <SkeletonRows rows={rows} />}
      <span className="trust"><Eye size={13} aria-hidden="true" />Reading only. Nothing is changed while this runs.</span>
    </div>
  );
}

export function SkeletonRows({ rows = 5 }: { rows?: number }) {
  return (
    <div className="card flush shimmer" aria-hidden="true">
      {Array.from({ length: rows }, (_, i) => (
        <div key={i}>
          {i > 0 && <div className="divider" style={{ marginLeft: 58 }} />}
          <div className="skel-row" style={{ opacity: 1 - i * (0.52 / Math.max(1, rows - 1)) }}>
            <span className="skel" style={{ width: 32, height: 32, borderRadius: 8 }} />
            <span className="col" style={{ gap: 6, flex: 1 }}>
              <span className="skel" style={{ width: TITLE_W[i % 5], height: 9 }} />
              <span className="skel soft" style={{ width: DETAIL_W[i % 5], height: 7 }} />
            </span>
            <span className="skel" style={{ width: 54, height: 9 }} />
          </div>
        </div>
      ))}
    </div>
  );
}

export function SkeletonBlock({ height, radius = 16 }: { height: number; radius?: number }) {
  return <div className="card flush shimmer" style={{ height, borderRadius: radius, background: "var(--panel)" }} aria-hidden="true" />;
}

/** A calm inline problem report with a way forward. */
export function ErrorBanner({ message, onRetry, title = "That didn't work" }: { message: string; onRetry?: () => void; title?: string }) {
  return (
    <div className="banner" role="alert">
      <AlertTriangle size={16} className="banner-icon" aria-hidden="true" />
      <div className="col" style={{ flex: 1, gap: 2 }}>
        <strong style={{ fontSize: 13 }}>{title}</strong>
        <span className="muted">{message}</span>
      </div>
      {onRetry && <button className="btn secondary sm" onClick={onRetry}><RotateCw size={12} />Try Again</button>}
    </div>
  );
}

export function Banner({ children, tone = "info", icon: Icon, action }: { children: ReactNode; tone?: "info" | "ok" | "warn"; icon: LucideIcon; action?: ReactNode }) {
  return (
    <div className={`banner ${tone === "warn" ? "" : tone}`}>
      <Icon size={16} className="banner-icon" aria-hidden="true" />
      <div style={{ flex: 1, minWidth: 0 }}>{children}</div>
      {action}
    </div>
  );
}

/** The sticky bar under lists you pick from. Nothing moves until the final check. */
export function SelectionBar({ count, total, onClear, commitLabel = "Review…", onCommit, disabled, message }: {
  count: number; total: number; onClear?: () => void; commitLabel?: string; onCommit: () => void; disabled?: boolean; message?: string;
}) {
  return (
    <div className="selection-bar">
      <span className="check" aria-checked={count > 0} aria-hidden="true">{count > 0 && <Check size={11} strokeWidth={3.5} />}</span>
      <div className="col" style={{ flex: 1, gap: 2 }}>
        <div className="row count"><span className="num">{count.toLocaleString()} selected</span><span className="faint">·</span><span className="num">{fmtBytes(total)}</span></div>
        <span className="row-sub truncate">{message ?? "Nothing is removed yet. You check everything once more before it moves to the Recycle Bin."}</span>
      </div>
      {onClear && count > 0 && <button className="btn plain" onClick={onClear}>Clear</button>}
      <button className="btn commit" onClick={onCommit} disabled={disabled || count === 0}>{commitLabel}</button>
    </div>
  );
}

export interface MenuItem { label: string; onClick: () => void; icon?: LucideIcon; danger?: boolean }
export function MoreMenu({ items, label = "More actions" }: { items: MenuItem[]; label?: string }) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const id = useId();
  useEffect(() => {
    if (!open) return;
    const close = (e: MouseEvent) => { if (!ref.current?.contains(e.target as Node)) setOpen(false); };
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("mousedown", close);
    document.addEventListener("keydown", key);
    (ref.current?.querySelector(".menu button") as HTMLButtonElement | null)?.focus();
    return () => { document.removeEventListener("mousedown", close); document.removeEventListener("keydown", key); };
  }, [open]);
  return (
    <div className="menu-wrap" ref={ref}>
      <button type="button" className="icon-btn" aria-label={label} aria-haspopup="menu" aria-expanded={open} aria-controls={id} onClick={() => setOpen(!open)}>
        <MoreHorizontal size={16} />
      </button>
      {open && (
        <div className="menu" role="menu" id={id}>
          {items.map((item) => (
            <button key={item.label} role="menuitem" type="button" className={item.danger ? "danger-text" : ""} onClick={() => { setOpen(false); item.onClick(); }}>
              {item.icon && <item.icon size={14} aria-hidden="true" />}{item.label}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

/** A modal dialog: Esc closes, focus moves inside and returns afterwards. */
export function Dialog({ children, onClose, size, label, swatch = "mint", className = "" }: {
  children: ReactNode; onClose?: () => void; size?: "sm" | "md"; label: string; swatch?: Swatch; className?: string;
}) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const before = document.activeElement as HTMLElement | null;
    const first = ref.current?.querySelector<HTMLElement>("[data-autofocus], .sheet-foot .btn.commit, button, input");
    first?.focus();
    const key = (e: KeyboardEvent) => {
      if (e.key === "Escape" && onClose) { e.preventDefault(); onClose(); }
      if (e.key === "Tab" && ref.current) {
        const focusables = Array.from(ref.current.querySelectorAll<HTMLElement>("button:not(:disabled), input, textarea, select, [tabindex='0']"));
        if (focusables.length === 0) return;
        const firstEl = focusables[0], lastEl = focusables[focusables.length - 1];
        if (e.shiftKey && document.activeElement === firstEl) { e.preventDefault(); lastEl.focus(); }
        else if (!e.shiftKey && document.activeElement === lastEl) { e.preventDefault(); firstEl.focus(); }
      }
    };
    document.addEventListener("keydown", key);
    return () => { document.removeEventListener("keydown", key); before?.focus?.(); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  return createPortal(
    <div className="scrim" onMouseDown={(e) => { if (e.target === e.currentTarget && onClose) onClose(); }}>
      <div ref={ref} className={`dialog ${size ?? ""} ${sw(swatch)} ${className}`} role="dialog" aria-modal="true" aria-label={label}>
        {children}
      </div>
    </div>,
    document.body,
  );
}

export function SheetHeader({ icon, swatch, eyebrow, title, subtitle, trailing }: { icon: LucideIcon; swatch: Swatch; eyebrow?: string; title: string; subtitle?: string; trailing?: ReactNode }) {
  return (
    <div className={`sheet-head ${sw(swatch)}`}>
      <Badge icon={icon} swatch={swatch} size={42} glow />
      <div className="col" style={{ flex: 1, gap: 2 }}>
        {eyebrow && <Eyebrow color={`var(--${swatch}-text)`}>{eyebrow}</Eyebrow>}
        <h2>{title}</h2>
        {subtitle && <p className="subtitle">{subtitle}</p>}
      </div>
      {trailing}
    </div>
  );
}

/** A thin bar in the area's color. */
export function Meter({ fraction, swatch, height = 5 }: { fraction: number | null; swatch: Swatch; height?: number }) {
  return (
    <div className={`bar ${sw(swatch)}`} style={{ height }} aria-hidden="true">
      {fraction != null && <span style={{ width: `${Math.max(0, Math.min(1, fraction)) * 100}%` }} />}
    </div>
  );
}

/** A circular gauge drawn with SVG strokes. */
export function Ring({ size, stroke, segments, track }: { size: number; stroke: number; segments: { from: number; to: number; color: string }[]; track: string }) {
  const r = (size - stroke) / 2;
  const c = 2 * Math.PI * r;
  return (
    <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} aria-hidden="true" style={{ transform: "rotate(-90deg)" }}>
      <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke={track} strokeWidth={stroke} />
      {segments.map((s, i) => {
        const len = Math.max(0, Math.min(1, s.to) - Math.max(0, s.from)) * c;
        return <circle key={i} cx={size / 2} cy={size / 2} r={r} fill="none" stroke={s.color} strokeWidth={stroke} strokeLinecap="round"
          strokeDasharray={`${len} ${c}`} strokeDashoffset={-Math.max(0, s.from) * c} />;
      })}
    </svg>
  );
}

export function Spinner({ color }: { color?: string }) {
  return <span className="spinner" style={{ color }} aria-hidden="true" />;
}
