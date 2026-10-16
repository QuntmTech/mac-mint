"use client";
import { useEffect, useRef, type ReactNode } from "react";
import { X, ArrowUpRight, ArrowRight, Code2, Download } from "lucide-react";
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
    <span className="eyebrow">MACMINT AVAILABILITY</span>
    <h2 id="modal-title">A clearer path<br />to a cleaner Mac.</h2>
    <p>A ready-to-install download isn’t linked here yet. Explore the demo or current source. The native app requires an account and an active plan.</p>
    <div className="availability"><Code2 /><div><strong>Explore the current app</strong><span>Source code and build instructions are available on GitHub. Building requires macOS 14+ and Swift 6.</span></div></div>
    <a className="button primary" href={productConfig.repositoryUrl} target="_blank" rel="noreferrer">View MacMint on GitHub <ArrowUpRight size={17}/></a>
    <a className="text-link" href={productConfig.releasesUrl} target="_blank" rel="noreferrer">Check release availability <ArrowUpRight size={15}/></a>
    <a className="text-link modal-demo-link" href="#product-demo" onClick={onClose}>Try the interactive demo <ArrowRight size={15}/></a>
    <a className="text-link" href={productConfig.signUpUrl}>Have a code? Create an account &amp; redeem <ArrowUpRight size={15}/></a>
    <small className="quiet">This page does not take payments. Confirm purchase terms and installer availability before buying.</small>
  </>;
  else if (name === "privacy") content = <><span className="eyebrow">PRIVACY, IN PLAIN ENGLISH</span><h2 id="modal-title">Local by design.</h2><p>MacMint scans files locally. Files, paths, scan results, cleanup history and exclusions stay on your Mac. The current app requires account sign-in and an active plan; account and license checks contact MacMint’s backend and include account and device information. The source contains no telemetry.</p><p>This homepage’s demos use fictional data. They cannot access your Mac’s files. No analytics, tracking scripts or forms have been added to this site. Hosting providers may process standard request logs.</p><p>GitHub links open an external service with its own privacy practices. A final legal privacy policy will be provided before a consumer release.</p></>;
  else content = <><span className="eyebrow">PROJECT STATUS</span><h2 id="modal-title">A little clarity.</h2><p>This website presents MacMint’s current source-based capabilities and illustrative product demos. It does not scan or clean your computer.</p><p>MacMint is still in development. This page does not provide checkout or an installer. Confirm pricing, support and distribution terms before purchase. Account and license services are separate from the local file-analysis features. The repository’s LICENSE governs the source code.</p><a className="text-link" href={`${productConfig.repositoryUrl}/blob/main/LICENSE`} target="_blank" rel="noreferrer">Read the source license <ArrowUpRight size={15}/></a></>;
  return <dialog ref={ref} className="modal" aria-labelledby="modal-title" onCancel={onClose} onClick={e => { if (e.target === e.currentTarget) onClose(); }}><div className="modal-top"><span id="modal-brand"><Brand small/></span><button className="icon-button" aria-label="Close dialog" onClick={onClose}><X/></button></div><div className="modal-content">{content}</div></dialog>;
}
export function GetButton({ onClick, className = "", children }: { onClick: () => void; className?: string; children?: ReactNode }) {
  return productConfig.downloadUrl ? <a className={`button primary ${className}`} href={productConfig.downloadUrl}><Download size={17}/>Download MacMint</a> : <button className={`button primary ${className}`} onClick={onClick}>{children || <>Check availability <ArrowUpRight size={17}/></>}</button>;
}
