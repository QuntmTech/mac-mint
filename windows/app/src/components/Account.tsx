// Sign in, plan and the paid-action gate (AccountViews.swift). Looking is always free; moving
// things to the Recycle Bin, uninstalling and emptying the bin need an active plan.
import { useState, type FormEvent } from "react";
import { CheckCircle2, Clock, Eye, Laptop, LayoutGrid, Leaf, Search, Trash2, WifiOff, type LucideIcon } from "lucide-react";
import { call } from "../api/client";
import type { AccountStatus } from "../api/types";
import { errorText } from "../lib/format";
import { useStore } from "../state/store";
import { Badge, Banner, Dialog, Spinner } from "./ui";

export function BrandPanel({ purpose }: { purpose: "account" | "paidAction" }) {
  return (
    <div className="brand-panel">
      <div className="row" style={{ gap: 10, marginBottom: 14 }}>
        <span className="brand-mark" style={{ width: 32, height: 32, background: "rgba(255,255,255,0.18)", boxShadow: "none" }} aria-hidden="true"><Leaf size={16} /></span>
        <div className="col"><strong style={{ fontSize: 15 }}>MacMint</strong><span style={{ fontSize: 11, opacity: 0.8, fontWeight: 600 }}>Pro</span></div>
      </div>
      <strong style={{ fontSize: 17, letterSpacing: -0.3, marginBottom: 4 }}>{purpose === "paidAction" ? "This step needs Pro" : "What Pro unlocks"}</strong>
      <Perk icon={Trash2} text="Move reviewed items to the Recycle Bin" />
      <Perk icon={LayoutGrid} text="Uninstall apps and clear their leftovers" />
      <Perk icon={CheckCircle2} text="Empty the Recycle Bin from MacMint" />
      <div className="free">
        <span className="eyebrow" style={{ color: "rgba(255,255,255,0.8)" }}>Always free</span>
        <Perk icon={Search} text="Scanning and exploring" />
        <Perk icon={Clock} text="History and Restore" />
      </div>
    </div>
  );
}

function Perk({ icon: Icon, text }: { icon: LucideIcon; text: string }) {
  return <div className="perk"><i aria-hidden="true"><Icon size={12} /></i><span style={{ paddingTop: 3 }}>{text}</span></div>;
}

export function SignInForm({ onDone }: { onDone: (status: AccountStatus) => void }) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (busy || !email || !password) return;
    setBusy(true);
    setError(null);
    try {
      onDone(await call("sign_in", { email, password }));
    } catch (err) {
      setError(errorText(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <form className="col" style={{ gap: 14 }} onSubmit={submit}>
      <div className="col" style={{ gap: 4 }}>
        <h2 style={{ fontSize: 19, letterSpacing: -0.3 }}>Sign in</h2>
        <p className="muted" style={{ fontSize: 12.5 }}>Use the same account you use on the MacMint website.</p>
      </div>
      <label className="field-label">Email
        <input className="field" type="email" autoComplete="username" value={email} onChange={(e) => setEmail(e.target.value)} data-autofocus />
      </label>
      <label className="field-label">Password
        <input className="field" type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} />
      </label>
      {error && <Banner tone="warn" icon={Eye}>{error}</Banner>}
      <button className="btn commit" type="submit" disabled={busy || !email || !password} style={{ minHeight: 34 }}>
        {busy && <Spinner />}Sign In
      </button>
      <div className="row">
        <button type="button" className="btn plain" onClick={() => void call("open_url", { url: "https://macmint.co/signup" })}>Create an account</button>
        <span className="spacer" />
        <button type="button" className="btn plain" onClick={() => void call("open_url", { url: "https://macmint.co/account" })}>Forgot password?</button>
      </div>
      <p className="caption">Scans, Storage, History and Restore work without signing in.</p>
    </form>
  );
}

/** Signed in, but this PC can't move files yet: no plan, or the plan needs checking. */
export function UnlockPanel({ status, onStatus }: { status: AccountStatus; onStatus: (s: AccountStatus) => void }) {
  const [busy, setBusy] = useState(false);
  const refresh = async () => {
    setBusy(true);
    try { onStatus(await call("refresh_account")); } finally { setBusy(false); }
  };
  return (
    <div className="col" style={{ gap: 14 }}>
      <div className="row" style={{ gap: 10 }}>
        <Badge icon={status.offline ? WifiOff : Laptop} swatch="amber" size={30} />
        <h2 style={{ fontSize: 17, letterSpacing: -0.3 }}>{status.offline ? "Couldn't check your plan" : "Unlock MacMint on this PC"}</h2>
      </div>
      <p className="muted small">Signed in as {status.email}. {status.message ?? "There's no active plan on this account yet. Bought MacMint on the website? Check again to activate this PC."}</p>
      <div className="row wrap">
        <button className="btn commit" onClick={refresh} disabled={busy}>{busy && <Spinner />}Check My Purchase</button>
        <button className="btn secondary" onClick={() => void call("open_url", { url: "https://macmint.co/#pricing" })}>Buy MacMint</button>
      </div>
    </div>
  );
}

export function AccountGateDialog() {
  const { gate, closeGate, account, accountChanged } = useStore();
  if (!gate) return null;
  return (
    <Dialog label={gate.purpose === "paidAction" ? "This step needs MacMint Pro" : "Account"} onClose={closeGate} swatch="violet">
      <div className="account-split">
        <BrandPanel purpose={gate.purpose} />
        <div className="col" style={{ padding: "22px 24px", gap: 14, overflowY: "auto" }}>
          {gate.purpose === "paidAction" && (
            <Banner tone="info" icon={CheckCircle2}>Your picks are kept. Sign in and MacMint takes you straight to the review.</Banner>
          )}
          {account?.signedIn ? <UnlockPanel status={account} onStatus={accountChanged} /> : <SignInForm onDone={accountChanged} />}
          <div className="row" style={{ marginTop: "auto" }}>
            <span className="spacer" />
            <button className="btn secondary" onClick={closeGate}>Not Now</button>
          </div>
        </div>
      </div>
    </Dialog>
  );
}
