import MacCleanerCore
import SwiftUI

struct HistoryView: View {
  @EnvironmentObject private var model: AppViewModel
  @State private var showOrganization = false
  @State private var expanded: Set<UUID> = []
  @State private var confirmingHistoryReset = false

  private var totalBytes: Int64 { model.history.reduce(0) { $0 + $1.bytes } }

  /// One day of the timeline, newest first (History is already sorted newest first).
  private struct HistoryDay: Identifiable {
    let id: Date
    let entries: [HistoryEntry]
  }

  /// What a receipt can still do, read from the entry itself.
  private enum ReceiptStatus {
    case photos, legacy, nothingMoved, needsCheck, restorable, partlyRestored, restored, notInTrash
  }

  var body: some View {
    Group {
      if model.history.isEmpty {
        VStack(alignment: .leading, spacing: 14) {
          header
          recoveryCard
          EmptyState(
            icon: "clock.arrow.circlepath", title: "Nothing moved yet",
            detail: "When you move items to the Trash from Review, a receipt appears here. Restore puts them back where they were, while they're still in the Trash.",
            actionTitle: "Go to Overview", action: { model.selectedSection = .dashboard },
            trust: "Every move to the Trash gets a receipt.")
        }
        .padding(.horizontal, AppTheme.pagePadding)
        .padding(.top, AppTheme.pageTopPadding)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            header
            recoveryCard
            monthStats
            ForEach(days) { day in
              daySection(day)
            }
          }
          .frame(maxWidth: 1000)
          .padding(.horizontal, AppTheme.pagePadding)
          .padding(.top, AppTheme.pageTopPadding)
          .padding(.bottom, 28)
          .frame(maxWidth: .infinity)
        }
      }
    }
    .sheet(isPresented: $showOrganization) { OrganizerView(historyOnly: true) }
  }

  // MARK: Header

  private var header: some View {
    PageHeader(title: "History", subtitle: "Everything MacMint moved, with a receipt. Restore Trash items here, and library photos in Photos.") {
      if !model.history.isEmpty {
        StatusPill(title: ByteFormatter.string(totalBytes) + " handled", icon: "clock.arrow.circlepath", tint: AppTheme.Swatch.slate.text)
      }
      Button { showOrganization = true } label: {
        Label("Organization history", systemImage: "folder")
      }
      .buttonStyle(MintButtonStyle(.secondary))
    }
  }

  @ViewBuilder private var recoveryCard: some View {
    if !model.recoveryWarnings.isEmpty {
      HStack(alignment: .top, spacing: 12) {
        SwatchBadge(symbol: "exclamationmark.triangle", swatch: .amber, size: 30)
        VStack(alignment: .leading, spacing: 6) {
          Text("Recovery needs attention (\(model.recoveryWarnings.count))")
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.warning)
          ForEach(model.recoveryWarnings) { warning in
            Text(warning.message).font(.system(size: 12)).foregroundStyle(AppTheme.ink2)
              .fixedSize(horizontal: false, vertical: true)
          }
          HStack(spacing: 8) {
            Button("Show Recovery Files") { model.reveal(AppPaths.supportDirectory) }
              .buttonStyle(MintButtonStyle(.secondary)).controlSize(.small)
            if model.recoveryReady, !model.historyReadable {
              Button("Reset History…") { confirmingHistoryReset = true }
                .buttonStyle(MintButtonStyle(.secondary)).controlSize(.small)
                .help("Starts a new History so cleanup can continue. The unreadable file is kept beside it.")
            }
          }
          .padding(.top, 2)
        }
        Spacer(minLength: 0)
      }
      .padding(16)
      .cardBackground(AppTheme.warningTint)
      .confirmationDialog("Reset History?", isPresented: $confirmingHistoryReset) {
        Button("Reset History", role: .destructive) { model.resetDamagedHistory() }
      } message: {
        Text("The unreadable History file is kept as a backup. Restore receipts it contained can't be used from MacMint, but Finder's Put Back still works for items in the Trash.")
      }
    }
  }

  // MARK: Month stats

  private var monthEntries: [HistoryEntry] {
    let calendar = Calendar.current
    let now = Date()
    return model.history.filter { calendar.isDate($0.date, equalTo: now, toGranularity: .month) }
  }

  private var monthStats: some View {
    let month = monthEntries
    let bytes = month.reduce(Int64(0)) { $0 + $1.bytes }
    let moved = month.reduce(0) { total, entry in total + (entry.receipts?.count ?? entry.paths.count) }
    let restored = month.reduce(0) { total, entry in total + (entry.restoredPaths?.count ?? 0) }
    return HStack(spacing: 10) {
      statTile("Moved this month", ByteFormatter.string(bytes), color: AppTheme.ink)
      statTile("Items this month", "\(moved)", color: AppTheme.ink)
      statTile("Restored this month", "\(restored)", color: AppTheme.accentText)
    }
  }

  private func statTile(_ label: String, _ value: String, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).font(.system(size: 11.5)).foregroundStyle(AppTheme.ink3).lineLimit(1)
      Text(value).font(AppTheme.number(20)).monospacedDigit().foregroundStyle(color)
        .lineLimit(1).minimumScaleFactor(0.7)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 14).padding(.vertical, 12)
    .cardBackground(radius: 14)
    .accessibilityElement(children: .combine)
  }

  // MARK: Timeline

  private var days: [HistoryDay] {
    let calendar = Calendar.current
    var order: [Date] = []
    var buckets: [Date: [HistoryEntry]] = [:]
    for entry in model.history {
      let day = calendar.startOfDay(for: entry.date)
      if buckets[day] == nil { order.append(day) }
      buckets[day, default: []].append(entry)
    }
    return order.map { HistoryDay(id: $0, entries: buckets[$0] ?? []) }
  }

  private func dayTitle(_ day: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(day) { return "Today" }
    if calendar.isDateInYesterday(day) { return "Yesterday" }
    if calendar.isDate(day, equalTo: Date(), toGranularity: .year) {
      return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
    return day.formatted(.dateTime.month(.wide).day().year())
  }

  private func daySection(_ day: HistoryDay) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Eyebrow(dayTitle(day.id))
        .padding(.horizontal, 2).padding(.top, 4)
        .accessibilityAddTraits(.isHeader)
      ForEach(day.entries) { entry in
        entryCard(entry)
      }
    }
  }

  private func toggle(_ id: UUID) {
    if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
  }

  private func entryStyle(_ entry: HistoryEntry) -> (symbol: String, swatch: AppTheme.Swatch) {
    if entry.restoresThroughPhotos { return ("photo", .pink) }
    if entry.action.localizedCaseInsensitiveContains("uninstall") { return ("app.badge", .violet) }
    return ("trash", .slate)
  }

  private func status(for entry: HistoryEntry) -> ReceiptStatus {
    if entry.restoresThroughPhotos { return .photos }
    if let unresolved = entry.unresolvedPaths, !unresolved.isEmpty { return .needsCheck }
    guard let receipts = entry.receipts else { return .legacy }
    if receipts.isEmpty { return .nothingMoved }
    let pending = entry.pendingReceipts
    if pending.isEmpty { return .restored }
    if pending.count < receipts.count { return .partlyRestored }
    let inTrash = pending.contains { receipt in
      guard let trashPath = receipt.trashPath else { return false }
      return FileManager.default.fileExists(atPath: trashPath)
    }
    return inTrash ? .restorable : .notInTrash
  }

  private func statusInfo(_ status: ReceiptStatus) -> (title: String, symbol: String, swatch: AppTheme.Swatch) {
    switch status {
    case .photos: return ("Restore through Photos", "photo.fill", .pink)
    case .legacy: return ("Restore in Finder", "folder.fill", .slate)
    case .nothingMoved: return ("Nothing moved", "minus.circle.fill", .slate)
    case .needsCheck: return ("Needs a check", "exclamationmark.triangle.fill", .amber)
    case .restorable: return ("In Trash · restorable", "trash.fill", .mint)
    case .partlyRestored: return ("Partly restored", "arrow.uturn.backward.circle.fill", .sky)
    case .restored: return ("Restored", "checkmark.circle.fill", .mint)
    case .notInTrash: return ("Not in Trash", "trash.slash.fill", .graphite)
    }
  }

  private func entryCard(_ entry: HistoryEntry) -> some View {
    let pending = entry.pendingReceipts
    let isOpen = expanded.contains(entry.id)
    let style = entryStyle(entry)
    let info = statusInfo(status(for: entry))
    return VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 12) {
        Button { toggle(entry.id) } label: {
          HStack(spacing: 12) {
            SwatchBadge(symbol: style.symbol, swatch: style.swatch, size: 34)
            VStack(alignment: .leading, spacing: 2) {
              Text(entry.action).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(AppTheme.ink).lineLimit(1)
              Text(entry.date.formatted(date: .omitted, time: .shortened) + (entry.notes.isEmpty ? "" : " · " + entry.notes))
                .font(.system(size: 11.5)).foregroundStyle(AppTheme.ink3).lineLimit(2)
              if let restored = entry.restoredPaths, !restored.isEmpty {
                Label("\(restored.count) restored", systemImage: "arrow.uturn.backward.circle.fill")
                  .font(.system(size: 11, weight: .medium))
                  .foregroundStyle(AppTheme.accentText)
              }
            }
            Spacer(minLength: 8)
            Chip(title: info.title, symbol: info.symbol, swatch: info.swatch).fixedSize()
            Text(entry.restoresThroughPhotos && entry.bytes == 0 ? "Size unavailable" : ByteFormatter.string(entry.bytes))
              .font(AppTheme.number(13)).monospacedDigit().foregroundStyle(AppTheme.ink)
              .frame(minWidth: 64, alignment: .trailing)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(isOpen ? "Hides the items" : "Shows the items")
        if pending.count > 1 {
          Button { model.restore(pending, entryID: entry.id) } label: {
            Label("Restore All", systemImage: "arrow.uturn.backward")
          }
          .buttonStyle(MintButtonStyle(.secondary)).controlSize(.small)
        }
        Button { toggle(entry.id) } label: {
          Image(systemName: isOpen ? "chevron.up" : "chevron.down")
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(AppTheme.ink2)
            .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOpen ? "Hide items" : "Show items")
        .help(isOpen ? "Hide items" : "Show items")
      }
      .padding(.horizontal, 14).padding(.vertical, 12)
      if isOpen {
        Rectangle().fill(AppTheme.divider).frame(height: 1)
        details(entry)
          .padding(.leading, 60).padding(.trailing, 14).padding(.vertical, 10)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardBackground()
  }

  // MARK: Receipts

  private func emptyReceiptsNote(_ entry: HistoryEntry) -> String {
    if entry.restoresThroughPhotos {
      return "Restore through Photos → Recently Deleted while available. Deletion can sync to your other devices."
    }
    if entry.receipts == nil {
      return "Recorded before MacMint tracked Trash locations. Use Finder to restore these items from the Trash."
    }
    return entry.notes
  }

  @ViewBuilder private func details(_ entry: HistoryEntry) -> some View {
    let receipts = entry.receipts ?? []
    VStack(alignment: .leading, spacing: 6) {
      if let unresolved = entry.unresolvedPaths, !unresolved.isEmpty {
        Label("These interrupted moves could not be verified. Inspect their original locations and Trash in Finder.", systemImage: "exclamationmark.triangle")
          .font(.system(size: 11.5)).foregroundStyle(AppTheme.warning)
          .fixedSize(horizontal: false, vertical: true)
        ForEach(unresolved, id: \.self) { path in
          Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(AppTheme.ink2).textSelection(.enabled)
        }
      }
      if receipts.isEmpty {
        Text(emptyReceiptsNote(entry))
          .font(.system(size: 12))
          .foregroundStyle(AppTheme.ink2)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.vertical, 2)
        if entry.restoresThroughPhotos {
          Button("Open Photos") { PhotoLibraryService.showInPhotos() }
            .buttonStyle(MintButtonStyle(.secondary)).controlSize(.small)
        }
        ForEach(entry.paths, id: \.self) { path in
          Text(path).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(AppTheme.ink2)
            .lineLimit(1).truncationMode(.middle)
        }
      } else {
        ForEach(receipts, id: \.originalPath) { receipt in
          receiptRow(receipt, entry: entry)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func receiptRow(_ receipt: TrashReceipt, entry: HistoryEntry) -> some View {
    let url = URL(fileURLWithPath: receipt.originalPath)
    let restored = entry.isRestored(receipt)
    let available = model.canRestore(receipt)
    return HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(url.lastPathComponent).font(.system(size: 12.5, weight: .medium)).foregroundStyle(AppTheme.ink).lineLimit(1)
        Text(entry.restoredLocations?[receipt.originalPath] ?? url.deletingLastPathComponent().path)
          .font(.system(size: 11, design: .monospaced)).foregroundStyle(AppTheme.ink3)
          .lineLimit(1).truncationMode(.middle)
      }
      Spacer(minLength: 8)
      Text(ByteFormatter.string(receipt.bytes))
        .font(AppTheme.number(12, weight: .semibold)).monospacedDigit()
        .foregroundStyle(AppTheme.ink2)
      if restored {
        Chip(title: "Restored", symbol: "checkmark", swatch: .mint).fixedSize()
        if let destination = entry.restoredLocations?[receipt.originalPath] {
          Button("Show") { model.reveal(URL(fileURLWithPath: destination)) }
            .buttonStyle(MintButtonStyle(.secondary)).controlSize(.small)
        }
      } else if available {
        Button { model.restore([receipt], entryID: entry.id) } label: {
          Label("Restore", systemImage: "arrow.uturn.backward")
        }
        .buttonStyle(MintButtonStyle(.secondary)).controlSize(.small)
      } else {
        Menu {
          Button("Restore to Another Folder…") {
            model.restoreElsewhere(
              .init(entryID: entry.id, receipt: receipt, message: ""))
          }
          Button("Show in Trash") { model.revealInTrash(receipt) }
        } label: {
          Text(restoreUnavailableReason(receipt)).font(.system(size: 11.5))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
      }
    }
    .padding(.vertical, 4)
  }

  private func restoreUnavailableReason(_ receipt: TrashReceipt) -> String {
    guard let trashPath = receipt.trashPath else { return "Not restorable" }
    if !FileManager.default.fileExists(atPath: trashPath) { return "Not in Trash" }
    if FileManager.default.fileExists(atPath: receipt.originalPath) { return "Original location occupied" }
    return "Identity could not be verified"
  }
}
