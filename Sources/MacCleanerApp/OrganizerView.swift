import MacCleanerCore
import SwiftUI

struct OrganizerView: View {
  var historyOnly = false
  @EnvironmentObject private var model: AppViewModel
  @EnvironmentObject private var account: AccountStore
  @Environment(\.dismiss) private var dismiss
  @State private var inventory: OrganizationInventory?
  @State private var proposals: [OrganizationProposal] = []
  @State private var selected: Set<String> = []
  @State private var problems: [String: String] = [:]
  @State private var records: [OrganizationRecord] = []
  @State private var localBusy = false
  @StateObject private var suggestions = OrganizationSuggestionSession()
  @State private var error: String?
  @State private var confirmation = false
  @State private var showingActivation = false
  @State private var showHistory = false
  @State private var consentPayload: AIOrganizationRequest?
  @State private var consentText = ""
  @State private var consentSheet = false
  @State private var validatedInput: ValidationInput?

  private var busy: Bool { localBusy || suggestions.isBusy }

  private struct ValidationInput: Hashable {
    let inventoryID: UUID?
    let proposals: [OrganizationProposal]
    let ignoredPaths: Set<String>
  }

  private var validationInput: ValidationInput {
    .init(inventoryID: inventory?.id, proposals: proposals, ignoredPaths: model.ignoredPaths)
  }
  private var validationPending: Bool {
    !proposals.isEmpty && validatedInput != validationInput
  }

  var body: some View {
    let history = showHistory || historyOnly
    VStack(spacing: 0) {
      SheetHeader(
        symbol: history ? "clock.arrow.circlepath" : "folder.badge.gearshape", swatch: .teal,
        eyebrow: "Organize",
        title: history ? "Organization history" : "A place for every file",
        subtitle: "Preview names and moves. Files stay in the folder you choose and never go to the Trash. Existing files are never overwritten."
      ) {
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
          .buttonStyle(MintButtonStyle(.secondary))
          .controlSize(.small)
      }
      Rectangle().fill(AppTheme.divider).frame(height: 1)
      if let error { errorBanner(error) }
      if history { historyContent }
      else if let inventory { proposalContent(inventory) }
      else {
        EmptyState(icon: "folder.badge.gearshape", title: "Start with one folder",
          detail: "Inspect up to 100 local documents and media files. Use existing subfolders, edit names, and review every change. App data, repositories, cloud-only files, and nested files are skipped.",
          actionTitle: "Choose folder…", action: chooseFolder,
          trust: "Files only move inside the folder you pick. Nothing goes to the Trash.",
          swatch: .teal)
      }
      SheetFooter {
        if !historyOnly {
          Button(showHistory ? "Back to preview" : "History & Undo") { showHistory.toggle(); Task { await loadHistory() } }
            .buttonStyle(MintButtonStyle(.plain))
        }
        if busy {
          ProgressView().controlSize(.small)
          Text("Working…").font(.system(size: 11.5)).foregroundStyle(AppTheme.ink2)
        } else if validationPending {
          ProgressView().controlSize(.small)
          Text("Checking changes…").font(.system(size: 11.5)).foregroundStyle(AppTheme.ink2)
        }
        if suggestions.isBusy {
          Button("Cancel suggestions") { cancelRequest() }
            .buttonStyle(MintButtonStyle(.secondary))
            .controlSize(.small)
        }
        Spacer()
        if inventory != nil && !showHistory && !historyOnly {
          Button("Choose another folder…", action: chooseFolder).disabled(busy)
            .buttonStyle(MintButtonStyle(.secondary))
          Button("Review \(selected.count) changes") { confirmation = true }
            .buttonStyle(MintButtonStyle()).disabled(busy || validationPending || selected.isEmpty || selected.contains { problems[$0] != nil } || model.isWorking || model.isScanning)
        }
      }
    }
    .background(AppTheme.elevated)
    .frame(minWidth: 700, idealWidth: 840, maxWidth: 960, minHeight: 520, idealHeight: 660)
    .task { await loadHistory(); if !SmokeTest.isRequested { await account.refreshAIStatus() } }
    .task(id: validationInput) { await validate() }
    .onChange(of: model.ignoredPaths) { _, _ in cancelRequest() }
    .onChange(of: model.aiEnabled) { _, enabled in if !enabled { cancelRequest() } }
    .onChange(of: account.isUnlocked) { _, unlocked in if !unlocked { cancelRequest() } }
    .onDisappear { cancelRequest() }
    .sheet(isPresented: $showingActivation) { AccountAccessSheet(purpose: .paidAction) }
    .sheet(isPresented: $consentSheet) { consentView }
    .alert("Apply \(selected.count) reviewed changes?", isPresented: $confirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Apply changes") { apply() }
    } message: { Text("Selected files will be renamed or moved within the chosen folder. Recovery records are written first. Use History & Undo to reverse changes when their files and locations are still available.") }
  }

  private func errorBanner(_ error: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(error, systemImage: "exclamationmark.triangle.fill")
        .font(.system(size: 12.5))
        .foregroundStyle(AppTheme.warning)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      Button("Show organization records in Finder") { model.reveal(model.supportDirectory.appendingPathComponent("Organization")) }
        .buttonStyle(MintButtonStyle(.plain))
        .controlSize(.small)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(AppTheme.warningTint, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    .padding(.horizontal, 20)
    .padding(.top, 12)
  }

  private func proposalContent(_ inventory: OrganizationInventory) -> some View {
    let validating = validationPending
    return VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 12) {
        SwatchBadge(symbol: "folder", swatch: .teal, size: 30)
        VStack(alignment: .leading, spacing: 2) {
          Text(inventory.root.lastPathComponent)
            .font(.system(size: 15, weight: .bold)).tracking(-0.2)
            .foregroundStyle(AppTheme.ink)
            .lineLimit(1)
          Text("\(inventory.files.count) eligible files · \(inventory.omitted) skipped\(inventory.wasLimited ? " · inspection stopped at 500 entries" : "")")
            .font(.system(size: 11.5)).monospacedDigit()
            .foregroundStyle(AppTheme.ink3)
        }
        .accessibilityElement(children: .combine)
        Spacer(minLength: 8)
        Button("Suggest by file type") {
          suggestLocally(inventory)
        }
        .buttonStyle(MintButtonStyle(.secondary))
        .controlSize(.small)
        .disabled(busy)
        Button { prepareAI(inventory) } label: { Label("Suggest with AI…", systemImage: "sparkles") }
          .buttonStyle(MintButtonStyle(.secondary))
          .controlSize(.small)
          .disabled(busy || inventory.files.isEmpty || !account.aiStatus.allows("organize"))
          .help(account.aiStatus.allows("organize") ? "Preview the names sent before requesting suggestions" : "AI organization is not enabled by the service. File-type suggestions and manual edits work locally.")
      }
      Text("AI uses names only in this version. Nothing is selected automatically. Select a row to approve its proposed change.")
        .font(.system(size: 11.5))
        .foregroundStyle(AppTheme.ink2)
        .fixedSize(horizontal: false, vertical: true)
      if proposals.isEmpty {
        Button("Prepare manual edits") {
          proposals = inventory.files.map { .init(fileID: $0.id, folderID: "root", name: $0.name, reason: "Your manual edit") }
        }
        .buttonStyle(MintButtonStyle(.secondary))
        .disabled(busy || inventory.files.isEmpty)
        Spacer()
        Text("File-type suggestions use existing folders named Documents, Photos, Videos, Audio, or Archives. You can also edit names and destinations yourself.")
          .font(.system(size: 13))
          .foregroundStyle(AppTheme.ink2)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 420)
          .frame(maxWidth: .infinity, alignment: .center)
        Spacer()
      } else {
        ScrollView {
          LazyVStack(spacing: 12) {
            ForEach(folderGroups(inventory)) { group in
              folderCard(group, inventory: inventory, validating: validating)
            }
          }.padding(.vertical, 4)
        }
      }
    }.padding(20)
  }

  /// Proposals gathered under the folder each one moves to.
  private struct FolderGroup: Identifiable {
    let id: String
    let title: String
    let proposals: [OrganizationProposal]
  }

  private func folderGroups(_ inventory: OrganizationInventory) -> [FolderGroup] {
    var groups: [FolderGroup] = []
    var placed: Set<String> = []
    for folder in inventory.folders where !placed.contains(folder.id) {
      let items = proposals.filter { $0.folderID == folder.id }
      guard !items.isEmpty else { continue }
      placed.insert(folder.id)
      let title = folder.id == "root" ? "Stays in \(inventory.root.lastPathComponent)" : folder.name
      groups.append(FolderGroup(id: folder.id, title: title, proposals: items))
    }
    let other = proposals.filter { !placed.contains($0.folderID) }
    if !other.isEmpty {
      groups.append(FolderGroup(id: "macmint.other-folders", title: "Other", proposals: other))
    }
    return groups
  }

  private func folderCard(_ group: FolderGroup, inventory: OrganizationInventory, validating: Bool) -> some View {
    let eligible = group.proposals.filter { problems[$0.id] == nil }.map(\.id)
    let chosen = eligible.filter { selected.contains($0) }.count
    let state: CheckboxMark.Kind = chosen == 0 ? .off : (chosen == eligible.count ? .on : .mixed)
    let locked = busy || validating || eligible.isEmpty
    return VStack(spacing: 0) {
      HStack(spacing: 11) {
        Button {
          if chosen == eligible.count { selected.subtract(eligible) } else { selected.formUnion(eligible) }
        } label: {
          CheckboxMark(state: state)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .opacity(locked ? 0.4 : 1)
        .accessibilityLabel("Select every file for \(group.title)")
        .accessibilityValue(state == .on ? "Checked" : state == .mixed ? "Mixed" : "Unchecked")

        SwatchBadge(symbol: "folder", swatch: .teal, size: 28)
        VStack(alignment: .leading, spacing: 1) {
          Text(group.title)
            .font(.system(size: 13.5, weight: .bold)).tracking(-0.2)
            .foregroundStyle(AppTheme.ink)
            .lineLimit(1)
          Text("\(group.proposals.count) files · \(chosen) selected")
            .font(.system(size: 11.5)).monospacedDigit()
            .foregroundStyle(AppTheme.ink3)
        }
        .accessibilityElement(children: .combine)
        Spacer(minLength: 8)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 11)
      ForEach(group.proposals) { proposal in
        Rectangle().fill(AppTheme.divider).frame(height: 1)
        proposalRow(proposal, inventory: inventory, validating: validating)
      }
    }
    .cardBackground()
  }

  private func proposalRow(_ proposal: OrganizationProposal, inventory: OrganizationInventory, validating: Bool) -> some View {
    let locked = busy || validating || problems[proposal.id] != nil
    return VStack(alignment: .leading, spacing: 8) {
      Toggle(isOn: Binding(get: { selected.contains(proposal.id) }, set: { if $0 { selected.insert(proposal.id) } else { selected.remove(proposal.id) } })) {
        Text(inventory.files.first { $0.id == proposal.fileID }?.name ?? "Unknown file")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(AppTheme.ink)
          .lineLimit(1)
      }
      .toggleStyle(MintCheckboxStyle())
      .disabled(locked)
      .opacity(locked ? 0.55 : 1)
      HStack(spacing: 8) {
        Image(systemName: "arrow.turn.down.right").foregroundStyle(AppTheme.ink3)
        Picker("Destination", selection: Binding(get: { proposal.folderID }, set: { replace(proposal, folder: $0) })) {
          ForEach(inventory.folders) { Text($0.name).tag($0.id) }
        }
        .labelsHidden()
        .frame(maxWidth: 240)
        TextField("Proposed name", text: Binding(get: { proposal.name }, set: { replace(proposal, name: $0) }))
          .textFieldStyle(.roundedBorder)
      }
      .disabled(busy)
      .padding(.leading, 24)
      Text(proposal.reason)
        .font(.system(size: 11.5))
        .foregroundStyle(AppTheme.ink2)
        .lineLimit(3)
        .padding(.leading, 24)
      if let problem = problems[proposal.id] {
        Label(problem, systemImage: "info.circle")
          .font(.system(size: 11.5))
          .foregroundStyle(AppTheme.warning)
          .padding(.leading, 24)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var historyContent: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 14) {
        if records.isEmpty {
          Text("No organization changes recorded yet.")
            .font(.system(size: 13))
            .foregroundStyle(AppTheme.ink2)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 40)
        }
        ForEach(records) { record in
          SurfaceCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
              HStack(spacing: 10) {
                SwatchBadge(symbol: "folder", swatch: .teal, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                  Text(record.inventory.root.lastPathComponent)
                    .font(.system(size: 14, weight: .bold)).tracking(-0.2)
                    .foregroundStyle(AppTheme.ink)
                  Text(record.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11.5)).monospacedDigit()
                    .foregroundStyle(AppTheme.ink3)
                }
                Spacer(minLength: 8)
                Button("Undo available changes") { undo(record) }
                  .buttonStyle(MintButtonStyle(.secondary))
                  .controlSize(.small)
                  .disabled(busy || model.isWorking || model.isScanning || !record.items.contains { $0.state == .moved })
              }
              ForEach(record.items) { item in
                let original = record.inventory.files.first { $0.id == item.id }?.name ?? "Unknown file"
                let folder = record.inventory.folders.first { $0.id == item.proposal.folderID }
                let destination = (folder?.id == "root" ? "" : (folder?.name ?? "Unknown folder") + "/") + item.proposal.name
                VStack(alignment: .leading, spacing: 2) {
                  Text("\(original) → \(destination)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(AppTheme.ink)
                    .textSelection(.enabled)
                  Text("\(stateLabel(item))\(item.message.map { " · " + $0 } ?? "")")
                    .font(.system(size: 11.5))
                    .foregroundStyle(item.message == nil ? AppTheme.ink3 : AppTheme.warning)
                }
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(AppTheme.divider).frame(height: 1) }
              }
            }
          }
        }
      }.padding(20)
    }
  }

  private func stateLabel(_ item: OrganizationRecord.Item) -> String {
    switch item.state {
    case .prepared, .failed: return "Not applied"
    case .moving, .undoing, .uncertain: return "Needs verification"
    case .moved: return item.message == nil ? "Undo available" : "Undo needs attention"
    case .undone: return "Undone"
    }
  }

  private var consentView: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Review the names sent to AI").font(.title2.bold())
      Text("This request sends the file and destination-folder names shown below to MacMint's service and Anthropic. Names may reveal personal information. It sends no file contents or full paths. AI proposes changes; you still review and approve them here.").font(.callout)
      ScrollView { Text(consentText).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        .padding(12).background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 10))
      HStack {
        Button("Cancel", role: .cancel) { consentSheet = false; consentPayload = nil }
        Spacer()
        Button("Send these names") { requestSuggestions() }.buttonStyle(MintButtonStyle())
      }
    }.padding(24).frame(width: 650, height: 520).background(AppTheme.canvas)
  }

  private func chooseFolder() {
    guard !busy, model.exclusionsReady, let root = model.chooseFolder(prompt: "Choose one folder to organize") else { return }
    cancelRequest(); selected = []; proposals = []; inventory = nil; error = nil; localBusy = true
    Task {
      defer { localBusy = false }
      do { inventory = try await model.organizationStore.inspect(root, ignoredPaths: model.ignoredPaths) }
      catch { self.error = error.localizedDescription }
    }
  }
  private func replace(_ proposal: OrganizationProposal, folder: String? = nil, name: String? = nil) {
    guard let index = proposals.firstIndex(where: { $0.id == proposal.id }) else { return }
    selected.remove(proposal.id)
    proposals[index] = .init(fileID: proposal.fileID, folderID: folder ?? proposal.folderID, name: name ?? proposal.name, reason: proposal.reason)
  }
  private func validate() async {
    let input = validationInput
    guard let inventory, !input.proposals.isEmpty else {
      problems = [:]; validatedInput = input
      return
    }
    // Coalesce typing before touching the filesystem. Cancellation and the full
    // input key prevent older checks from enabling review after an edit/exclusion.
    do { try await Task.sleep(for: .milliseconds(200)) }
    catch { return }
    var issues: [String: String] = [:]
    for proposal in input.proposals {
      if Task.isCancelled { return }
      if let problem = await model.organizationStore.problem(proposal, in: inventory, ignoredPaths: input.ignoredPaths) { issues[proposal.id] = problem }
    }
    guard !Task.isCancelled, input == validationInput else { return }
    problems = issues; selected.subtract(issues.keys); validatedInput = input
  }
  private func prepareAI(_ inventory: OrganizationInventory) {
    guard account.isUnlocked else { showingActivation = true; return }
    let payload = AIOrganizationRequest(inventory)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    consentText = (try? encoder.encode(payload)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    consentPayload = payload; consentSheet = true
  }
  private func requestSuggestions() {
    guard let payload = consentPayload, !busy else { return }
    consentSheet = false; consentPayload = nil; error = nil
    suggestions.start {
      let response = try await account.aiOrganize(payload)
      let known = Set(payload.files.map(\.id)); var seen: Set<String> = []
      return response.proposals.filter { known.contains($0.id) && seen.insert($0.id).inserted }
    } receive: { proposals = $0; selected = [] }
      reportError: { error = $0 }
  }
  private func suggestLocally(_ inventory: OrganizationInventory) {
    guard !busy else { return }
    error = nil
    suggestions.start {
      await model.organizationStore.localSuggestions(inventory)
    } receive: { proposals = $0; selected = [] }
      reportError: { error = $0 }
  }
  private func cancelRequest() {
    suggestions.cancel(); consentPayload = nil; consentSheet = false
  }
  private func apply() {
    guard let inventory, !busy, !validationPending, !selected.isEmpty,
      !model.isWorking, !model.isScanning, model.exclusionsReady else { return }
    guard model.authorizeRemoval() else { showingActivation = true; return }
    let approved = proposals.filter { selected.contains($0.id) }
    localBusy = true; error = nil
    Task {
      defer { localBusy = false }
      do {
        _ = try await model.applyOrganization(inventory, proposals: approved)
        self.inventory = nil; proposals = []; selected = []; showHistory = true
      } catch { self.error = error.localizedDescription }
      await loadHistory()
    }
  }
  private func undo(_ record: OrganizationRecord) {
    guard !busy, !model.isWorking else { return }
    localBusy = true; error = nil
    Task {
      defer { localBusy = false }
      do { _ = try await model.undoOrganization(record.id) }
      catch { self.error = error.localizedDescription }
      await loadHistory()
    }
  }
  private func loadHistory() async {
    do {
      let report = try await model.organizationStore.historyReport()
      records = report.records
      if !report.warnings.isEmpty { self.error = report.warnings.joined(separator: " ") }
    }
    catch { self.error = "Organization records could not be read. They have been preserved. " + error.localizedDescription }
  }
}
