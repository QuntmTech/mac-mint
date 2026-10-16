import MacCleanerCore
import SwiftUI

// MARK: - Shared row

struct PlanItemRow: View {
  let item: PlanItem
  var onRemove: (() -> Void)? = nil
  @EnvironmentObject private var model: AppViewModel
  @State private var expanded = false
  @State private var childNames: [String] = []

  var body: some View {
    HStack(spacing: 11) {
      ZStack {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill((item.needsAttention ? Color.orange : AppTheme.accent).opacity(0.12))
          .frame(width: 30, height: 30)
        Image(systemName: Self.icon(for: item.kind))
          .accessibilityHidden(true)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(item.needsAttention ? Color.orange : AppTheme.accentText)
      }
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(item.displayName).fontWeight(.medium).lineLimit(1)
          if item.needsAttention {
            StatusPill(title: "Review", icon: "eye.fill", tint: .orange)
          }
        }
        Text(item.kind.label + " · " + (item.ownerBundleID ?? "Owner not identified"))
          .font(.caption2).foregroundStyle(.secondary)
        Text(item.snapshot?.modified.map { "Last changed " + $0.formatted() } ?? "Change time not recorded")
          .font(.caption2).foregroundStyle(.tertiary)
        Text(item.reason).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Text(item.url.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
          .truncationMode(.middle)
        if (try? item.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
          DisclosureGroup("Inspect folder contents", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 3) {
              Text("First 100 direct children; use Finder for the complete folder.").foregroundStyle(.secondary)
              ForEach(childNames, id: \.self) { Text($0).textSelection(.enabled) }
            }.font(.caption)
          }
          .task(id: expanded) {
            guard expanded else { return }
            let url = item.url
            childNames = await Task.detached(priority: .utility) {
              do { return Array(try FileManager.default.contentsOfDirectory(atPath: url.path).sorted().prefix(100)) }
              catch { return ["Contents could not be read: " + error.localizedDescription] }
            }.value
          }
        }
      }
      Spacer(minLength: 8)
      Text(ByteFormatter.string(item.expectedBytes))
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
      Button {
        model.reveal(item.url)
      } label: {
        Image(systemName: "magnifyingglass.circle")
          .accessibilityLabel("Reveal in Finder")
      }
      .buttonStyle(.borderless)
      .help("Reveal in Finder")
      if let onRemove {
        Button(action: onRemove) {
          Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            .accessibilityLabel("Remove \(item.displayName) from review")
        }
        .buttonStyle(.borderless)
        .help("Remove from review")
      }
    }
    .padding(.vertical, 3)
    .accessibilityElement(children: .contain)
  }

  static func icon(for kind: PlanItemKind) -> String {
    switch kind {
    case .cleanupTarget(let category, _):
      switch category {
      case .userCaches: return "shippingbox"
      case .userLogs: return "doc.text.magnifyingglass"
      case .browserCaches: return "globe"
      case .developerJunk: return "hammer"
      case .deviceBackups: return "iphone.gen3"
      case .diagnostics: return "waveform.path.ecg"
      case .appLeftovers: return "app.badge"
      case .installers: return "shippingbox.and.arrow.backward"
      case .mailAttachments: return "paperclip"
      case .deviceFirmware: return "iphone.and.arrow.forward"
      }
    case .appBundle: return "app.fill"
    case .appLeftover: return "folder.badge.gearshape"
    case .duplicateCopy: return "square.on.square"
    case .reviewedFile: return "doc.fill"
    case .developerArtifact: return "hammer.fill"
    }
  }
}

// MARK: - Review sheet (shown before anything moves)

struct PlanReviewSheet: View {
  @State private var plan: OperationPlan

  init(plan: OperationPlan) { _plan = State(initialValue: plan) }

  @EnvironmentObject private var model: AppViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var showExcluded = false

  private var grouped: [(String, [PlanItem])] {
    plan.sources.map { source in (source, plan.items.filter { $0.source == source }) }
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if plan.isEmpty {
        EmptyState(
          icon: "hand.raised", title: "Nothing can be moved",
          detail: "Everything selected was skipped for the reasons below.")
          .frame(minHeight: 160)
      } else {
        List {
          ForEach(grouped, id: \.0) { source, items in
            Section {
              ForEach(items, id: \.url) { item in
                PlanItemRow(item: item, onRemove: { remove(item) })
                  .contextMenu {
                    Button("Keep this item") { remove(item) }
                    Button("Exclude from Future Scans") {
                      model.ignore(item.url)
                      remove(item)
                    }
                    Button("Show Folder Contents in Finder") { model.reveal(item.url) }
                  }
              }
            } header: {
              HStack {
                Text(source)
                Spacer()
                Text(ByteFormatter.string(items.reduce(0) { $0 + $1.expectedBytes }))
                  .monospacedDigit()
              }
            }
          }
        }
        .listStyle(.inset)
        .frame(minHeight: 240)
      }
      if !plan.excluded.isEmpty || !plan.covered.isEmpty {
        Divider()
        notes
      }
      Divider()
      footer
    }
    .frame(width: 720)
    .frame(minHeight: 420, maxHeight: 680)
  }

  private func remove(_ item: PlanItem) {
    let remaining = (plan.items + plan.covered).filter {
      !FileSystem.path($0.url, isInsideOrEqual: item.url)
    }
    for removed in (plan.items + plan.covered) where FileSystem.path(removed.url, isInsideOrEqual: item.url) {
      model.dequeue(removed)
    }
    plan = OperationPlanner.plan(title: plan.title, items: remaining,
      ignoredPaths: model.ignoredPaths, excluded: plan.excluded, protecting: plan.keeperConstraints, validationItems: plan.validationItems)
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: "trash.circle.fill")
        .font(.system(size: 38))
        .foregroundStyle(AppTheme.accentText)
      VStack(alignment: .leading, spacing: 4) {
        Text("Review: \(plan.title)").font(.title2.bold())
        Text(
          "\(plan.items.count) item\(plan.items.count == 1 ? "" : "s") • \(ByteFormatter.string(plan.totalBytes)) will be moved to the Trash."
        )
        .foregroundStyle(.secondary)
        if !plan.attentionItems.isEmpty {
          Label(
            "\(plan.attentionItems.count) item\(plan.attentionItems.count == 1 ? " needs" : "s need") a closer look (\(ByteFormatter.string(plan.attentionBytes))) — personal files, backups, or data that may not be rebuilt.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.callout)
          .foregroundStyle(.orange)
        }
      }
      Spacer()
    }
    .padding(20)
  }

  private var notes: some View {
    VStack(alignment: .leading, spacing: 6) {
      if !plan.covered.isEmpty {
        Label(
          "\(plan.covered.count) selected item\(plan.covered.count == 1 ? " is" : "s are") already inside a selected folder and counted once.",
          systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      if !plan.excluded.isEmpty {
        DisclosureGroup(isExpanded: $showExcluded) {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(plan.excluded.enumerated()), id: \.offset) { _, failure in
              VStack(alignment: .leading, spacing: 1) {
                Text(failure.url.lastPathComponent).font(.caption.weight(.medium))
                Text(failure.message).font(.caption2).foregroundStyle(.secondary)
              }
            }
          }
          .padding(.top, 4)
        } label: {
          Label(
            "\(plan.excluded.count) item\(plan.excluded.count == 1 ? "" : "s") won't be moved",
            systemImage: "hand.raised.fill"
          )
          .font(.caption.weight(.semibold))
          .foregroundStyle(.orange)
        }
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var footer: some View {
    HStack {
      Label(
        "Files go to Trash. Restore is available while the recorded items remain there.",
        systemImage: "arrow.uturn.backward.circle"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Spacer()
      Button("Cancel", role: .cancel) { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button {
        model.execute(plan)
      } label: {
        Text("Move \(plan.items.count) Item\(plan.items.count == 1 ? "" : "s") to Trash")
      }
      .buttonStyle(.borderedProminent)
      .keyboardShortcut(.defaultAction)
      .disabled(plan.isEmpty)
    }
    .padding(16)
  }
}

// MARK: - Result sheet (after an operation)

struct OperationReportSheet: View {
  let report: OperationReport
  @EnvironmentObject private var model: AppViewModel
  @Environment(\.dismiss) private var dismiss

  private var allGood: Bool { report.problems.isEmpty && !report.wasCancelled && report.persistenceError == nil }

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 14) {
        Image(systemName: allGood ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
          .font(.system(size: 38))
          .foregroundStyle(allGood ? AppTheme.accentText : .orange)
        VStack(alignment: .leading, spacing: 4) {
          Text(report.moved.isEmpty ? "Nothing was moved" : "\(ByteFormatter.string(report.bytesMoved)) moved to Trash")
            .font(.title2.bold())
          Text(report.summary + ".")
            .foregroundStyle(.secondary)
          Text("Moving to Trash may not change free space. Emptying Trash, snapshots, clones, and cloud storage affect the eventual savings.")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        Spacer()
      }
      .padding(20)

      if !report.problems.isEmpty || !report.notAttempted.isEmpty {
        Divider()
        List {
          if !report.problems.isEmpty {
            Section("Items needing attention") {
              ForEach(report.problems) { outcome in
                VStack(alignment: .leading, spacing: 2) {
                  Text(outcome.item.displayName).fontWeight(.medium)
                  Text(outcome.message ?? "Skipped").font(.caption).foregroundStyle(.secondary)
                }
              }
            }
          }
          if !report.notAttempted.isEmpty {
            Section("Not started (operation was stopped)") {
              ForEach(report.notAttempted) { Text($0.item.displayName) }
            }
          }
        }
        .listStyle(.inset)
        .frame(minHeight: 160, maxHeight: 320)
      }

      Divider()
      HStack {
        if !report.receipts.isEmpty {
          Button {
            model.undo(report)
          } label: {
            Label("Undo", systemImage: "arrow.uturn.backward")
          }
          .help("Put every moved item back where it was")
        }
        Button("Show History") {
          model.selectedSection = .history
          dismiss()
        }
        Spacer()
        Button("Done") { dismiss() }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      }
      .padding(16)
    }
    .frame(width: 600)
    .onExitCommand { dismiss() }
  }
}

// MARK: - Review queue screen

struct ReviewQueueView: View {
  @EnvironmentObject private var model: AppViewModel

  private var grouped: [(String, [PlanItem])] {
    let items = model.queuedItems
    var order: [String] = []
    for item in items where !order.contains(item.source) { order.append(item.source) }
    return order.map { source in (source, items.filter { $0.source == source }) }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .center, spacing: 14) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Review").font(.system(size: 30, weight: .bold, design: .rounded))
          Text("Everything you've selected across Cleaner, Storage, Developer & AI, Duplicates, and Large Files — in one place.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        if model.queuedCount > 0 {
          Button("Clear All") { model.clearQueue() }
          Button {
            model.reviewEverything()
          } label: {
            if model.isPreparingPlan {
              ProgressView().controlSize(.small)
            } else {
              Label("Review \(ByteFormatter.string(model.queuedBytes))", systemImage: "checklist")
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(model.isWorking || model.isScanning || model.isPreparingPlan)
        }
      }
      .padding(AppTheme.pagePadding)
      Divider()

      if model.queuedCount == 0 {
        EmptyState(
          icon: "checklist", title: "Nothing selected yet",
          detail: "Select items in Cleaner, Storage, Developer & AI, Duplicates, or Large Files and they'll gather here for one final review.")
      } else {
        List {
          ForEach(grouped, id: \.0) { source, items in
            Section {
              ForEach(items, id: \.url) { item in
                PlanItemRow(item: item) { model.dequeue(item) }
              }
            } header: {
              HStack {
                Text(source)
                Spacer()
                Text(ByteFormatter.string(items.reduce(0) { $0 + $1.expectedBytes })).monospacedDigit()
              }
            }
          }
        }
        .listStyle(.inset)
      }
    }
  }
}


struct RestoreConflictsSheet: View {
  @EnvironmentObject private var model: AppViewModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Restore needs attention").font(.title2.bold())
      Text("Choose what to do with each item. Existing files are never overwritten.")
        .foregroundStyle(.secondary)
      List(model.restoreConflicts) { conflict in
        VStack(alignment: .leading, spacing: 6) {
          Text(conflict.receipt.originalPath).font(.callout.weight(.medium)).textSelection(.enabled)
          Text(conflict.message).font(.caption).foregroundStyle(.secondary)
          HStack {
            Button("Restore Elsewhere…") { model.restoreElsewhere(conflict) }
            Button("Show in Trash") { model.revealInTrash(conflict.receipt) }
            Button("Skip") { model.skipRestoreConflict(conflict) }
          }.disabled(model.isWorking)
        }.padding(.vertical, 5)
      }
      Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
    }.padding(20).frame(width: 680, height: 460)
  }
}
