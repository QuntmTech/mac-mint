"use client";

import { useEffect, useRef, useState } from "react";
import { ArrowLeft, ArrowRight, Check, ChevronRight, Clock3, Copy, Eye, Folder, HardDrive, History, LayoutGrid, LockKeyhole, Package, RotateCcw, Search, Settings2, ShieldCheck, Sparkles, Trash2, Zap } from "lucide-react";
import { Brand } from "./brand";
import { cleanupRows } from "./content";
import { DuplicateDemo, LargeFilesDemo, UninstallerDemo } from "./feature-demos";

const modules = [
  { id: "overview", name: "Quick Scan", icon: Sparkles },
  { id: "cleaner", name: "Cleaner", icon: Trash2 },
  { id: "apps", name: "Applications", icon: LayoutGrid },
  { id: "large", name: "Large Files", icon: HardDrive },
  { id: "duplicates", name: "Duplicates", icon: Copy },
  { id: "startup", name: "Startup Items", icon: Zap },
  { id: "history", name: "History", icon: History },
  { id: "exclusions", name: "Exclusions", icon: Settings2 },
];
const defaultSelection = cleanupRows.filter(row => row.risk === "safe").map(row => row.id);
const initialExclusions = ["~/Projects/Keep"];
const scanChecks = ["Application caches", "Browser caches", "Developer caches", "Application logs", "Device backups"];
type Receipt = { id: number; items: string[]; restored: boolean };
type DemoProps = { module?: string; onModuleChange?: (module: string) => void; startUrl?: string };

export function ProductDemo({ module, onModuleChange, startUrl }: DemoProps = {}) {
  const [localTab, setLocalTab] = useState("overview");
  const tab = module ?? localTab;
  const [progress, setProgress] = useState<number | null>(null);
  const [scanned, setScanned] = useState(false);
  const [status, setStatus] = useState("Try a scan with example files. Your Mac stays untouched.");
  const [selected, setSelected] = useState(defaultSelection);
  const [confirm, setConfirm] = useState(false);
  const [filter, setFilter] = useState("all");
  const [query, setQuery] = useState("");
  const [receipts, setReceipts] = useState<Receipt[]>([]);
  const [outcome, setOutcome] = useState<number | null>(null);
  const [excluded, setExcluded] = useState(initialExclusions);
  const [generation, setGeneration] = useState(0);
  const timer = useRef<ReturnType<typeof setInterval> | null>(null);
  const nextReceipt = useRef(1);
  const viewRef = useRef<HTMLDivElement>(null);
  const reviewButton = useRef<HTMLButtonElement>(null);
  const wasConfirm = useRef(false);
  const outcomeRestored = receipts.some(record => record.id === outcome && record.restored);

  function stopScan() {
    if (timer.current === null) return;
    clearInterval(timer.current);
    timer.current = null;
    setProgress(null);
    setStatus("Demo scan cancelled. Your selections and history are unchanged.");
  }
  function setTab(next: string) {
    if (next !== tab) stopScan();
    setConfirm(false);
    setLocalTab(next);
    onModuleChange?.(next);
  }
  // Also cover navigation from the homepage's shortcuts, which control the tab externally.
  useEffect(() => {
    if (tab !== "overview" && timer.current !== null) {
      clearInterval(timer.current);
      timer.current = null;
      setProgress(null);
      setStatus("Demo scan cancelled. Your selections and history are unchanged.");
    }
    setConfirm(false);
  }, [tab]);
  useEffect(() => () => { if (timer.current !== null) clearInterval(timer.current); }, []);
  useEffect(() => {
    if (confirm || (tab === "overview" && outcome !== null)) {
      viewRef.current?.focus({ preventScroll: true });
      // A long mobile list may leave the next screen above the viewport.
      viewRef.current?.scrollIntoView({ block: "start", behavior: "instant" });
    } else if (wasConfirm.current) reviewButton.current?.focus();
    wasConfirm.current = confirm;
  }, [confirm, outcome, outcomeRestored, tab]);

  const removed = new Set(receipts.filter(receipt => !receipt.restored).flatMap(receipt => receipt.items));
  const available = cleanupRows.filter(row => !removed.has(row.id));
  const chosen = available.filter(row => selected.includes(row.id));
  const total = chosen.reduce((sum, row) => sum + row.size, 0);
  const reviewTotal = chosen.filter(row => row.risk === "review").reduce((sum, row) => sum + row.size, 0);
  const visible = available.filter(row => (filter === "all" || row.risk === filter) && row.name.toLowerCase().includes(query.toLowerCase()));
  const receipt = receipts.find(item => item.id === outcome);
  const receiptRows = cleanupRows.filter(row => receipt?.items.includes(row.id));
  const receiptTotal = receiptRows.reduce((sum, row) => sum + row.size, 0);
  const kept = available.filter(row => !selected.includes(row.id));
  const step = tab === "overview" && receipt && !confirm ? 2 : scanned || confirm || tab === "cleaner" ? 1 : 0;

  function scan() {
    if (timer.current !== null) return;
    setProgress(0);
    setStatus("Demo scan running. Checking example cleanup locations…");
    const started = performance.now();
    timer.current = setInterval(() => {
      // Delayed/throttled callbacks should catch up rather than extend the animation.
      const value = Math.min(100, Math.floor((performance.now() - started) / 24));
      if (value >= 100) {
        clearInterval(timer.current!);
        timer.current = null;
        setProgress(null);
        setScanned(true);
        setOutcome(null);
        setFilter("all");
        setQuery("");
        // A new scan must not resurrect anything still recorded in demo Trash.
        setSelected(defaultSelection.filter(id => !removed.has(id)));
        setStatus("Demo scan complete. Review the results; device backups stay unchecked.");
      } else setProgress(value);
    }, 120);
  }
  function toggle(id: string) {
    setSelected(current => current.includes(id) ? current.filter(item => item !== id) : [...current, id]);
  }
  function clean() {
    if (!chosen.length || timer.current !== null) return;
    const id = nextReceipt.current++;
    setReceipts(current => [{ id, items: chosen.map(row => row.id), restored: false }, ...current]);
    setOutcome(id);
    setSelected([]);
    setConfirm(false);
    setTab("overview");
    setStatus(`${total.toFixed(1)} GB moved to demo Trash. Try restoring it next.`);
  }
  function restore(id: number) {
    const record = receipts.find(item => item.id === id);
    if (!record || record.restored) return;
    setReceipts(current => current.map(item => item.id === id ? { ...item, restored: true } : item));
    setStatus("Example files restored to their original locations. Nothing on your Mac was changed.");
  }
  function reset() {
    stopScan();
    setScanned(false);
    setProgress(null);
    setSelected(defaultSelection);
    setReceipts([]);
    setOutcome(null);
    setFilter("all");
    setQuery("");
    setExcluded(initialExclusions);
    setGeneration(current => current + 1);
    setTab("overview");
    setStatus("Demo reset. Your Mac stays untouched.");
  }

  function rows(items: typeof cleanupRows, reviewing = false) {
    return <div className="cleanup-list">{items.map(row => <label className="cleanup-row" key={row.id}>
      <input type="checkbox" aria-label={`${row.name}, ${row.size.toFixed(1)} GB`} checked={selected.includes(row.id)} disabled={progress !== null} onChange={() => toggle(row.id)} />
      <span className={`row-icon ${row.risk === "review" ? "amber" : "mint"}`} aria-hidden="true">{row.id === "dev" ? <Package size={17} /> : row.risk === "review" ? <Eye size={17} /> : <Folder size={17} />}</span>
      <span className="cleanup-name"><strong>{row.name}</strong><small>{row.detail}</small></span>
      <span className={`badge ${row.risk}`}>{row.risk === "safe" ? "Rebuildable" : "Review first"}</span>
      <b>{row.size.toFixed(1)} GB</b>
    </label>)}{!items.length && !reviewing && <div className="demo-empty">{available.length ? <><Search size={24} /><p>No example items match these filters.</p><button className="mini-button" onClick={() => { setQuery(""); setFilter("all"); }}>Clear filters</button></> : <><ShieldCheck /><p>Example cleanup complete. Your receipt is in History.</p><button className="mini-button" onClick={() => setTab("history")}>Open History</button></>}</div>}</div>;
  }

  return <div className="product-window guided-demo" id="product-demo">
    <div className="window-titlebar"><div className="traffic" aria-hidden="true"><i /><i /><i /></div><span>MacMint</span><span className="window-demo">Interactive demo · Example data</span></div>
    <label className="demo-module-picker"><span>Explore the demo</span><select aria-label="Choose a product demo" value={tab} onChange={event => setTab(event.target.value)}>{modules.map(item => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label>
    <div className="window-body">
      <aside className="app-sidebar"><Brand small /><nav aria-label="Product demo modules">{modules.map(({ id, name, icon: Icon }) => <button key={id} className={tab === id ? "active" : ""} onClick={() => setTab(id)} aria-pressed={tab === id}><Icon size={17} /><span>{name}</span></button>)}</nav><div className="sidebar-disk"><HardDrive size={19} /><strong>Example Mac</strong><small>76.8 GB available of 512 GB</small><div><span /></div><small><LockKeyhole size={12} /> No access to your files</small></div></aside>
      <div className="demo-main"><div className="demo-view">
        {(tab === "overview" || tab === "cleaner") && <>
          <ol className="demo-journey" aria-label="Demo cleanup journey">{["Scan", "Review", "Restore"].map((label, index) => <li key={label} aria-current={step === index ? "step" : undefined} className={step > index || (index === 2 && receipt?.restored) ? "done" : ""}><span>{step > index || (index === 2 && receipt?.restored) ? <Check size={13} /> : index + 1}</span>{label}</li>)}</ol>
          {confirm ? <div className="demo-review" ref={viewRef} tabIndex={-1} role="region" aria-labelledby="demo-review-heading">
            <button className="plain-button demo-back" onClick={() => setConfirm(false)}><ArrowLeft size={14} /> Back to results</button>
            <div className="demo-heading"><h3 id="demo-review-heading">Your cleanup. Your final say.</h3><span className="badge neutral">Example files</span></div>
            <p className="demo-description">Uncheck anything you want to keep. Only the selected items below will move.</p>
            <div className="cleanup-box">{rows(available, true)}</div>
            <div className="demo-review-summary"><strong>{total.toFixed(1)} GB selected</strong><span>including {reviewTotal.toFixed(1)} GB of review items</span></div>
            <p className="demo-kept"><ShieldCheck size={15} /><span>{kept.length ? `Staying put: ${kept.map(row => row.name.toLowerCase()).join(", ")}.` : "All five example categories are selected. You can still keep any of them."}</span></p>
            <div className="demo-consequences"><p><Package size={15} /><span>Caches can rebuild or download again on next use.</span></p><p><Trash2 size={15} /><span>Files move to Trash. Space is generally reclaimed when Trash is emptied separately.</span></p><p><RotateCcw size={15} /><span>Restore is available while the files remain in Trash.</span></p></div>
            <div className="demo-review-actions"><span>This only changes the example.</span><button className="mini-button green" disabled={total === 0} onClick={clean}><Trash2 size={15} /> Move to demo Trash</button></div>
          </div> : tab === "overview" && receipt ? <div className="demo-outcome" ref={viewRef} tabIndex={-1} role="region" aria-labelledby="demo-outcome-heading">
            <div className="demo-outcome-icon" aria-hidden="true">{receipt.restored ? <RotateCcw size={27} /> : <Check size={30} />}</div>
            <h3 id="demo-outcome-heading">{receipt.restored ? "Back where they started." : "Room to change your mind."}</h3>
            <p className="demo-description">{receipt.restored ? "Your example files are restored. That’s the whole journey: see what goes, choose for yourself, and know how to bring it back." : "Your selection moved to demo Trash. Try bringing it back, just as you would from MacMint’s History."}</p>
            <div className="demo-receipt"><div><strong>{receiptTotal.toFixed(1)} <small>GB</small></strong><span>{receipt.restored ? "restored in this demo" : "moved to demo Trash"}</span></div><span className={`badge ${receipt.restored ? "safe" : "neutral"}`}>{receiptRows.length} categories · {receipt.restored ? "Restored" : "Restorable"}</span></div>
            <p className="demo-kept"><ShieldCheck size={15} /><span>{!receipt.items.includes("backups") ? "Your device backups stayed untouched." : "Your device backups were included because you selected them."} Nothing on your Mac was changed.</span></p>
            {!receipt.restored && <p className="demo-space-note">Free space hasn’t changed yet. In macOS, emptying Trash is a separate step.</p>}
            <div className="demo-outcome-actions">{receipt.restored ? startUrl && <a className="mini-button green" href={startUrl}>Start free trial <ArrowRight size={15} /></a> : <button className="mini-button green" onClick={() => restore(receipt.id)}><RotateCcw size={15} /> Restore these files</button>}<button className="plain-button" onClick={() => setTab("history")}><History size={14} /> View receipt</button></div>
            {receipt.restored && <div className="demo-next"><p>See what else MacMint can help you inspect.</p><div><button onClick={() => setTab("apps")}><LayoutGrid size={16} /> App leftovers <ArrowRight size={13} /></button><button onClick={() => setTab("duplicates")}><Copy size={16} /> Exact duplicates <ArrowRight size={13} /></button></div></div>}
            <button className="plain-button demo-return" onClick={() => { setOutcome(null); setScanned(true); }}>Back to results <ArrowRight size={13} /></button>
            <button className="plain-button demo-reset" onClick={reset}><RotateCcw size={13} /> Reset demo</button>
          </div> : <>
            <div className="demo-heading"><h3>{tab === "cleaner" ? "Choose what’s worth clearing." : scanned ? "A clearer picture of the clutter." : "Find space. Keep control."}</h3><span className="badge safe"><ShieldCheck size={13} /> Trash-first</span></div>
            {tab === "overview" && <div className={`demo-scan-card ${progress !== null ? "scanning" : ""}`}>
              <div className="demo-scan-copy"><span className="demo-scan-symbol" aria-hidden="true">{scanned && progress === null ? <Check size={24} /> : <Search size={24} />}</span><div><h4>{progress !== null ? `Checking ${scanChecks[Math.min(4, Math.floor(progress / 20))].toLowerCase()}…` : scanned ? "Found in this example scan" : "Try the cleanup, start to finish."}</h4><p>{progress !== null ? "Nothing moves during a scan. You review the results next." : scanned ? "Rebuildable data is selected. Backups are left for you to decide." : "Scan example files, choose what goes, then bring it back. No install or sign-in needed."}</p></div></div>
              <div className="scan-buttons"><button className={`mini-button ${scanned && progress === null ? "" : "green"}`} onClick={scan} disabled={progress !== null}><Sparkles size={15} />{progress !== null ? "Scanning…" : scanned ? "Scan again" : "Run Quick Scan"}</button>{progress !== null && <button className="plain-button" onClick={stopScan}>Cancel</button>}</div>
              {progress !== null && <div className="demo-scan-progress"><div role="progressbar" aria-label="Example scan progress" aria-valuemin={0} aria-valuemax={100} aria-valuenow={progress}><span style={{ width: `${progress}%` }} /></div><span>{progress}%</span></div>}
              {!scanned && progress === null && <div className="demo-scan-scope"><span><Folder size={14} /> App & browser caches</span><span><Package size={14} /> Build data & logs</span><span><Eye size={14} /> Backups to review</span></div>}
            </div>}
            {(scanned || tab === "cleaner") && <>
              {tab === "cleaner" && <div className="cleaner-tools"><label><Search size={15} /><input aria-label="Search example cleanup items" placeholder="Search cleanup items" value={query} onChange={event => setQuery(event.target.value)} /></label><select aria-label="Cleanup risk filter" value={filter} onChange={event => setFilter(event.target.value)}><option value="all">All items</option><option value="safe">Rebuildable only</option><option value="review">Review first</option></select><button className="plain-button" onClick={() => setSelected(available.filter(row => row.risk === "safe").map(row => row.id))}>Select rebuildable</button></div>}
              <div className="cleanup-box"><div className="cleanup-title"><span><strong>{total.toFixed(1)} GB selected</strong><small>Example sizes. You can change every selection.</small></span><button onClick={() => setSelected([])} disabled={progress !== null || selected.length === 0}>Deselect all</button></div>{rows(visible)}<div className="cleanup-total"><span><ShieldCheck size={15} />{chosen.length} of {available.length} categories selected</span><button className="mini-button green" ref={reviewButton} disabled={total === 0 || progress !== null} onClick={() => setConfirm(true)}>Review {total.toFixed(1)} GB <ArrowRight size={14} /></button></div></div>
              <p className="demo-kept"><LockKeyhole size={15} /><span>{!selected.includes("backups") && !removed.has("backups") ? "Device backups are unchecked. Keep them unless you’re sure you no longer need them." : "Backups can be valuable. Keep any you may need to recover a device."}</span></p>
            </>}
            {!scanned && tab === "overview" && <div className="demo-before-scan"><ShieldCheck size={21} /><h4>The useful part is knowing what stays.</h4><p>Personal files stay outside automatic cleanup. Backups need your review. You choose what moves to Trash.</p><div><button onClick={() => setTab("apps")}>Explore app leftovers <ArrowRight size={14} /></button><button onClick={() => setTab("duplicates")}>Try exact duplicates <ArrowRight size={14} /></button></div></div>}
          </>}
        </>}
        {tab === "apps" && <><div className="demo-heading"><h3>Uninstall more than an icon.</h3></div><UninstallerDemo key={generation} /></>}
        {tab === "large" && <><div className="demo-heading"><h3>Meet your storage hogs.</h3></div><LargeFilesDemo key={generation} /></>}
        {tab === "duplicates" && <><div className="demo-heading"><h3>Same file. Extra space.</h3></div><DuplicateDemo key={generation} /></>}
        {tab === "startup" && <><div className="demo-heading"><h3>Know what wakes up.</h3><span className="badge neutral">Read-only</span></div><p className="demo-description">Inspect launch agents and daemons. Management stays in macOS System Settings.</p>{["com.example.sync-agent", "com.example.update-helper", "com.example.menu-agent"].map((name, index) => <details className="startup-row" key={name}><summary><span className="row-icon mint"><Zap size={17} /></span><strong>{name}</strong><span className="badge neutral">{index === 1 ? "System" : "User"}</span><ChevronRight size={15} /></summary><p>Scope: {index === 1 ? "System LaunchDaemon" : "User LaunchAgent"}<br />RunAtLoad: {index === 2 ? "No" : "Yes"} · KeepAlive: {index === 0 ? "Yes" : "No"}<br />Example inventory only. No system settings are changed.</p></details>)}</>}
        {tab === "history" && <><div className="demo-heading"><h3>A record. And a way back.</h3><span className="badge neutral">This demo session</span></div><p className="demo-description">In MacMint, History keeps local receipts. Restore files while they remain in Trash. These example receipts last until you reset or leave this page.</p>{receipts.length ? <div className="demo-history">{receipts.map(record => {
          const items = cleanupRows.filter(row => record.items.includes(row.id));
          const size = items.reduce((sum, row) => sum + row.size, 0);
          return <div className="demo-history-entry" key={record.id}><div><Clock3 size={18} /><strong>{size.toFixed(1)} GB moved to demo Trash</strong><span className={`badge ${record.restored ? "safe" : "neutral"}`}>{record.restored ? "Restored" : "Restorable"}</span></div><details><summary>{items.length} categories · View receipt <ChevronRight size={14} /></summary><ul>{items.map(row => <li key={row.id}><span>{row.name}</span><strong>{row.size.toFixed(1)} GB</strong></li>)}</ul></details><button className="mini-button" aria-disabled={record.restored} onClick={() => restore(record.id)}>{record.restored ? <Check size={14} /> : <RotateCcw size={14} />}{record.restored ? "Files restored" : "Restore files"}</button></div>;
        })}</div> : <div className="demo-empty"><History size={35} /><h4>A clean slate.</h4><p>Complete a demo cleanup to see its receipt and try Restore.</p><button className="mini-button green" onClick={() => setTab("overview")}>Try Quick Scan</button></div>}</>}
        {tab === "exclusions" && <><div className="demo-heading"><h3>Some folders stay yours.</h3></div><p className="demo-description">In the native app, exclusions persist locally and are respected by cleanup, leftovers, large-file and duplicate scans.</p>{excluded.map(path => <div className="history-row" key={path}><Folder size={19} /><strong>{path}</strong><button className="plain-button" onClick={() => setExcluded(current => current.filter(item => item !== path))}>Remove</button></div>)}<button className="mini-button" disabled={excluded.includes("~/Work/Important")} onClick={() => setExcluded(current => [...current, "~/Work/Important"])}>Add example exclusion</button><div className="protected-list"><ShieldCheck /><p>Desktop, Documents, Pictures, Movies and Music are protected from automatic cleanup.</p></div></>}
      </div><div className="app-status" role="status"><span><Check size={13} />{status}</span><span>Example data only</span></div></div>
    </div>
  </div>;
}
