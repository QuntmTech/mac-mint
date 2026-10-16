import type { Metadata } from "next";
import "./globals.css";
const origin = process.env.NEXT_PUBLIC_SITE_URL || "https://macmint.co";
export const metadata: Metadata = {
  metadataBase: new URL(origin),
  title: "MacMint — Put your Mac back in mint condition",
  description: "Understand your Mac’s storage. Review unnecessary caches, app leftovers, large files and exact duplicates with a native, local-first macOS cleaner.",
  alternates: { canonical: origin },
  openGraph: { title: "MacMint — Back to mint condition", description: "Fresh space. Fewer mysteries. Mac cleanup that keeps you in control.", url: origin, type: "website", images: [{ url: "/og.png", width: 1200, height: 630 }] },
  twitter: { card: "summary_large_image", title: "MacMint — Back to mint condition", images: ["/og.png"] },
  icons: { icon: "/favicon.svg" },
};
export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body>{children}</body></html>;
}
