import Foundation

public actor SmartScanService {
  private let cleanupScanner: CleanupScanner
  private let appScanner: AppScanner
  private let startupScanner: StartupItemScanner

  public init(
    cleanupScanner: CleanupScanner = CleanupScanner(),
    appScanner: AppScanner = AppScanner(),
    startupScanner: StartupItemScanner = StartupItemScanner()
  ) {
    self.cleanupScanner = cleanupScanner
    self.appScanner = appScanner
    self.startupScanner = startupScanner
  }

  public func scan(ignoredPaths: Set<String> = []) async -> ScanSummary {
    let started = Date()
    async let cleanup = cleanupScanner.scanReport(ignoredPaths: ignoredPaths)
    async let apps = appScanner.installedAppsReport(ignoredPaths: ignoredPaths)
    async let startup = startupScanner.scanReport(ignoredPaths: ignoredPaths)
    let (cleanupReport, appReport, startupReport) = await (cleanup, apps, startup)

    let targets = cleanupReport.value
    let reclaimable = targets.filter { $0.risk == .safe }.reduce(Int64(0)) { $0 + $1.size }
    let review = targets.filter { $0.risk == .review }.reduce(Int64(0)) { $0 + $1.size }
    let issues = cleanupReport.issues + appReport.issues + startupReport.issues
    return ScanSummary(
      cleanupTargets: targets,
      reclaimableBytes: reclaimable,
      reviewBytes: review,
      apps: appReport.value,
      startupItems: startupReport.value,
      issues: issues,
      scannedAt: Date(),
      duration: Date().timeIntervalSince(started),
      wasCancelled: cleanupReport.wasCancelled || appReport.wasCancelled
        || startupReport.wasCancelled || Task.isCancelled
    )
  }
}
