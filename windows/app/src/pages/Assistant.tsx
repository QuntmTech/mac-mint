// Ask MacMint (AIViews.swift): an optional second opinion. It needs your consent first, it
// only advises, and it can never pick or move anything.
import { Fragment, useEffect, useRef, useState, type ReactNode } from "react";
import { Ban, Eye, Lock, Send, ShieldCheck, Sparkles, SquarePen, WandSparkles } from "lucide-react";
import { call } from "../api/client";
import { errorText } from "../lib/format";
import { useStore } from "../state/store";
import { Badge, Dialog, EmptyState, PageHeader, SheetHeader, Spinner } from "../components/ui";

interface Turn { role: "me" | "ai"; text: string; error?: boolean }

const SUGGESTIONS = [
  "What's using the most space?",
  "Is it safe to remove node_modules?",
  "Why didn't my free space go up?",
  "What is the Temp folder?",
];

// The conversation survives moving between pages.
let saved: Turn[] = [];
let savedRemaining: number | null = null;

export default function Assistant() {
  const { account, settings, go } = useStore();
  const [turns, setTurns] = useState<Turn[]>(saved);
  const [remaining, setRemaining] = useState<number | null>(savedRemaining);
  const [text, setText] = useState("");
  const [thinking, setThinking] = useState(false);
  const [consent, setConsent] = useState(false);
  const endRef = useRef<HTMLDivElement>(null);
  useEffect(() => { saved = turns; savedRemaining = remaining; endRef.current?.scrollIntoView({ block: "end", behavior: "smooth" }); }, [turns, remaining]);

  const ask = async (question: string) => {
    const q = question.trim();
    if (!q || thinking) return;
    setText("");
    setTurns((t) => [...t, { role: "me", text: q }]);
    setThinking(true);
    try {
      const answer = await call("ai_ask", { question: q });
      setTurns((t) => [...t, { role: "ai", text: answer.answer }]);
      setRemaining(answer.remaining);
    } catch (e) {
      setTurns((t) => [...t, { role: "ai", text: errorText(e), error: true }]);
    } finally {
      setThinking(false);
    }
  };

  const header = (
    <PageHeader title="Ask MacMint" icon={WandSparkles} swatch="iris" subtitle="A second opinion on your storage. AI advises; you decide.">
      {turns.length > 0 && <button className="btn secondary" onClick={() => setTurns([])}><SquarePen size={13} />New Chat</button>}
    </PageHeader>
  );

  if (!account?.aiAvailable) {
    return (
      <div className="page">
        {header}
        <EmptyState icon={Sparkles} swatch="iris" title="AI isn't available right now" trust={null}
          detail={account?.signedIn ? "MacMint AI is turned off for your account, or you're offline. Everything else works as usual." : "MacMint AI comes with MacMint Pro. Sign in to use it. Everything else works without it."}
          action={account?.signedIn ? undefined : { label: "Sign In", onClick: () => go("account") }} />
      </div>
    );
  }

  if (!settings?.aiEnabled) {
    return (
      <div className="page">
        {header}
        <div className="card col sw-iris" style={{ gap: 14, maxWidth: 680 }}>
          <div className="row" style={{ gap: 12 }}>
            <Badge icon={Sparkles} swatch="iris" size={36} />
            <div className="col"><strong style={{ fontSize: 15 }}>Turn on MacMint AI?</strong><span className="small muted">It's optional, and off until you say yes.</span></div>
          </div>
          <ConsentPoints />
          <div className="row">
            <span className="caption" style={{ flex: 1 }}>You can turn this off any time in Settings.</span>
            <button className="btn commit" onClick={() => setConsent(true)}>Review and Turn On…</button>
          </div>
        </div>
        {consent && <AIConsentDialog onClose={() => setConsent(false)} />}
      </div>
    );
  }

  return (
    <>
      <div className="page" style={{ paddingBottom: 18 }}>
        {header}
        {turns.length === 0 ? (
          <div className="card col" style={{ alignItems: "center", textAlign: "center", gap: 12, padding: "32px 24px" }}>
            <Badge icon={Sparkles} swatch="iris" size={52} glow />
            <h2 style={{ fontSize: 19 }}>Ask about your storage</h2>
            <p className="muted" style={{ maxWidth: 460 }}>Ask what a folder is, whether it's safe to remove, or what's filling your disk. AI only advises. You decide what to review.</p>
            <div className="row wrap" style={{ justifyContent: "center", gap: 8 }}>
              {SUGGESTIONS.map((s) => <button key={s} className="suggestion" onClick={() => void ask(s)}>{s}</button>)}
            </div>
          </div>
        ) : (
          <div className="chat" aria-live="polite">
            {turns.map((t, i) => (
              <div key={i} className="col" style={{ gap: 4, alignItems: t.role === "me" ? "flex-end" : "flex-start" }}>
                <div className={`bubble ${t.role}`} style={t.error ? { background: "var(--warning-tint)" } : undefined}>
                  {t.role === "ai" ? <Rich text={t.text} /> : t.text}
                </div>
                {t.role === "ai" && !t.error && <span className="caption" style={{ paddingLeft: 4 }}>AI-generated. It may be wrong; MacMint's safety rules always decide.</span>}
              </div>
            ))}
            {thinking && <div className="bubble ai row" style={{ gap: 8 }}><Spinner color="var(--iris-text)" /><span className="muted">Thinking…</span></div>}
            <div ref={endRef} />
          </div>
        )}
      </div>
      <div className="sticky-bar">
        <form className="composer" onSubmit={(e) => { e.preventDefault(); void ask(text); }}>
          <textarea rows={1} value={text} placeholder="Ask about a folder, an app or your disk…" aria-label="Your question"
            onChange={(e) => setText(e.target.value)} onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); void ask(text); } }} />
          <button className="btn commit" type="submit" disabled={!text.trim() || thinking} style={{ minHeight: 38 }}><Send size={14} />Ask</button>
        </form>
        <div className="row caption" style={{ padding: "0 var(--page-pad) 8px", background: "var(--surface)", gap: 6 }}>
          <Lock size={11} aria-hidden="true" />Your question and storage categories are sent. File contents never are.
          {remaining != null && <span style={{ marginLeft: "auto" }} className="num">{remaining} questions left this month</span>}
        </div>
      </div>
    </>
  );
}

/** Bold (**text**) and inline code (`text`) only; everything else stays plain text. */
function Rich({ text }: { text: string }) {
  const parts: ReactNode[] = [];
  text.split(/(\*\*[^*]+\*\*|`[^`]+`)/g).forEach((part, i) => {
    if (part.startsWith("**")) parts.push(<strong key={i}>{part.slice(2, -2)}</strong>);
    else if (part.startsWith("`")) parts.push(<code key={i}>{part.slice(1, -1)}</code>);
    else parts.push(<Fragment key={i}>{part}</Fragment>);
  });
  return <>{parts}</>;
}

function ConsentPoints() {
  return (
    <div className="col" style={{ gap: 10 }}>
      <Point icon={Eye} title="What's sent">Your question, recent messages in this chat, and storage categories with sizes (like "App caches, 4 GB"). Never file contents.</Point>
      <Point icon={ShieldCheck} title="What AI can do">Only advise. It can't pick, move or remove anything, and MacMint's safety rules always win.</Point>
      <Point icon={Ban} title="What to leave out">Questions are sent as you type them, so don't include private details.</Point>
    </div>
  );
}

function Point({ icon: Icon, title, children }: { icon: typeof Eye; title: string; children: ReactNode }) {
  return (
    <div className="row" style={{ alignItems: "flex-start", gap: 10 }}>
      <span className="tile-icon sw-iris" style={{ width: 26, height: 26 }} aria-hidden="true"><Icon size={13} /></span>
      <div className="col" style={{ gap: 1 }}><strong style={{ fontSize: 12.5 }}>{title}</strong><span className="small muted">{children}</span></div>
    </div>
  );
}

export function AIConsentDialog({ onClose }: { onClose: () => void }) {
  const { saveSettings } = useStore();
  return (
    <Dialog label="Turn on MacMint AI" onClose={onClose} size="md" swatch="iris">
      <SheetHeader icon={Sparkles} swatch="iris" eyebrow="Optional" title="Turn on MacMint AI?"
        subtitle="When you ask something, MacMint sends a short summary to its server, which asks Anthropic's Claude and returns advice." />
      <div className="sheet-body"><ConsentPoints /></div>
      <div className="sheet-foot">
        <span className="caption" style={{ flex: 1 }}>You can turn this off any time in Settings.</span>
        <button className="btn secondary" onClick={onClose} data-autofocus>Not Now</button>
        <button className="btn commit" onClick={() => { void saveSettings({ aiEnabled: true }); onClose(); }}>Turn On AI</button>
      </div>
    </Dialog>
  );
}
