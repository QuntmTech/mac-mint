/** Consumer download guidance; never starts a scan or grants account access. */
export function InstallationSteps({ downloadUrl }: { downloadUrl: string }) {
  let path = ''
  try { path = new URL(downloadUrl).pathname.toLowerCase() } catch { /* Generic instructions for an unrecognized link. */ }
  const diskImage = path.endsWith('.dmg')
  const zip = path.endsWith('.zip')
  const steps = [
    { title: diskImage ? 'Open MacMint.dmg' : zip ? 'Expand MacMint.zip' : 'Open the download',
      detail: diskImage ? 'Double-click the disk image in Downloads.' : zip ? 'Double-click the archive in Downloads to extract MacMint.app.' : 'Open the file in Downloads and follow its installation instructions.' },
    { title: 'Drag MacMint to Applications', detail: diskImage ? 'Drag MacMint.app onto the Applications shortcut in the installer window.' : 'Move the extracted MacMint.app into your Applications folder.' },
    { title: 'Open the installed copy', detail: 'Open MacMint from Applications. Choose Open Workspace or Run Quick Scan in setup. Optional permissions can wait.' },
  ]
  return <section aria-label="Install MacMint" className="mt-5 border-t border-slate-200 pt-5 dark:border-slate-700">
    <h3 className="text-sm font-semibold">Install in three steps</h3>
    <ol className="mt-3 space-y-3">
      {steps.map((step, index) => <li key={step.title} className="flex gap-3 text-sm">
        <span aria-hidden="true" className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-slate-100 text-xs font-semibold text-slate-700 dark:bg-slate-800 dark:text-slate-200">{index + 1}</span>
        <div><p className="font-medium">{step.title}</p><p className="mt-1 leading-relaxed text-slate-600 dark:text-slate-400">{step.detail}</p></div>
      </li>)}
    </ol>
    <p className="mt-4 text-sm leading-relaxed text-slate-600 dark:text-slate-400">Already purchased? Connect the same account in MacMint that you used here. Choose Check My Purchase if payment has just finished. A direct website purchase does not need a redemption code.</p>
  </section>
}
