import AppKit
import MacCleanerCore
import SwiftUI

struct HelpView: View {
  @EnvironmentObject private var model: AppViewModel
  @EnvironmentObject private var account: AccountStore
  @Environment(\.dismiss) private var dismiss
  @State private var showDiagnostics = false
  @State private var showPermissions = false
  @State private var exportError: String?
  @State private var query = ""
  @State private var selectedTopic = "space"
  @State private var copied = false
  private var diagnostics: String {
    """
    MacMint \(UpdateService.currentVersion)
    macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
    Scan completed: \(model.lastScanDate?.formatted() ?? "Not run")
    Completed categories: \(model.scanCompletedAreas.count)
    Scan issues: \(model.scanIssues.count)
    Recovery warnings: \(model.recoveryWarnings.count)
    Exclusions: \(model.ignoredPaths.count)
    History operations: \(model.history.count)
    Access: \(account.isUnlocked ? "Pro" : "Local inspection")
    AI consent: \(model.aiEnabled ? "Enabled" : "Disabled")
    AI available: \(account.aiAvailable)
    No account identifiers, names, paths, questions, or file contents are included.
    """
  }

  private struct Topic: Identifiable {
    let id: String
    let title: String
    let text: String
    let symbol: String
    let swatch: AppTheme.Swatch
  }

  private var topics: [Topic] {
    [
      Topic(id: "space", title: "Why didn't my free space increase?",
        text: "Moving files to Trash does not free their space. Review Trash in Finder when you no longer need recovery. APFS snapshots, shared file blocks and other activity can affect the observed change.",
        symbol: "internaldrive.fill", swatch: .indigo),
      Topic(id: "access", title: "An area could not be read",
        text: "Check the scan issues. Full Disk Access can improve coverage; choose System Settings → Privacy & Security → Full Disk Access. Continue without it to inspect permitted locations.",
        symbol: "lock.shield.fill", swatch: .amber),
      Topic(id: "restore", title: "How do I restore?",
        text: "Open History and expand an operation. Restore never overwrites another item. For conflicts, choose another folder. Photos assets are recovered through Photos, while available in Recently Deleted. iCloud Photos deletion also affects synced devices.",
        symbol: "clock.arrow.circlepath", swatch: .slate),
      Topic(id: "quickscan", title: "What is included in Quick Scan?",
        text: "Known cache locations, installed apps, startup metadata, Downloads, removed-app data and home Trash. It runs when MacMint opens (turn that off in Settings), and pages that need it load the first time you open them. Whole-folder storage maps, duplicate comparisons and photo analysis start only when you choose them.",
        symbol: "dot.radiowaves.left.and.right", swatch: .mint),
      Topic(id: "ai", title: "How does AI use my data?",
        text: "AI is optional and cannot select or remove items. Automatic context uses storage categories and known tool identifiers. Your typed question and recent conversation are sent as written. Preview the context before enabling AI.",
        symbol: "sparkles", swatch: .iris),
      Topic(id: "keys", title: "Keyboard shortcuts",
        text: "⌘K opens Go To for any page, action or item. ⌘1 to ⌘9 open Overview, Cleanup, Storage, Apps, Photos, Developer, History, Performance and Review. ⌘R runs Quick Scan. ⌘, opens Settings.",
        symbol: "keyboard", swatch: .sky),
    ]
  }

  private var filteredTopics: [Topic] {
    let tokens = query.lowercased().split(separator: " ").map(String.init)
    guard !tokens.isEmpty else { return topics }
    return topics.filter { topic in
      let haystack = (topic.title + " " + topic.text).lowercased()
      return tokens.allSatisfy { haystack.contains($0) }
    }
  }

  var body: some View {
    let shown = filteredTopics
    let current = shown.first { $0.id == selectedTopic } ?? shown.first
    VStack(spacing: 0) {
      SheetHeader(symbol: "questionmark.circle.fill", swatch: .mint, eyebrow: "Help", title: "Help & recovery",
        subtitle: "A little guidance, whenever you need it.")
      Rectangle().fill(AppTheme.divider).frame(height: 1)
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          SearchField(prompt: "Search help", text: $query)
          Text("Scans and previews work locally before sign-in. An active plan is needed to start a removal. History and Restore remain available.")
            .font(.system(size: 12.5))
            .foregroundStyle(AppTheme.ink2)
            .fixedSize(horizontal: false, vertical: true)
          if shown.isEmpty {
            Text("No topics match. Try another word, or contact support below.")
              .font(.system(size: 12.5))
              .foregroundStyle(AppTheme.ink2)
              .padding(.vertical, 8)
          } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
              ForEach(shown) { topic in
                tile(topic, selected: topic.id == current?.id)
              }
            }
            if let current { answer(current) }
          }
          actionsCard
          diagnosticsCard
        }
        .padding(22)
      }
      SheetFooter {
        Label("Here to help", systemImage: "leaf.fill")
          .font(.system(size: 11.5))
          .foregroundStyle(AppTheme.ink2)
        Spacer()
        Button("Done") { dismiss() }
          .buttonStyle(MintButtonStyle())
          .keyboardShortcut(.defaultAction)
      }
    }
    .frame(width: 660, height: 640)
    .background(AppTheme.canvas)
    .sheet(isPresented: $showPermissions) { PermissionHelpSheet() }
    .onExitCommand { dismiss() }
  }

  // MARK: Topics

  private func tile(_ topic: Topic, selected: Bool) -> some View {
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    return Button {
      selectedTopic = topic.id
    } label: {
      HStack(spacing: 10) {
        SwatchBadge(symbol: topic.symbol, swatch: topic.swatch, size: 28)
        Text(topic.title)
          .font(.system(size: 12.5, weight: .semibold))
          .foregroundStyle(AppTheme.ink)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
      .cardBackground(selected ? topic.swatch.tint : AppTheme.surface, radius: 12)
      .overlay(shape.strokeBorder(selected ? topic.swatch.color.opacity(0.55) : Color.clear, lineWidth: 1.5))
      .contentShape(shape)
    }
    .buttonStyle(CardButtonStyle())
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityHint("Shows the answer below")
  }

  private func answer(_ topic: Topic) -> some View {
    HStack(alignment: .top, spacing: 12) {
      SwatchBadge(symbol: topic.symbol, swatch: topic.swatch, size: 32)
      VStack(alignment: .leading, spacing: 5) {
        Text(topic.title)
          .font(.system(size: 15, weight: .bold))
          .tracking(-0.2)
          .foregroundStyle(AppTheme.ink)
          .accessibilityAddTraits(.isHeader)
        Text(topic.text)
          .font(.system(size: 13))
          .foregroundStyle(AppTheme.ink2)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
      Spacer(minLength: 0)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardBackground()
  }

  // MARK: Actions

  private var actionsCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Get going")
        .font(.system(size: 15, weight: .bold))
        .tracking(-0.2)
        .foregroundStyle(AppTheme.ink)
        .accessibilityAddTraits(.isHeader)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) { actionButtons }
        VStack(alignment: .leading, spacing: 8) { actionButtons }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardBackground()
  }

  @ViewBuilder private var actionButtons: some View {
    Button {
      dismiss()
      model.startTour()
    } label: {
      Label("Take the Quick Tour", systemImage: "map.fill")
    }
    .buttonStyle(MintButtonStyle(.area))
    .environment(\.areaSwatch, .iris)
    Button {
      showPermissions = true
    } label: {
      Label("Permissions & Setup…", systemImage: "lock.shield")
    }
    .buttonStyle(MintButtonStyle(.secondary))
    Button {
      NSWorkspace.shared.open(URL(string: "mailto:support@macmint.co")!)
    } label: {
      Label("Contact Support", systemImage: "envelope")
    }
    .buttonStyle(MintButtonStyle(.secondary))
  }

  // MARK: Diagnostics

  private var diagnosticsCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 10) {
        SwatchBadge(symbol: "stethoscope", swatch: .slate, size: 28)
        VStack(alignment: .leading, spacing: 1) {
          Text("Diagnostics")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(AppTheme.ink)
          Text("A short summary for support. No account details, names, paths or file contents.")
            .font(.system(size: 11.5))
            .foregroundStyle(AppTheme.ink3)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        Toggle("Preview diagnostic summary", isOn: $showDiagnostics)
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.small)
      }
      if showDiagnostics {
        Text(diagnostics)
          .font(.system(size: 11.5, design: .monospaced))
          .foregroundStyle(AppTheme.ink)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
          .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        HStack(spacing: 8) {
          Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(diagnostics, forType: .string)
            copied = true
          } label: {
            Label(copied ? "Copied" : "Copy Diagnostics", systemImage: copied ? "checkmark" : "doc.on.doc")
          }
          .buttonStyle(MintButtonStyle(.secondary))
          .controlSize(.small)
          Button("Export this summary…") {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "MacMint-diagnostics.txt"
            if panel.runModal() == .OK, let url = panel.url {
              do { try diagnostics.write(to: url, atomically: true, encoding: .utf8); exportError = nil }
              catch {
                let message = "Could not export diagnostics: \(error.localizedDescription)"
                exportError = message
                model.statusMessage = message
              }
            }
          }
          .buttonStyle(MintButtonStyle(.secondary))
          .controlSize(.small)
        }
        if let exportError {
          Label(exportError, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12))
            .foregroundStyle(AppTheme.warning)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardBackground()
  }
}
