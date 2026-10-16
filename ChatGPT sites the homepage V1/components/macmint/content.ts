export const faqs = [
  ["Do I need an account or a plan?", "Local scanning, inspection, exclusions, History and Restore work without sign-in. A paid removal requires an active account and plan. If you already have a redemption code, create an account or sign in at macmint.co to redeem it. Account and license checks use the network; file scanning stays on your Mac."],
  ["Can I download MacMint today?", "A ready-to-install consumer download is not linked on this page. Explore the interactive demos here, or find the source and local build instructions on GitHub. Local inspection and recovery work before sign-in; paid removal requires activation. These website demos use example data and cannot access your files."],
  ["Is MacMint safe for my Mac?", "MacMint uses a conservative cleanup policy: disposable caches can be preselected, review items require your choice, and restricted items cannot be selected. Paths are checked again before cleanup. Selected files move to macOS Trash."],
  ["Will it delete my photos or documents?", "Automatic cleanup is blocked from targeting Desktop, Documents, Pictures, Movies and Music. Large Files and Duplicates are separate review tools: you explicitly choose any personal files to remove."],
  ["Does MacMint permanently delete files?", "No. Cleanup moves selected items to the normal macOS Trash. You can restore items while they remain there. Emptying Trash is a separate action; storage is generally reclaimed when Trash is emptied."],
  ["Does it upload my files or track me?", "File scanning is local. File contents, cleanup history and exclusions remain on your Mac. Optional AI sends previewable category summaries, known tool identifiers and your typed questions through MacMint to Anthropic after consent. Account and activation checks use MacMint’s backend. Website analytics collection is disabled."],
  ["Which Macs does it support?", "The current Swift package targets macOS 14 Sonoma and later and uses Swift 6 and SwiftUI. A final signed and notarized consumer download has not been published yet; the source repository includes local build instructions."],
  ["How does the app uninstaller work?", "MacMint inventories installed applications and looks for related files in known user Library locations. Exact bundle-identifier matches have higher confidence; looser name matches need review. Related data is left untouched if moving the app to Trash fails."],
  ["Are duplicates really checked?", "Yes. MacMint groups files by size, compares sample fingerprints, then verifies full contents using streaming SHA-256. Nothing is automatically selected, and the review flow prevents selecting every remaining copy in a group."],
  ["Can I clean Xcode and developer caches?", "Yes. Targets include Xcode DerivedData, Archives, DeviceSupport, simulator caches, npm, Gradle, Homebrew, pip, CocoaPods, Yarn and Swift Package Manager. Categories with possible long-term value require review. Some caches will need to rebuild afterward."],
  ["Does browser cleanup remove passwords or bookmarks?", "No. Current browser cleanup targets caches for Chrome, Firefox, Microsoft Edge and Safari. It does not target passwords, bookmarks, browsing history or cookies."],
  ["Do I need Full Disk Access?", "It is optional. macOS may block access to some locations without it. MacMint reports access issues and continues where permitted, rather than bypassing macOS privacy controls."],
];
export const cleanupRows = [
  { id: "cache", name: "Application caches", detail: "Regenerable app data", size: 2.4, risk: "safe" },
  { id: "browser", name: "Browser caches", detail: "Cached files, not your bookmarks", size: 1.6, risk: "safe" },
  { id: "dev", name: "Developer caches", detail: "Build and package caches", size: 2.1, risk: "safe" },
  { id: "logs", name: "Application logs", detail: "Historical logs", size: 0.3, risk: "safe" },
  { id: "backups", name: "Device backups", detail: "Local backups — review first", size: 1.2, risk: "review" },
];
export const largeFiles = [
  { name: "Weekend-film.mov", type: "Video", size: 8.4, color: "peach" },
  { name: "Project-archive.zip", type: "Archive", size: 3.2, color: "lilac" },
  { name: "Old-installer.dmg", type: "Disk image", size: 1.8, color: "mint" },
  { name: "Presentation-export.pdf", type: "Document", size: 0.6, color: "blue" },
];
