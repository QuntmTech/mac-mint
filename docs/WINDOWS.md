# MacMint for Windows

The Windows app lives in `windows/`:

| Folder | What it is |
|---|---|
| `windows/core` | The engine, in Rust: what's safe to move, scanners, the Recycle Bin mover, History. No window code, so it's tested with temporary folders on any system. |
| `windows/app/src-tauri` | The Tauri shell: commands the window calls, the MacMint account, the optional assistant and updates. |
| `windows/app/src` | The window (React + TypeScript), the same design as the Mac app. `src/api/types.ts` and `src/api/commands.ts` are the contract with the engine. |

## Same promises as the Mac app

- Scanning only looks. Nothing moves until you review it, and every move goes to the **Recycle Bin**, recorded in History with Restore.
- Right before each item moves, it's checked again: still there, same item (creation time), still in an allowed place, not excluded, and nothing using it (its app, a program running from it, a process working inside it, or a build tool working in its project). If MacMint can't read what's running, anything an app or build tool might be using stays.
- A journal is written before each move. If MacMint stops mid-move, the next launch records that item as "uncertain" in History, never as moved.
- Never touched: `C:\Windows`, `Program Files`, `ProgramData`, anything outside your user folder, links and junctions, top-level folders of your profile, MacMint's own files, and your Documents, Desktop, Pictures, Music, Videos and OneDrive (except single files you pick yourself in Large Files, Duplicates or Downloads).
- Caches are only offered when their owner is known (Chrome, Edge, Firefox, VS Code, Discord, Slack and others). An open owner means the item is listed but never preselected. Unknown owners, crash reports, old installers, Brave, WebCatalog, pnpm's store and Visual Studio's installer packages are review-only.
- Installed packages (`node_modules`, `.venv`) are review-only; patch markers are called out. Build output (`target`, `.next`, `obj`…) is suggested only in projects idle for 30+ days.
- "App data with no owner found" is review-only, skips anything changed in the last 30 days, and is skipped entirely if the installed-app list couldn't be read.
- Large items: Windows' own "too big for the Recycle Bin" case is refused (the item stays), so nothing is ever deleted outright by a move.
- Removing files and uninstalling need an active MacMint plan, as on the Mac. Scanning is free.

## Windows-specific features

- **Apps**: the uninstall list from the registry (current user and all users). Uninstall starts the app's own uninstaller; Windows asks for permission when needed.
- **Startup**: the Run keys and Startup folders, with the same on/off switch Task Manager uses. All-users items need an administrator, so MacMint opens Task Manager for those.
- **Performance**: processor and memory, heaviest apps grouped by program. "Lower priority" sets Below Normal until the app restarts; nothing is closed.
- **Recycle Bin**: size on the Overview; emptying it needs a separate confirmation.

## Account and assistant

Same server as the Mac app (`https://macmint.cloudpod.pro`). Signing in activates this PC as a device on the account (it uses one of the plan's device slots). The device ID is a hash of Windows' machine ID. The session token is kept in Windows Credential Manager. The server-signed offline pass is verified with the same Ed25519 key as the Mac app.

The assistant is off until turned on in Settings. It sends only the typed question, earlier turns, and the system drive's size and free space. Never file names or paths.

## Builds and updates

`.github/workflows/windows.yml` runs on every change under `windows/`:

1. Engine tests on Windows.
2. Type-check and build the window.
3. `tauri build` makes the NSIS installer (per-user install, no administrator needed).
4. The installer is installed silently on the runner and MacMint is started once to check it stays running.

On `main` it publishes `windows-dev-build-N` (N is the commit count) with `MacMint-Setup.exe` and its SHA-256, then points `windows-dev.json` on the `dev-feed` release at it. The app's **Check for updates** reads that file, downloads the installer only from this repository's releases, checks the SHA-256, and starts it.

The installer is **not code-signed yet**, so SmartScreen shows "Windows protected your PC": choose **More info → Run anyway**. Signing needs a certificate the owner provides.

## Developing

```bash
cd windows/core && cargo test                     # engine tests (Linux or Windows)
cd windows/app && npm install && npm run dev      # window in a browser, with sample data
cd windows/app && npx tauri dev                   # the real app (Windows)
```
