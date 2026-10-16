"use client";
import { useEffect, useRef, type ReactNode } from "react";
import { X, ArrowUpRight, Code2, Download } from "lucide-react";
import { productConfig } from "@/lib/product-config";
import { Brand } from "./brand";
export type ModalName = "download" | "privacy" | "terms" | null;
export function Modal({ name, onClose }: { name: ModalName; onClose: () => void }) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const dialog = ref.current;
    if (!name || !dialog) return;
    const previous = document.activeElement as HTMLElement | null;
    dialog.showModal();
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => { dialog.close(); document.body.style.overflow = previousOverflow; previous?.focus(); };
  }, [name]);
  if (!name) return null;
  let content: ReactNode;
  if (name === "download") content = <>
    <span className="eyebrow">A FRESH START IS TAKING SHAPE</span>
    <h2>Your Mac’s next<br />fresh start.</h2>
    <p>MacMint is in development. A signed, notarized installer isn’t available yet.</p>
    <div className="availability"><Code2 /><div><strong>Explore the current app</strong><span>Source code and build instructions are available on GitHub. Building requires macOS 14+ and Swift 6.</span></div></div>
    <a className="button primary" href={productConfig.repositoryUrl} target="_blank" rel="noreferrer">View MacMint on GitHub <ArrowUpRight size={17}/></a>
    <a className="text-link" href={productConfig.releasesUrl} target="_blank" rel="noreferrer">Check release availability <ArrowUpRight size={15}/></a>
    <small className="quiet">No pricing or release date has been announced.</small>
  </>;
  else if (name === "privacy") content = <><span className="eyebrow">PRIVACY, IN PLAIN ENGLISH</span><h2>Local by design.</h2><p>The current native MacMint app has no telemetry and makes no network calls. Scans, cleanup history and exclusions stay on your Mac.</p><p>This homepage’s demos use fictional data. They cannot access your Mac’s files. No analytics, tracking scripts or forms have been added to this site. Hosting providers may process standard request logs.</p><p>GitHub links open an external service with its own privacy practices. A final legal privacy policy will be provided before a consumer release.</p></>;
  else content = <><span className="eyebrow">PROJECT STATUS</span><h2>A little clarity.</h2><p>This website presents MacMint’s current source-based capabilities and illustrative product demos. It does not scan or clean your computer.</p><p>MacMint is still in development. Consumer pricing, support terms, final branding and distribution terms have not been announced. The repository’s LICENSE governs the source code.</p><a className="text-link" href={`${productConfig.repositoryUrl}/blob/main/LICENSE`} target="_blank" rel="noreferrer">Read the source license <ArrowUpRight size={15}/></a></>;
  return <dialog ref={ref} className="modal" aria-labelledby="modal-brand" onCancel={onClose} onClick={e => { if (e.target === e.currentTarget) onClose(); }}><div className="modal-top"><span id="modal-brand"><Brand small/></span><button className="icon-button" aria-label="Close dialog" onClick={onClose}><X/></button></div><div className="modal-content">{content}</div></dialog>;
}
export function GetButton({ onClick, className = "", children }: { onClick: () => void; className?: string; children?: ReactNode }) {
  return productConfig.downloadUrl ? <a className={`button primary ${className}`} href={productConfig.downloadUrl}><Download size={17}/>Download MacMint</a> : <button className={`button primary ${className}`} onClick={onClick}>{children || <>Get MacMint <ArrowUpRight size={17}/></>}</button>;
}
