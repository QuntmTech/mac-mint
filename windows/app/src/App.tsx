// The window: sidebar, toolbar, the current page and the overlays that sit above it.
import type { ComponentType } from "react";
import { CheckCircle2, AlertTriangle } from "lucide-react";
import type { Page } from "./api/types";
import { PAGES } from "./lib/pages";
import { StoreProvider, useStore } from "./state/store";
import { Sidebar, StatusBar, Toolbar } from "./components/Shell";
import { EmptyRecycleBinDialog, OperationFlow } from "./components/OperationFlow";
import { AccountGateDialog } from "./components/Account";
import { Onboarding, Tour } from "./components/Onboarding";
import Overview from "./pages/Overview";
import SmartScan from "./pages/SmartScan";
import Performance from "./pages/Performance";
import Cleanup from "./pages/Cleanup";
import Storage from "./pages/Storage";
import LargeFiles from "./pages/LargeFiles";
import Duplicates from "./pages/Duplicates";
import Apps from "./pages/Apps";
import Startup from "./pages/Startup";
import Developer from "./pages/Developer";
import Assistant from "./pages/Assistant";
import History from "./pages/History";
import Settings from "./pages/Settings";
import Account from "./pages/Account";
import Help from "./pages/Help";

const VIEWS: Record<Page, ComponentType> = {
  overview: Overview, smartScan: SmartScan, performance: Performance, cleanup: Cleanup, storage: Storage, largeFiles: LargeFiles,
  duplicates: Duplicates, apps: Apps, startup: Startup, developer: Developer, assistant: Assistant, history: History,
  settings: Settings, account: Account, help: Help,
};

function Window() {
  const { page, toast } = useStore();
  const View = VIEWS[page];
  return (
    <div className="app">
      <Sidebar />
      <div className="app-divider" />
      <main className={`main sw-${PAGES[page].swatch}`}>
        <Toolbar />
        <div className="page-scroll">
          <div className="page-wrap" key={page}><View /></div>
        </div>
        <StatusBar />
      </main>
      <OperationFlow />
      <EmptyRecycleBinDialog />
      <AccountGateDialog />
      <Onboarding />
      <Tour />
      {toast && (
        <div key={toast.id} className={`toast ${toast.tone === "warn" ? "warn" : ""}`} role="status">
          {toast.tone === "warn" ? <AlertTriangle size={16} aria-hidden="true" /> : <CheckCircle2 size={16} aria-hidden="true" />}
          <span>{toast.message}</span>
        </div>
      )}
    </div>
  );
}

export default function App() {
  return <StoreProvider><Window /></StoreProvider>;
}
