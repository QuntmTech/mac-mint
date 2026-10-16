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
  @State private var busy = false
  @State private var error: String?
  @State private var confirmation = false
  @State private var showHistory = false
  @State private var consentPayload: AIOrganizationRequest?
  @State private var consentText = ""
  @State private var consentSheet = false
  @State private var requestTask: Task<Void, Never>?
  @State private var generation = UUID()

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
        if requestTask != nil { Button("Cancel request") { cancelRequest() } }
        Spacer()
        if inventory != nil && !showHistory && !historyOnly {
          Button("Choose another folder…", action: chooseFolder).disabled(busy)
          Button("Review \(selected.count) changes") { confirmation = true }
            .buttonStyle(MintButtonStyle()).disabled(busy || selected.isEmpty || selected.contains { problems[$0] != nil } || model.isWorking || model.isScanning)
        }
      }.padding(16)
    }
    .background(AppTheme.canvas)
    .frame(minWidth: 700, idealWidth: 840, maxWidth: 960, minHeight: 520, idealHeight: 660)
    .task { await loadHistory(); if !SmokeTest.isRequested { await account.refreshAIStatus() } }
    .task(id: proposals) { await validate() }
    .onChange(of: model.ignoredPaths) { _, _ in Task { await validate() } }
    .onChange(of: model.aiEnabled) { _, enabled in if !enabled { cancelRequest() } }
    .onChange(of: account.isUnlocked) { _, unlocked in if !unlocked { cancelRequest() } }
    .onDisappear { cancelRequest() }
    .sheet(isPresented: $consentSheet) { consentView }
    .alert("Apply \(selected.count) reviewed changes?", isPresented: $confirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Apply changes") { apply() }
    } message: { Text("Selected files will be renamed or moved within the chosen folder. Recovery records are written first. Use History & Undo to reverse changes when their files and locations are still available.") }
  }

  private func proposalContent(_ inventory: OrganizationInventory) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Label(inventory.root.lastPathComponent, systemImage: "folder").font(.headline)
          Text("\(inventory.files.count) eligible files · \(inventory.omitted) skipped\(inventory.wasLimited ? " · inspection stopped at 500 entries" : "")")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Suggest by file type") {
          Task { proposals = await model.organizationStore.localSuggestions(inventory); selected = [] }
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
            ForEach(proposals) { proposal in proposalRow(proposal, inventory: inventory) }
          }.padding(.vertical, 4)
        }
      }
    }.padding(20)
  }

  private func proposalRow(_ proposal: OrganizationProposal, inventory: OrganizationInventory) -> some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Toggle(isOn: Binding(get: { selected.contains(proposal.id) }, set: { if $0 { selected.insert(proposal.id) } else { selected.remove(proposal.id) } })) {
            Text(inventory.files.first { $0.id == proposal.fileID }?.name ?? "Unknown file").lineLimit(1)
          }.toggleStyle(.checkbox).disabled(busy || problems[proposal.id] != nil)
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
                  .disabled(busy || model.isWorking || !record.items.contains { $0.state == .moved })
              }
              ForEach(record.items) { item in
                let original = record.inventory.files.first { $0.id == item.id }?.name ?? "Unknown file"
                VStack(alignment: .leading, spacing: 3) {
                  Text("\(original) → \(item.proposal.name)").font(.callout).textSelection(.enabled)
                  Text("\(item.state.rawValue.capitalized)\(item.message.map { " · " + $0 } ?? "")")
                    .font(.caption).foregroundStyle(item.message == nil ? .secondary : AppTheme.warning)
                }
              }
            }
          }
        }
      }.padding(20)
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
    cancelRequest(); selected = []; proposals = []; inventory = nil; error = nil; busy = true
    Task {
      defer { busy = false }
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
    guard let inventory else { return }
    var issues: [String: String] = [:]
    for proposal in proposals {
      if Task.isCancelled { return }
      if let problem = await model.organizationStore.problem(proposal, in: inventory, ignoredPaths: model.ignoredPaths) { issues[proposal.id] = problem }
    }
    guard !Task.isCancelled else { return }
    problems = issues; selected.subtract(issues.keys)
  }
  private func prepareAI(_ inventory: OrganizationInventory) {
    let payload = AIOrganizationRequest(inventory)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    consentText = (try? encoder.encode(payload)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    consentPayload = payload; consentSheet = true
  }
  private func requestSuggestions() {
    guard let payload = consentPayload else { return }
    consentSheet = false; consentPayload = nil; busy = true; error = nil
    let token = generation
    requestTask = Task {
      defer { if generation == token { busy = false; requestTask = nil } }
      do {
        let response = try await account.aiOrganize(payload)
        guard !Task.isCancelled, generation == token else { return }
        let known = Set(payload.files.map(\.id)); var seen: Set<String> = []
        proposals = response.proposals.filter { known.contains($0.id) && seen.insert($0.id).inserted }; selected = []
      } catch { if !Task.isCancelled, generation == token { self.error = error.localizedDescription } }
    }
  }
  private func cancelRequest() { generation = UUID(); requestTask?.cancel(); requestTask = nil; consentPayload = nil; consentSheet = false; busy = false }
  private func apply() {
    guard let inventory, !busy, !model.isWorking, !model.isScanning, model.exclusionsReady, model.requirePaidAccess() else { return }
    let approved = proposals.filter { selected.contains($0.id) }
    busy = true; model.isWorking = true; error = nil
    Task {
      defer { busy = false; model.isWorking = false }
      do {
        _ = try await model.organizationStore.apply(inventory, proposals: approved, ignoredPaths: model.ignoredPaths)
        self.inventory = nil; proposals = []; selected = []; showHistory = true
        // Files have changed; invalidate affected inventories rather than retain stale selections.
        model.photoScan = nil; model.selectedPhotoIDs = []; model.storageScan = nil
        model.largeFiles = []; model.selectedLargeFileIDs = []; model.duplicateGroups = []; model.selectedDuplicateIDs = []
        model.invalidateAIReview()
      } catch { self.error = error.localizedDescription }
      await loadHistory()
    }
  }
  private func undo(_ record: OrganizationRecord) {
    guard !busy, !model.isWorking else { return }
    busy = true; model.isWorking = true; error = nil
    Task {
      defer { busy = false; model.isWorking = false }
      do { _ = try await model.organizationStore.undo(recordID: record.id) }
      catch { self.error = error.localizedDescription }
      await loadHistory()
    }
  }
  private func loadHistory() async {
    do { records = try await model.organizationStore.history() }
    catch { self.error = "Organization records could not be read. They have been preserved. " + error.localizedDescription }
  }
}
