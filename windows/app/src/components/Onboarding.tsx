// First run: three short steps (OnboardingView.swift), then an optional one-minute tour of
// pop-ups pointing at the sidebar (GuidedTour.swift). Neither changes anything on the PC.
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import {
  Check, Eye, FileLock2, Hand, Leaf, ListChecks, Map as MapIcon, Radar, RefreshCw, Search, ShieldCheck, Trash2, Undo2, UserRound, WifiOff,
  CircleHelp, Gauge, History, type LucideIcon,
} from "lucide-react";
import { AREAS, AREA_BLURB, PAGES, type Swatch } from "../lib/pages";
import type { Page } from "../api/types";
import { useStore } from "../state/store";
import { Badge, Eyebrow, Switch, sw } from "./ui";

const STEPS = [
  { title: "Welcome", detail: "What MacMint does" },
  { title: "Safety", detail: "How it stays careful" },
  { title: "Ready", detail: "Pick how to start" },
];

export function Onboarding() {
  const { onboarding, finishOnboarding, settings, saveSettings } = useStore();
  const [step, setStep] = useState(0);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!onboarding) return;
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") finishOnboarding("later"); };
    document.addEventListener("keydown", key);
    return () => document.removeEventListener("keydown", key);
  }, [onboarding, finishOnboarding]);
  useEffect(() => { ref.current?.querySelector<HTMLElement>(".onboard-main .btn.commit, .choice")?.focus(); }, [step, onboarding]);
  if (!onboarding) return null;

  return createPortal(
    <div className="scrim">
      <div className="onboard" role="dialog" aria-modal="true" aria-label="Set up MacMint" ref={ref}>
        <aside className="onboard-side">
          <div className="row" style={{ gap: 10, marginBottom: 26 }}>
            <span className="brand-mark" style={{ width: 34, height: 34, background: "rgba(255,255,255,0.18)", boxShadow: "none" }} aria-hidden="true"><Leaf size={17} /></span>
            <div className="col"><strong style={{ fontSize: 15 }}>MacMint</strong><span style={{ fontSize: 11, opacity: 0.78 }}>Setup</span></div>
          </div>
          <span className="eyebrow" style={{ color: "rgba(255,255,255,0.78)", padding: "0 10px 8px" }}>Three steps</span>
          <div className="col" style={{ gap: 4 }}>
            {STEPS.map((s, i) => (
              <div key={s.title} className={`ob-step ${i === step ? "current" : ""} ${i < step ? "done" : ""}`} aria-current={i === step ? "step" : undefined}>
                <span className="n">{i < step ? <Check size={11} strokeWidth={3.5} /> : i + 1}</span>
                <div className="col"><span style={{ fontSize: 13, fontWeight: i === step ? 700 : 500 }}>{s.title}</span><span style={{ fontSize: 11, opacity: i === step ? 0.88 : 0.7 }}>{s.detail}</span></div>
              </div>
            ))}
          </div>
          <div className="spacer" />
          <div className="col" style={{ gap: 8, padding: 12, borderRadius: 12, background: "rgba(255,255,255,0.12)" }} aria-label="We look, you decide, you can undo">
            <SidePromise icon={Eye} text="We look" />
            <SidePromise icon={Hand} text="You decide" />
            <SidePromise icon={Undo2} text="You can undo" />
          </div>
        </aside>
        <div className="onboard-main">
          <div className="onboard-body">
            {step === 0 && <Welcome />}
            {step === 1 && <Safety />}
            {step === 2 && (
              <div className="col" style={{ gap: 16 }}>
                <Heading eyebrow="Ready" title="Pick how to start" subtitle="Smart Scan only reads. You'll see what it found before anything moves." />
                <button className="choice" onClick={() => finishOnboarding("tour")}>
                  <Badge icon={MapIcon} swatch="iris" size={36} />
                  <div className="col" style={{ gap: 2 }}><strong>Show me around</strong><span className="small muted">A one-minute tour while Smart Scan looks around. Nothing is removed.</span></div>
                </button>
                <button className="choice primary" onClick={() => finishOnboarding("scan")}>
                  <Badge icon={Radar} swatch="mint" size={36} />
                  <div className="col" style={{ gap: 2 }}><strong>Jump right in</strong><span className="small muted">Skip the tour and run Smart Scan now. It only reads.</span></div>
                </button>
                <div className="card tight col" style={{ gap: 10 }}>
                  <strong style={{ fontSize: 13.5 }}>Optional helpers</strong>
                  <div className="row">
                    <RefreshCw size={15} className="muted" aria-hidden="true" />
                    <span className="small" style={{ flex: 1 }}>Check for MacMint updates automatically</span>
                    <Switch on={settings?.checkUpdatesAutomatically ?? true} label="Check for updates automatically" onChange={(v) => void saveSettings({ checkUpdatesAutomatically: v })} />
                  </div>
                  <div className="row">
                    <UserRound size={15} className="muted" aria-hidden="true" />
                    <span className="small muted" style={{ flex: 1 }}>Sign in any time from the round button at the top right. Looking is free; moving items needs MacMint Pro.</span>
                  </div>
                </div>
              </div>
            )}
          </div>
          <div className="sheet-foot">
            <span className="small muted num">Step {step + 1} of 3</span>
            <span className="spacer" />
            {step < 2 && <button className="btn plain" onClick={() => finishOnboarding("later")}>Set Up Later</button>}
            {step > 0 && <button className="btn secondary" onClick={() => setStep(step - 1)}>Back</button>}
            {step < 2 && <button className="btn commit" onClick={() => setStep(step + 1)}>Continue</button>}
          </div>
        </div>
      </div>
    </div>,
    document.body,
  );
}

function SidePromise({ icon: Icon, text }: { icon: LucideIcon; text: string }) {
  return <div className="row" style={{ gap: 8, fontSize: 12, fontWeight: 600 }}><Icon size={13} aria-hidden="true" />{text}</div>;
}

function Heading({ eyebrow, title, subtitle }: { eyebrow: string; title: string; subtitle: string }) {
  return (
    <div className="col" style={{ gap: 4 }}>
      <Eyebrow color="var(--mint-text)">{eyebrow}</Eyebrow>
      <h2 style={{ fontSize: 24, letterSpacing: -0.55 }}>{title}</h2>
      <p className="muted">{subtitle}</p>
    </div>
  );
}

function Welcome() {
  return (
    <>
      <Heading eyebrow="Welcome" title="Welcome to MacMint" subtitle="See what fills your PC, choose what can go, and keep a way back." />
      <div style={{ display: "grid", gridTemplateColumns: "repeat(3, minmax(0, 1fr))", gap: 10 }}>
        <PromiseCard icon={Search} swatch="mint" title="We look" text="Smart Scan only reads. Scans and History work without an account." />
        <PromiseCard icon={ListChecks} swatch="sky" title="You decide" text="A scan never removes anything. Personal files always need your choice." />
        <PromiseCard icon={Undo2} swatch="indigo" title="You can undo" text="Items go to the Recycle Bin with a receipt. Restore them from History." />
      </div>
      <div className="col" style={{ gap: 10 }}>
        <strong style={{ fontSize: 15 }}>Where everything lives</strong>
        <div className="card" style={{ padding: 12, display: "grid", gridTemplateColumns: "repeat(2, minmax(0, 1fr))", gap: "10px 12px", borderRadius: 14 }}>
          {AREAS.map((p) => (
            <div key={p} className="row" style={{ gap: 10 }}>
              <Badge icon={PAGES[p].icon} swatch={PAGES[p].swatch} size={26} />
              <div className="col"><span style={{ fontSize: 12.5, fontWeight: 600 }}>{PAGES[p].title}</span><span className="caption truncate">{AREA_BLURB[p]}</span></div>
            </div>
          ))}
        </div>
      </div>
    </>
  );
}

function PromiseCard({ icon, swatch, title, text }: { icon: LucideIcon; swatch: Swatch; title: string; text: string }) {
  return (
    <div className="card col" style={{ padding: 12, gap: 8, borderRadius: 14 }}>
      <Badge icon={icon} swatch={swatch} size={30} />
      <strong style={{ fontSize: 13.5 }}>{title}</strong>
      <span className="caption" style={{ color: "var(--ink2)" }}>{text}</span>
    </div>
  );
}

function Safety() {
  const rows: [LucideIcon, Swatch, string, string][] = [
    [Trash2, "mint", "Recycle Bin first", "Nothing is deleted. Items go to the Recycle Bin, and History keeps a receipt so you can put them back."],
    [ShieldCheck, "sky", "Open files are left alone", "If an app is using something, MacMint skips it and tells you why."],
    [FileLock2, "indigo", "Your files stay yours", "Documents, Desktop and Pictures are never picked for you. Large files and duplicates always wait for your choice."],
    [Eye, "amber", "Windows stays in charge", "Folders that belong to Windows or need an administrator are only measured, never changed."],
    [WifiOff, "slate", "No tracking", "No analytics. File contents never leave this PC."],
  ];
  return (
    <>
      <Heading eyebrow="Safety" title="How MacMint stays careful" subtitle="The same rules apply on every page, every time." />
      <div className="card flush">
        {rows.map(([icon, swatch, title, text], i) => (
          <div key={title} className="row" style={{ gap: 12, padding: "12px 16px", borderTop: i ? "1px solid var(--divider)" : 0, alignItems: "flex-start" }}>
            <Badge icon={icon} swatch={swatch} size={30} />
            <div className="col" style={{ gap: 2 }}><strong style={{ fontSize: 13 }}>{title}</strong><span className="small muted">{text}</span></div>
          </div>
        ))}
      </div>
    </>
  );
}

// MARK: Guided tour

interface TourStep { target: string; page: Page | null; title: string; message: string; icon: LucideIcon; swatch: Swatch }

export const TOUR: TourStep[] = [
  { target: "map", page: "overview", title: "Where everything lives", icon: MapIcon, swatch: "mint",
    message: "Seven areas, each with its own color. Pick one to open it. Tabs at the top of a page hold related pages." },
  { target: "scan", page: "overview", title: "Smart Scan", icon: Radar, swatch: "mint",
    message: "Checks temp files, caches, old downloads and build folders. It only looks. Nothing moves until you review it." },
  { target: "tab-performance", page: "overview", title: "Tabs", icon: Gauge, swatch: "sky",
    message: "Related pages sit in tabs. Performance shows which apps are using memory and CPU right now." },
  { target: "area-history", page: "history", title: "History and Restore", icon: History, swatch: "slate",
    message: "Everything MacMint moved to the Recycle Bin, with a Restore button while it's still there." },
  { target: "account", page: null, title: "Your account", icon: UserRound, swatch: "violet",
    message: "Scanning and looking are always free. Moving items to the Recycle Bin needs MacMint Pro." },
  { target: "help", page: null, title: "Help is here", icon: CircleHelp, swatch: "graphite",
    message: "Answers, tips and this tour live under the ? at the bottom of the sidebar." },
];

const MARGIN = 16, GAP = 14;

function place(target: DOMRect | null, card: { w: number; h: number }, bounds: { w: number; h: number }, labelRoom: number) {
  const clamp = (x: number, y: number) => ({
    x: Math.min(Math.max(x, MARGIN), Math.max(MARGIN, bounds.w - card.w - MARGIN)),
    y: Math.min(Math.max(y, MARGIN), Math.max(MARGIN, bounds.h - card.h - MARGIN)),
  });
  if (!target) return clamp((bounds.w - card.w) / 2, (bounds.h - card.h) / 2);
  const right = target.right + labelRoom;
  if (right + GAP + card.w + MARGIN <= bounds.w && (target.height < card.h * 2 || target.width < bounds.w * 0.3)) return clamp(right + GAP, target.top + target.height / 2 - card.h / 2);
  if (target.bottom + GAP + card.h + MARGIN <= bounds.h) return clamp(target.left + target.width / 2 - card.w / 2, target.bottom + GAP);
  if (target.top - GAP - card.h >= MARGIN) return clamp(target.left + target.width / 2 - card.w / 2, target.top - GAP - card.h);
  return clamp(target.left - GAP - card.w, target.top + target.height / 2 - card.h / 2);
}

export function Tour() {
  const { tourStep, setTourStep, finishTour, go } = useStore();
  const [rect, setRect] = useState<DOMRect | null>(null);
  const [areaRects, setAreaRects] = useState<{ page: Page; rect: DOMRect }[]>([]);
  const [size, setSize] = useState({ w: window.innerWidth, h: window.innerHeight });
  const cardRef = useRef<HTMLDivElement>(null);
  const [cardH, setCardH] = useState(220);
  const step = tourStep != null ? TOUR[tourStep] : null;

  const measure = useCallback(() => {
    if (!step) return;
    const el = document.querySelector(`[data-tour="${step.target}"]`);
    setRect(el ? el.getBoundingClientRect() : null);
    setAreaRects(step.target === "map" ? AREAS.flatMap((p) => {
      const r = document.querySelector(`[data-tour="area-${p}"]`)?.getBoundingClientRect();
      return r ? [{ page: p, rect: r }] : [];
    }) : []);
    setSize({ w: window.innerWidth, h: window.innerHeight });
  }, [step]);

  useEffect(() => {
    if (!step) return;
    if (step.page) go(step.page);
    const timers = [window.setTimeout(measure, 30), window.setTimeout(measure, 300), window.setTimeout(measure, 900)];
    window.addEventListener("resize", measure);
    return () => { timers.forEach(clearTimeout); window.removeEventListener("resize", measure); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tourStep]);

  useLayoutEffect(() => { if (cardRef.current) setCardH(cardRef.current.offsetHeight); }, [tourStep, rect]);

  const next = useCallback(() => {
    if (tourStep == null) return;
    if (tourStep + 1 < TOUR.length) setTourStep(tourStep + 1);
    else { finishTour(); go("overview"); }
  }, [tourStep, setTourStep, finishTour, go]);
  const back = useCallback(() => { if (tourStep) setTourStep(tourStep - 1); }, [tourStep, setTourStep]);

  useEffect(() => {
    if (tourStep == null) return;
    cardRef.current?.querySelector<HTMLElement>(".btn.commit")?.focus();
    const key = (e: KeyboardEvent) => {
      if (e.key === "Escape") finishTour();
      if (e.key === "ArrowRight") next();
      if (e.key === "ArrowLeft") back();
    };
    document.addEventListener("keydown", key);
    return () => document.removeEventListener("keydown", key);
  }, [tourStep, next, back, finishTour]);

  if (!step || tourStep == null) return null;
  const hole = rect ? { left: rect.left - 6, top: rect.top - 6, width: rect.width + 12, height: rect.height + 12 } : null;
  const labelRoom = step.target === "map" ? 200 : 0;
  const pos = place(rect, { w: 340, h: cardH }, size, labelRoom);

  return createPortal(
    <div className="tour-layer" role="dialog" aria-modal="true" aria-label={`Quick tour, step ${tourStep + 1} of ${TOUR.length}: ${step.title}`}>
      {hole ? <div className="tour-hole" style={hole} /> : <div style={{ position: "absolute", inset: 0, background: "rgba(0,0,0,0.55)" }} />}
      {hole && areaRects.map(({ page, rect: r }) => (
        <div key={page} className={`tour-label ${sw(PAGES[page].swatch)}`} style={{ left: hole.left + hole.width + 14, top: r.top + r.height / 2 - 13 }} aria-hidden="true">
          <i />{AREA_BLURB[page]}
        </div>
      ))}
      <div ref={cardRef} className="tour-card" style={{ left: pos.x, top: pos.y }}>
        <div className="row" style={{ gap: 10 }}>
          <Badge icon={step.icon} swatch={step.swatch} size={30} />
          <span className="eyebrow" style={{ color: "var(--accent-text)", flex: 1 }}>Quick tour · {tourStep + 1} of {TOUR.length}</span>
          <button className="btn plain quiet sm" onClick={finishTour} title="Skip the tour (Esc)">Skip</button>
        </div>
        <strong style={{ fontSize: 18, letterSpacing: -0.3 }}>{step.title}</strong>
        <p className="muted">{step.message}</p>
        <div className="tour-progress" aria-hidden="true">{TOUR.map((_, i) => <span key={i} className={i <= tourStep ? "on" : ""} />)}</div>
        <div className="row">
          <span className="caption">← → to move</span>
          <span className="spacer" />
          {tourStep > 0 && <button className="btn secondary sm" onClick={back}>Back</button>}
          <button className="btn commit sm" onClick={next}>{tourStep + 1 === TOUR.length ? "Finish" : "Next"}</button>
        </div>
      </div>
    </div>,
    document.body,
  );
}
