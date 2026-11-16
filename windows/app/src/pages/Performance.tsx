// Performance (PerformanceView.swift): CPU and memory right now, the busiest apps, and a
// gentle "Lower priority" instead of the Mac's taming. Nothing is closed for you.
import { useEffect, useState } from "react";
import { Clock, Cpu, Gauge, HardDrive, MemoryStick, Pause, Play, ShieldCheck, Turtle, Zap, type LucideIcon } from "lucide-react";
import { call } from "../api/client";
import type { Performance as Perf, ProcessInfo } from "../api/types";
import { bytes, duration, errorText, percent } from "../lib/format";
import type { Swatch } from "../lib/pages";
import { update, useResource } from "../state/resource";
import { useStore } from "../state/store";
import { Badge, Chip, ErrorBanner, LoadingState, Meter, Segmented, Spinner } from "../components/ui";
import { AppIcon } from "./Apps";

export default function Performance() {
  const { go, notify } = useStore();
  const res = useResource<Perf>("performance", () => call("performance"));
  const [paused, setPaused] = useState(false);
  const [sort, setSort] = useState<"cpu" | "memory">("cpu");
  const [pending, setPending] = useState<number | null>(null);
  const data = res.data;
  const reload = res.reload;

  useEffect(() => {
    if (paused) return;
    const timer = window.setInterval(() => { if (!document.hidden) void reload(); }, 3000);
    return () => window.clearInterval(timer);
  }, [paused, reload]);

  const lower = async (p: ProcessInfo, low: boolean) => {
    setPending(p.pid);
    try {
      const next = await call("set_low_priority", { pid: p.pid, low });
      update<Perf>("performance", (d) => ({ ...d, processes: d.processes.map((x) => (x.pid === p.pid ? next : x)) }));
      notify(low ? `${p.name} now gets less of the processor while other apps need it.` : `${p.name} is back to normal priority.`);
    } catch (e) {
      notify(errorText(e), "warn");
    } finally {
      setPending(null);
    }
  };

  const procs = [...(data?.processes ?? [])].sort((a, b) => (sort === "cpu" ? b.cpuPercent - a.cpuPercent : b.memory - a.memory));
  const maxCpu = Math.max(100, ...procs.map((p) => p.cpuPercent));
  const memFraction = data ? data.memory.used / data.memory.total : 0;

  return (
    <div className="page">
      <header className="page-header">
        <div className="heading">
          <Badge icon={Gauge} swatch="sky" size={42} glow />
          <div className="col">
            <h1>Performance</h1>
            <p className="subtitle">See what's busy, find the app, and decide what to do.</p>
          </div>
        </div>
        <div className="actions">
          <span className="pill" aria-live="off">
            <span style={{ width: 7, height: 7, borderRadius: 4, background: paused ? "var(--ink3)" : "var(--brand)" }} aria-hidden="true" />
            {paused ? "Paused" : "Live · every 3 seconds"}
          </span>
          <button className="btn secondary" onClick={() => setPaused(!paused)}>{paused ? <Play size={13} /> : <Pause size={13} />}{paused ? "Resume" : "Pause"}</button>
        </div>
      </header>
      {res.error && <ErrorBanner message={res.error} onRetry={() => void res.reload()} title="Couldn't read performance" />}
      {!data && !res.error ? (
        <LoadingState title="Reading CPU and memory…" detail="Taking a quick look at what's running right now." icon={Gauge} swatch="sky" />
      ) : data && (
        <>
          <div className="grid-cards">
            <Card icon={Cpu} swatch="sky" title="CPU" value={`${Math.round(data.cpuPercent)}%`} detail="How hard the processor is working" fraction={data.cpuPercent / 100}
              state={data.cpuPercent > 85 ? "Busy" : "Normal"} strained={data.cpuPercent > 85} />
            <Card icon={MemoryStick} swatch="violet" title="Memory" value={percent(memFraction)} detail={`${bytes(data.memory.used)} of ${bytes(data.memory.total)} in use`} fraction={memFraction}
              state={memFraction > 0.9 ? "Running low" : "Normal"} strained={memFraction > 0.9} />
            <Card icon={Zap} swatch="violet" title="Startup apps" value={String(data.startupEnabled)} detail="Start when you sign in · Manage" fraction={null} onClick={() => go("startup")} />
            <Card icon={Clock} swatch="slate" title="Up time" value={duration(data.uptimeSeconds)} detail="A restart can help if things feel slow" fraction={null}
              state={data.uptimeSeconds > 7 * 86400 ? "Restart soon" : undefined} strained={data.uptimeSeconds > 7 * 86400} />
          </div>

          <section className="card flush" aria-label="Busy apps">
            <div className="row wrap" style={{ padding: "14px 18px", gap: 10 }}>
              <div className="col" style={{ flex: 1, gap: 2, minWidth: 220 }}>
                <span className="card-title">Busy apps</span>
                <span className="caption">CPU is the share of the whole processor. Memory includes each app's helper processes.</span>
              </div>
              <Segmented label="Sort by" value={sort} onChange={setSort} options={[{ value: "cpu", label: "CPU" }, { value: "memory", label: "Memory" }]} />
            </div>
            <div className="table-head"><span style={{ width: 30 }} /><span style={{ flex: 1 }}>App</span><span style={{ width: 150 }} className="hide-narrow">CPU</span><span style={{ width: 76, textAlign: "right" }}>Memory</span><span style={{ width: 150 }} /></div>
            {procs.map((p) => (
              <div key={p.pid} className="list-row" style={{ minHeight: 48 }}>
                <AppIcon app={{ name: p.name, icon: null }} size={30} />
                <div className="col" style={{ flex: 1, gap: 2 }}>
                  <div className="row" style={{ gap: 6 }}>
                    <span className="row-title truncate">{p.name}</span>
                    {p.lowered && <Chip swatch="amber" icon={Turtle}>Lower priority</Chip>}
                  </div>
                  <span className="caption num">Process {p.pid}</span>
                </div>
                <span className="row hide-narrow" style={{ width: 150, gap: 8 }}>
                  <span style={{ flex: 1 }}><Meter fraction={p.cpuPercent / maxCpu} swatch="sky" /></span>
                  <span className="caption num" style={{ width: 40, textAlign: "right", color: "var(--ink)" }}>{p.cpuPercent.toFixed(1)}%</span>
                </span>
                <span className="size" style={{ width: 76 }}>{bytes(p.memory)}</span>
                <span style={{ width: 150, display: "flex", justifyContent: "flex-end" }}>
                  {p.canLower ? (
                    <button className="btn secondary sm" disabled={pending === p.pid} onClick={() => void lower(p, !p.lowered)}>
                      {pending === p.pid && <Spinner />}{p.lowered ? "Back to Normal" : "Lower Priority"}
                    </button>
                  ) : <Chip swatch="mint" icon={ShieldCheck} title="Windows protects this process">Protected</Chip>}
                </span>
              </div>
            ))}
          </section>

          <div className="two-col" style={{ gridTemplateColumns: "minmax(0,1fr) minmax(0,1fr)" }}>
            <section className="card col" style={{ gap: 10 }}>
              <span className="card-title">When to do something</span>
              <p className="small muted">Short bursts of CPU while something installs or builds are normal. If one app stays busy for minutes and you aren't using it, lower its priority or close it.</p>
              <p className="small muted"><strong style={{ color: "var(--ink)" }}>Lower priority</strong> lets other apps go first when they need the processor. Nothing is closed, and it goes back to normal when the app restarts.</p>
              <p className="small muted">To close an app that's stuck, press <strong style={{ color: "var(--ink)" }}>Ctrl + Shift + Esc</strong> to open Task Manager.</p>
            </section>
            <section className="card col" style={{ gap: 12 }}>
              <span className="card-title">What these mean</span>
              <Meaning icon={MemoryStick} swatch="violet" title="Memory (RAM) is your desk" text="It holds the apps you have open right now. Windows keeps it fairly full on purpose." />
              <Meaning icon={HardDrive} swatch="indigo" title="Disk space is your filing cabinet" text="More free space doesn't make apps faster, but very little free space slows updates." />
              <Meaning icon={Cpu} swatch="sky" title="CPU is how hard the PC is working" text="One app near 100% for a long time can make everything else feel slow." />
            </section>
          </div>
        </>
      )}
    </div>
  );
}

function Card({ icon, swatch, title, value, detail, fraction, state, strained, onClick }: {
  icon: LucideIcon; swatch: Swatch; title: string; value: string; detail: string; fraction: number | null; state?: string; strained?: boolean; onClick?: () => void;
}) {
  const inner = (
    <>
      <div className="row" style={{ width: "100%" }}>
        <Badge icon={icon} swatch={swatch} size={22} />
        <span className="eyebrow">{title}</span>
        <span className="spacer" />
        {state && <span className={strained ? "state-warn" : "state-ok"}>{state}</span>}
      </div>
      <span className="value">{value}</span>
      <span className="small muted truncate" style={{ width: "100%" }}>{detail}</span>
      {fraction != null && <div style={{ width: "100%" }}><Meter fraction={fraction} swatch={swatch} /></div>}
    </>
  );
  return onClick ? <button type="button" className="health" onClick={onClick}>{inner}</button> : <div className="health">{inner}</div>;
}

function Meaning({ icon, swatch, title, text }: { icon: LucideIcon; swatch: Swatch; title: string; text: string }) {
  return (
    <div className="row" style={{ alignItems: "flex-start", gap: 10 }}>
      <Badge icon={icon} swatch={swatch} size={26} />
      <div className="col" style={{ gap: 1 }}><strong style={{ fontSize: 12.5 }}>{title}</strong><span className="caption" style={{ color: "var(--ink2)" }}>{text}</span></div>
    </div>
  );
}
