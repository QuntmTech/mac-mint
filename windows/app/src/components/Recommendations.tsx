import { Eye, Lightbulb, ShieldCheck } from "lucide-react";
import type { Recommendation, SmartScan } from "../api/types";
import { bytes, relative } from "../lib/format";
import { PAGES, type Swatch } from "../lib/pages";
import { useStore } from "../state/store";
import { Badge, Chip } from "./ui";

export function kindChip(kind: Recommendation["kind"]) {
  if (kind === "clean") return <Chip swatch="mint" icon={ShieldCheck}>Safe</Chip>;
  if (kind === "review") return <Chip swatch="amber" icon={Eye}>Review</Chip>;
  return <Chip swatch="slate" icon={Lightbulb}>Tip</Chip>;
}

export function RecommendationRow({ rec }: { rec: Recommendation }) {
  const { review, go, busy } = useStore();
  const canReview = rec.kind !== "advice" && rec.candidateIds.length > 0;
  return (
    <div className="rec-row">
      <Badge icon={PAGES[rec.page]?.icon ?? Lightbulb} swatch={rec.tone as Swatch} size={32} />
      <div className="col" style={{ flex: 1, gap: 3 }}>
        <span className="row-title truncate" title={rec.title}>{rec.title}</span>
        <div className="row" style={{ gap: 6 }}>
          {kindChip(rec.kind)}
          <span className="caption truncate" title={rec.detail}>{rec.detail}</span>
        </div>
      </div>
      {rec.bytes > 0 && (
        <div className="col" style={{ alignItems: "flex-end", flex: "none" }}>
          <span className="size">≈ {bytes(rec.bytes)}</span>
          {rec.candidateIds.length > 1 && <span className="caption num">{rec.candidateIds.length} items</span>}
        </div>
      )}
      {canReview
        ? <button className="btn secondary sm" onClick={() => review(rec.title, rec.candidateIds)} disabled={busy} title="Opens the review. Nothing moves until you confirm.">Review</button>
        : <button className="btn secondary sm" onClick={() => go(rec.page)}>Show</button>}
    </div>
  );
}

export function RecommendationList({ scan }: { scan: SmartScan }) {
  const count = scan.recommendations.length;
  return (
    <div className="card flush">
      <div className="col" style={{ padding: "14px 18px 10px", gap: 4 }}>
        <div className="row" style={{ alignItems: "baseline" }}>
          <span className="card-title">Recommended for you</span>
          <span className="spacer" />
          <span className="caption">{count} suggestion{count === 1 ? "" : "s"} · checked {relative(scan.checkedAt)}</span>
        </div>
        <span className="caption">Ranked by estimated space and how sure MacMint is. Sizes are estimates until the Recycle Bin is emptied.</span>
      </div>
      {scan.recommendations.map((rec) => <RecommendationRow key={rec.id} rec={rec} />)}
    </div>
  );
}
