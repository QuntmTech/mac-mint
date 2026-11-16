// Account (AccountViews.swift): sign in, your plan and this PC. Looking, History and Restore
// never need an account.
import { useState } from "react";
import { BadgeCheck, CircleUser, ExternalLink, Laptop, LogOut, RefreshCw, Sparkles, WifiOff } from "lucide-react";
import { call } from "../api/client";
import { errorText } from "../lib/format";
import { useStore } from "../state/store";
import { BrandPanel, SignInForm, UnlockPanel } from "../components/Account";
import { Badge, Banner, Chip, Dialog, PageHeader, SheetHeader, SkeletonBlock, Spinner } from "../components/ui";

export default function Account() {
  const { account, setAccount, notify } = useStore();
  const [busy, setBusy] = useState(false);
  const [confirmOut, setConfirmOut] = useState(false);

  const refresh = async () => {
    setBusy(true);
    try { setAccount(await call("refresh_account")); notify("Account checked."); } catch (e) { notify(errorText(e), "warn"); } finally { setBusy(false); }
  };
  const signOut = async () => {
    setBusy(true);
    try { setAccount(await call("sign_out")); notify("Signed out on this PC. History and exclusions stay here."); } catch (e) { notify(errorText(e), "warn"); }
    finally { setBusy(false); setConfirmOut(false); }
  };
  const initials = (account?.name ?? account?.email ?? "").split(/[\s@.]+/).filter(Boolean).slice(0, 2).map((s) => s[0]!.toUpperCase()).join("");

  return (
    <div className="page">
      <PageHeader title="Account" icon={CircleUser} swatch="violet" subtitle="Your plan and this PC. Scanning, History and Restore work without signing in." />
      {!account ? <SkeletonBlock height={320} /> : !account.signedIn ? (
        <section className="card flush" style={{ maxWidth: 820 }}>
          <div className="account-split">
            <BrandPanel purpose="account" />
            <div style={{ padding: "24px 26px" }}><SignInForm onDone={(s) => { setAccount(s); if (s.unlocked) notify("Signed in. MacMint Pro is active on this PC."); }} /></div>
          </div>
        </section>
      ) : (
        <div className="two-col" style={{ gridTemplateColumns: "minmax(0,1fr) minmax(0,1fr)" }}>
          <section className="card col" style={{ gap: 16 }}>
            <div className="row" style={{ gap: 14 }}>
              <span className="avatar lg" aria-hidden="true">{initials}</span>
              <div className="col" style={{ flex: 1, gap: 3 }}>
                <strong style={{ fontSize: 17 }}>{account.name ?? account.email}</strong>
                <span className="small muted truncate">{account.email}</span>
                <div className="row" style={{ gap: 6 }}>
                  {account.plan ? <Chip swatch="violet" icon={BadgeCheck}>MacMint {account.plan}</Chip> : <Chip swatch="slate">No plan</Chip>}
                  {account.offline && <Chip swatch="amber" icon={WifiOff}>Offline</Chip>}
                </div>
              </div>
            </div>
            {account.message && <Banner tone="info" icon={CircleUser}>{account.message}</Banner>}
            {account.unlocked ? (
              <p className="small muted">You review and confirm every removal. Billing, receipts and your devices are managed on your account page.</p>
            ) : <UnlockPanel status={account} onStatus={setAccount} />}
            <div className="row wrap" style={{ gap: 8 }}>
              <button className="btn secondary" onClick={() => void call("open_url", { url: "https://macmint.co/account" })}><ExternalLink size={13} />Manage Account</button>
              <button className="btn secondary" onClick={() => void refresh()} disabled={busy}>{busy ? <Spinner /> : <RefreshCw size={13} />}Refresh</button>
              <span className="spacer" />
              <button className="btn plain danger-text" onClick={() => setConfirmOut(true)}><LogOut size={13} />Sign Out</button>
            </div>
          </section>
          <div className="col" style={{ gap: 14 }}>
            <section className="card col" style={{ gap: 10 }}>
              <div className="row" style={{ gap: 12 }}>
                <Badge icon={Laptop} swatch="sky" size={30} />
                <div className="col" style={{ flex: 1 }}><strong>This PC</strong><span className="caption">{account.deviceName}</span></div>
                {account.unlocked ? <Chip swatch="mint" icon={BadgeCheck}>Activated</Chip> : <Chip swatch="amber">Not activated</Chip>}
              </div>
              <p className="small muted">{account.unlocked
                ? account.offline ? "You're offline. MacMint keeps working and checks your plan again when you're back online." : "This PC can move reviewed items to the Recycle Bin, uninstall apps and empty the Recycle Bin."
                : "Looking around is free. Activate this PC to move items to the Recycle Bin."}</p>
            </section>
            <section className="card col" style={{ gap: 10 }}>
              <div className="row" style={{ gap: 12 }}>
                <Badge icon={Sparkles} swatch="iris" size={30} />
                <div className="col" style={{ flex: 1 }}><strong>MacMint AI</strong><span className="caption">{account.aiAvailable ? "Included with your plan" : "Not available on this account"}</span></div>
              </div>
              <p className="small muted">Optional. Turn it on in Settings or on the Ask MacMint page.</p>
            </section>
          </div>
        </div>
      )}
      {confirmOut && (
        <Dialog label="Sign out" onClose={() => setConfirmOut(false)} size="sm" swatch="violet">
          <SheetHeader icon={LogOut} swatch="violet" title="Sign out on this PC?" subtitle="Your History and exclusions stay here. You can still scan and restore." />
          <div className="sheet-foot">
            <span className="spacer" />
            <button className="btn secondary" onClick={() => setConfirmOut(false)} data-autofocus>Cancel</button>
            <button className="btn destructive" onClick={() => void signOut()} disabled={busy}>{busy && <Spinner />}Sign Out</button>
          </div>
        </Dialog>
      )}
    </div>
  );
}
