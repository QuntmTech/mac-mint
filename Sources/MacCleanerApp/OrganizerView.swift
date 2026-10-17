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
    VStack(spacing: 0) {
      PageHeader(title: showHistory || historyOnly ? "Organization history" : "A place for every file",
        subtitle: "Preview names and moves. You choose what changes; existing files are never overwritten.") {
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }.padding(22)
      Divider()
      if let error {
        Label(error, systemImage: "exclamationmark.triangle").font(.callout)
          .foregroundStyle(AppTheme.warning).textSelection(.enabled).padding(14)
        Button("Show organization records in Finder") { model.reveal(model.supportDirectory.appendingPathComponent("Organization")) }.padding(.bottom, 8)
      }
      if showHistory || historyOnly { historyContent }
      else if let inventory { proposalContent(inventory) }
      else {
        EmptyState(icon: "folder.badge.gearshape", title: "Start with one folder",
          detail: "Inspect up to 100 local documents and media files. Use existing subfolders, edit names, and review every change. App data, repositories, cloud-only files, and nested files are skipped.",
          actionTitle: "Choose folder…", action: chooseFolder)
      }
      Divider()
      HStack {
        if !historyOnly { Button(showHistory ? "Back to preview" : "History & Undo") { showHistory.toggle(); Task { await loadHistory() } } }
        if busy { ProgressView().controlSize(.small); Text("Working…").font(.caption) }
        else if validationPending {
          ProgressView().controlSize(.small)
          Text("Checking changes…").font(.caption).foregroundStyle(.secondary)
        }
        if suggestions.isBusy { Button("Cancel suggestions") { cancelRequest() } }
        Spacer()
        if inventory != nil && !showHistory && !historyOnly {
          Button("Choose another folder…", action: chooseFolder).disabled(busy)
          Button("Review \(selected.count) changes") { confirmation = true }
            .buttonStyle(MintButtonStyle()).disabled(busy || validationPending || selected.isEmpty || selected.contains { problems[$0] != nil } || model.isWorking || model.isScanning)
        }
      }.padding(16)
    }
    .background(AppTheme.canvas)
    .frame(minWidth: 700, idealWidth: 840, maxWidth: 960, minHeight: 520, idealHeight: 660)
    .task { await loadHistory(); if !SmokeTest.isRequested { await account.refreshAIStatus() } }
    .task(id: validationInput) { await validate() }
    .onChange(of: model.ignoredPaths) { _, _ in cancelRequest() }
    .onChange(of: model.aiEnabled) { _, enabled in if !enabled { cancelRequest() } }
    .onChange(of: account.isUnlocked) { _, unlocked in if !unlocked { cancelRequest() } }
    .onDisappear { cancelRequest() }
    .sheet(isPresented: $showingActivation) { AccountAccessSheet() }
    .sheet(isPresented: $consentSheet) { consentView }
    .alert("Apply \(selected.count) reviewed changes?", isPresented: $confirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Apply changes") { apply() }
    } message: { Text("Selected files will be renamed or moved within the chosen folder. Recovery records are written first. Use History & Undo to reverse changes when their files and locations are still available.") }
  }

  private func proposalContent(_ inventory: OrganizationInventory) -> some View {
    let validating = validationPending
    return VStack(alignment: .leading, spacing: 12) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Label(inventory.root.lastPathComponent, systemImage: "folder").font(.headline)
          Text("\(inventory.files.count) eligible files · \(inventory.omitted) skipped\(inventory.wasLimited ? " · inspection stopped at 500 entries" : "")")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Suggest by file type") {
          suggestLocally(inventory)
        }.disabled(busy)
        Button { prepareAI(inventory) } label: { Label("Suggest with AI…", systemImage: "sparkles") }
          .disabled(busy || inventory.files.isEmpty || !account.aiStatus.allows("organize"))
          .help(account.aiStatus.allows("organize") ? "Preview the names sent before requesting suggestions" : "AI organization is not enabled by the service. File-type suggestions and manual edits work locally.")
      }
      Text("AI uses names only in this version. Nothing is selected automatically. Select a row to approve its proposed change.")
        .font(.caption).foregroundStyle(.secondary)
      if proposals.isEmpty {
        Button("Prepare manual edits") {
          proposals = inventory.files.map { .init(fileID: $0.id, folderID: "root", name: $0.name, reason: "Your manual edit") }
        }.disabled(busy || inventory.files.isEmpty)
        Spacer()
        Text("File-type suggestions use existing folders named Documents, Photos, Videos, Audio, or Archives. You can also edit names and destinations yourself.")
          .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center)
        Spacer()
      } else {
        ScrollView {
          LazyVStack(spacing: 12) {
            ForEach(proposals) { proposal in proposalRow(proposal, inventory: inventory, validating: validating) }
          }.padding(.vertical, 4)
        }
      }
    }.padding(20)
  }

  private func proposalRow(_ proposal: OrganizationProposal, inventory: OrganizationInventory, validating: Bool) -> some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Toggle(isOn: Binding(get: { selected.contains(proposal.id) }, set: { if $0 { selected.insert(proposal.id) } else { selected.remove(proposal.id) } })) {
            Text(inventory.files.first { $0.id == proposal.fileID }?.name ?? "Unknown file").lineLimit(1)
          }.toggleStyle(.checkbox).disabled(busy || validating || problems[proposal.id] != nil)
          Spacer()
        }
        HStack {
          Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
          Picker("Destination", selection: Binding(get: { proposal.folderID }, set: { replace(proposal, folder: $0) })) {
            ForEach(inventory.folders) { Text($0.name).tag($0.id) }
          }.frame(maxWidth: 240)
          TextField("Proposed name", text: Binding(get: { proposal.name }, set: { replace(proposal, name: $0) }))
            .textFieldStyle(.roundedBorder)
        }.disabled(busy)
        Text(proposal.reason).font(.caption).foregroundStyle(.secondary).lineLimit(3)
        if let problem = problems[proposal.id] { Label(problem, systemImage: "info.circle").font(.caption).foregroundStyle(AppTheme.warning) }
      }
    }
  }

  private var historyContent: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 14) {
        if records.isEmpty { Text("No organization changes recorded yet.").foregroundStyle(.secondary) }
        ForEach(records) { record in
          SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Text(record.inventory.root.lastPathComponent).font(.headline)
                Text(record.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Undo available changes") { undo(record) }
                  .disabled(busy || model.isWorking || model.isScanning || !record.items.contains { $0.state == .moved })
              }
              ForEach(record.items) { item in
                let original = record.inventory.files.first { $0.id == item.id }?.name ?? "Unknown file"
                let folder = record.inventory.folders.first { $0.id == item.proposal.folderID }
                let destination = (folder?.id == "root" ? "" : (folder?.name ?? "Unknown folder") + "/") + item.proposal.name
                VStack(alignment: .leading, spacing: 3) {
                  Text("\(original) → \(destination)").font(.callout).textSelection(.enabled)
                  Text("\(stateLabel(item))\(item.message.map { " · " + $0 } ?? "")")
                    .font(.caption).foregroundStyle(item.message == nil ? .secondary : AppTheme.warning)
                }
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
