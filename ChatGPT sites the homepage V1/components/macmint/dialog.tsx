"use client";
import { useEffect, useRef, type ReactNode } from "react";
import { X, ArrowUpRight } from "lucide-react";
import { productConfig } from "@/lib/product-config";
import { Brand } from "./brand";
export type ModalName = "privacy" | "terms" | null;
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
  if (name === "privacy") content = <><span className="eyebrow">PRIVACY, IN PLAIN ENGLISH</span><h2 id="modal-title">Local by design.</h2><p>MacMint scans files locally. File contents, cleanup history and exclusions stay on your Mac. Optional AI sends a previewable category summary, allowlisted tool identifiers and your typed questions through MacMint to Anthropic after consent. Arbitrary personal names are omitted from automatic context. Local inspection and recovery work before sign-in. Account and license checks send account and device information to MacMint’s backend.</p><p>This homepage’s demos use fictional data. They cannot access your Mac’s files. The site includes a landing-page assignment script with analytics collection disabled. Account forms communicate with MacMint’s backend. Hosting providers may process standard request logs.</p><p>GitHub links open an external service with its own privacy practices. A final legal privacy policy will be provided before a consumer release.</p></>;
  else content = <><span className="eyebrow">PROJECT STATUS</span><h2 id="modal-title">A little clarity.</h2><p>This website presents MacMint’s current source-based capabilities and illustrative product demos. It does not scan or clean your computer.</p><p>MacMint Pro is an annual subscription with a 7-day free trial, sold through the plan page. Payment is handled by Stripe; the plan page shows the price, renewal terms and cancellation before you start. The installer is offered after checkout. Account and license services are separate from the local file-analysis features. The repository’s LICENSE governs the source code.</p><a className="text-link" href={`${productConfig.repositoryUrl}/blob/main/LICENSE`} target="_blank" rel="noreferrer">Read the source license <ArrowUpRight size={15}/></a></>;
  return <dialog ref={ref} className="modal" aria-labelledby="modal-title" onCancel={onClose} onClick={e => { if (e.target === e.currentTarget) onClose(); }}><div className="modal-top"><span id="modal-brand"><Brand small/></span><button className="icon-button" aria-label="Close dialog" onClick={onClose}><X/></button></div><div className="modal-content">{content}</div></dialog>;
}
/** Every purchase call-to-action goes to the one plan page. */
export function GetButton({ className = "", children }: { className?: string; children?: ReactNode }) {
  return <a className={`button primary ${className}`} href={productConfig.startUrl}>{children || <>Start free trial <ArrowUpRight size={17}/></>}</a>;
}
