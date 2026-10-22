import MacCleanerCore
import SwiftUI

struct StorageExplorerView: View {
  @EnvironmentObject private var model: AppViewModel
  @State private var showOrganizer = false
  @State private var focused: String?
  /// The treemap is laid out once per folder and size, not on every hover or selection.
  @State private var layoutCache = TreemapLayoutCache()

  var body: some View {
    VStack(spacing: 0) {
      header
      if let node = model.storageCurrentNode, let scan = model.storageScan {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            summary(node, scan: scan)
            treemap(node)
            itemList(node)
            coverage(scan)
          }
          .frame(maxWidth: 1180, alignment: .leading)
          .padding(.horizontal, AppTheme.pagePadding)
          .padding(.top, 2)
          .padding(.bottom, 24)
          .frame(maxWidth: .infinity)
        }
      } else if model.isScanning && model.operationTitle == "Storage" {
        LoadingState(title: "Mapping \(model.storageRoot.lastPathComponent)…",
          detail: "Measuring every folder so you can see what takes up space. Nothing is opened or downloaded; cloud-only files stay in the cloud.",
          symbol: "chart.pie.fill", swatch: .indigo,
          status: "\(model.storageScannedCount.formatted()) items so far",
          cancel: { model.cancelCurrentOperation() })
      } else {
        // Walking a whole folder can take a minute and may ask for folder access, so it starts when you ask.
        EmptyState(
          icon: "chart.pie", title: "Map a folder to see what's inside",
          detail: "Map your home folder or a connected drive to see which folders take up the most room. It usually takes under a minute, and nothing is changed.",
          actionTitle: "Map Folder", action: { model.scanStorage() },
          secondaryTitle: "Choose Folder…", secondaryAction: { model.chooseStorageFolder() })
      }
    }
    .sheet(isPresented: $showOrganizer) { OrganizerView() }
  }

  // MARK: Header

  private var isHomeRoot: Bool {
    model.storageRoot.standardizedFileURL.path
      == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
  }

  private var header: some View {
    PageHeader(title: "Storage", subtitle: "See what takes up room, folder by folder. Select items for a closer look.") {
      HStack(spacing: 8) {
        Button { showOrganizer = true } label: { Label("Organize…", systemImage: "folder.badge.gearshape") }
          .buttonStyle(MintButtonStyle(.secondary))
        if !FileSystem.path(model.storageRoot, isInsideOrEqual: FileManager.default.homeDirectoryForCurrentUser) {
          StatusPill(title: "Inspection only", icon: "eye", tint: AppTheme.ink2)
        }
        if !model.selectedStoragePaths.isEmpty {
          Button("Deselect") { model.keepQueuedFiles(model.queuedStorageNodes.map(\.url)) }
            .buttonStyle(MintButtonStyle(.plain))
          Button {
            model.reviewStorageSelection()
          } label: {
            Label(
              "Review \(model.selectedStoragePaths.count) items",
              systemImage: "checklist")
          }
          .buttonStyle(MintButtonStyle())
          .disabled(model.isWorking || model.isScanning)
        }
        Menu {
          Button("Home Folder") {
            model.storageRoot = FileManager.default.homeDirectoryForCurrentUser
            model.scanStorage()
          }
          Button("Choose Folder or Drive…") { model.chooseStorageFolder() }
        } label: {
          Label(isHomeRoot ? "Home Folder" : model.storageRoot.lastPathComponent,
            systemImage: isHomeRoot ? "house" : "folder")
        }
        .fixedSize()
        .help("Location")
        Button {
          model.scanStorage()
        } label: {
          Label(model.storageScan == nil ? "Map Folder" : "Rescan", systemImage: "scope")
        }
        .buttonStyle(MintButtonStyle(.area))
        .disabled(model.isScanning || model.isWorking)
      }
    }
    .frame(maxWidth: 1180)
    .padding(.horizontal, AppTheme.pagePadding)
    .padding(.top, AppTheme.pageTopPadding)
    .padding(.bottom, 14)
    .frame(maxWidth: .infinity)
  }

  // MARK: Summary and breadcrumbs

  private func summary(_ node: StorageNode, scan: StorageScan) -> some View {
    HStack(spacing: 10) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          breadcrumbs
          Text(summaryDetail(node, scan: scan))
            .font(.system(size: 12.5))
            .monospacedDigit()
            .foregroundStyle(AppTheme.ink3)
            .lineLimit(1)
            .fixedSize()
        }
        .padding(.vertical, 2)
      }
      Text("Click a block to open it")
        .font(.system(size: 11.5))
        .foregroundStyle(AppTheme.ink3)
        .fixedSize()
    }
  }

  private func summaryDetail(_ node: StorageNode, scan: StorageScan) -> String {
    var parts = [ByteFormatter.string(node.allocatedBytes), "\(node.itemCount.formatted()) items"]
    if model.storageTrail.count <= 1 {
      parts.append("mapped in " + scan.duration.formatted(.number.precision(.fractionLength(1))) + " s")
    }
    return "· " + parts.joined(separator: " · ")
  }

  private var breadcrumbs: some View {
    HStack(spacing: 4) {
      ForEach(Array(model.storageTrail.enumerated()), id: \.element.id) { index, node in
        if index > 0 {
          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(AppTheme.ink3)
        }
        let isLast = index == model.storageTrail.count - 1
        Button {
          model.storagePath = index == 0 ? nil : node.id
        } label: {
          HStack(spacing: 5) {
            if index == 0 {
              Image(systemName: isHomeRoot ? "house.fill" : "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.Swatch.indigo.text)
            }
            Text(node.name)
              .font(.system(size: 12.5, weight: isLast ? .semibold : .regular))
              .foregroundStyle(isLast ? AppTheme.ink : AppTheme.ink2)
              .lineLimit(1)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLast)
        .help(isLast ? node.name : "Go back to \(node.name)")
      }
    }
  }

  // MARK: Treemap

  private func treemap(_ node: StorageNode) -> some View {
    GeometryReader { geometry in
      let blocks = layoutCache.blocks(for: node, size: geometry.size)
      let children = childIndex(node)
      ZStack(alignment: .topLeading) {
        if blocks.isEmpty {
          Text("Nothing here uses local space.")
            .font(.system(size: 13))
            .foregroundStyle(AppTheme.ink2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        ForEach(blocks) { block in
          if let child = children[block.id] {
            tile(child, rect: block.rect, total: node.allocatedBytes)
          } else if block.restCount > 0 {
            restTile(block)
          }
        }
      }
    }
    .frame(height: 300)
    .padding(4)
    .cardBackground(radius: 18)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Storage map of \(node.name)")
  }

  private func childIndex(_ node: StorageNode) -> [String: StorageNode] {
    var index: [String: StorageNode] = [:]
    for child in node.children where index[child.id] == nil { index[child.id] = child }
    return index
  }

  private func tile(_ node: StorageNode, rect: Treemap.Rect, total: Int64) -> some View {
    let isSelected = model.selectedStoragePaths.contains(node.id)
    let width = max(0, CGFloat(rect.width) - 4)
    let height = max(0, CGFloat(rect.height) - 4)
    return tileFace(node, width: width, height: height, total: total, isSelected: isSelected)
      .modifier(StorageTileHover())
      .contentShape(Rectangle())
      .onTapGesture(count: 2) { model.openStorageNode(node) }
      .onTapGesture {
        focused = node.id
        if opensFolder(node) { model.openStorageNode(node) }
      }
      .help("\(tileLabel(node))\(node.kind == .folder ? " • click to open" : "")")
      .contextMenu { contextMenu(for: node) }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(tileLabel(node))
      .accessibilityValue(isSelected ? "Selected for review" : "")
      .accessibilityHint(opensFolder(node) ? "Opens this folder" : "")
      .accessibilityAddTraits(.isButton)
      .accessibilityAction { model.openStorageNode(node) }
      .accessibilityAction(named: isSelected ? "Remove from Review" : "Add to Review") {
        model.toggleStorageSelection(node)
      }
      .offset(x: CGFloat(rect.x) + 2, y: CGFloat(rect.y) + 2)
  }

  private func tileLabel(_ node: StorageNode) -> String {
    "\(node.name), \(ByteFormatter.string(node.allocatedBytes))"
  }

  private func opensFolder(_ node: StorageNode) -> Bool { model.canOpenStorageNode(node) }

  private func tileCorner(width: CGFloat, height: CGFloat) -> CGFloat {
    let side = min(width, height)
    if side > 90 { return 14 }
    if side > 28 { return 10 }
    return 3
  }

  private func tileFace(_ node: StorageNode, width: CGFloat, height: CGFloat, total: Int64, isSelected: Bool)
    -> some View
  {
    let swatch = StorageStyle.swatch(for: node)
    let shape = RoundedRectangle(cornerRadius: tileCorner(width: width, height: height), style: .continuous)
    return shape
      .fill(swatch.gradient)
      .overlay {
        if isSelected {
          shape.strokeBorder(Color.white, lineWidth: 3)
        }
      }
      .overlay(alignment: .topLeading) { tileCaption(node, width: width, height: height, total: total) }
      .overlay(alignment: .topTrailing) {
        if isSelected && width > 34 && height > 34 {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(8)
        }
      }
      .foregroundStyle(.white)
      .clipShape(shape)
      .frame(width: width, height: height)
  }

  private func sharePercent(_ bytes: Int64, of total: Int64) -> Int {
    guard total > 0 else { return 0 }
    return Int((Double(bytes) / Double(total) * 100).rounded())
  }

  @ViewBuilder
  private func tileCaption(_ node: StorageNode, width: CGFloat, height: CGFloat, total: Int64) -> some View {
    if width > 120 && height > 100 {
      VStack(alignment: .leading, spacing: 1) {
        Image(systemName: StorageStyle.icon(for: node))
          .font(.system(size: 20, weight: .semibold))
          .opacity(0.9)
        Spacer(minLength: 4)
        Text(node.name)
          .font(.system(size: 13.5, weight: .bold))
          .lineLimit(1)
        Text(ByteFormatter.string(node.allocatedBytes))
          .font(AppTheme.number(width > 200 ? 24 : 19))
          .tracking(-0.5)
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.7)
        Text("\(node.itemCount.formatted()) items · \(sharePercent(node.allocatedBytes, of: total))%")
          .font(.system(size: 11.5))
          .monospacedDigit()
          .opacity(0.85)
          .lineLimit(1)
      }
      .padding(14)
      .frame(width: width, height: height, alignment: .topLeading)
    } else if width > 64 && height > 40 {
      VStack(alignment: .leading, spacing: 0) {
        Spacer(minLength: 0)
        Text(node.name)
          .font(.system(size: 12, weight: .bold))
          .lineLimit(1)
        Text(ByteFormatter.string(node.allocatedBytes))
          .font(AppTheme.number(13))
          .monospacedDigit()
          .lineLimit(1)
      }
      .padding(9)
      .frame(width: width, height: height, alignment: .bottomLeading)
    }
  }

  /// Everything too small to draw on its own, so the blocks keep their true proportions.
  private func restTile(_ block: TreemapLayoutCache.Block) -> some View {
    let width = max(0, CGFloat(block.rect.width) - 4)
    let height = max(0, CGFloat(block.rect.height) - 4)
    let shape = RoundedRectangle(cornerRadius: tileCorner(width: width, height: height), style: .continuous)
    let label = "\(block.restCount.formatted()) more · \(ByteFormatter.string(block.restBytes))"
    return shape
      .fill(AppTheme.panel2)
      .overlay(alignment: .bottomLeading) {
        if width > 70 && height > 32 {
          Text(label)
            .font(.system(size: 11.5, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(AppTheme.ink2)
            .lineLimit(1)
            .padding(9)
        }
      }
      .frame(width: width, height: height)
      .help(label + " in the list below")
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(block.restCount) smaller items, \(ByteFormatter.string(block.restBytes)), listed below")
      .offset(x: CGFloat(block.rect.x) + 2, y: CGFloat(block.rect.y) + 2)
  }

  // MARK: List

  private func itemList(_ node: StorageNode) -> some View {
    let total = max(node.allocatedBytes, 1)
    return VStack(spacing: 0) {
      HStack(spacing: 12) {
        Text("Name").frame(maxWidth: .infinity, alignment: .leading)
        Text("Share of \(node.name)").lineLimit(1).frame(width: 170, alignment: .leading)
        Text("Size").frame(width: 78, alignment: .trailing)
        Color.clear.frame(width: 52, height: 1)
      }
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(AppTheme.ink3)
      .padding(.leading, 44)
      .padding(.trailing, 16)
      .padding(.vertical, 8)
      .background(AppTheme.panel)
      .accessibilityHidden(true)
      LazyVStack(spacing: 0) {
        ForEach(node.children) { child in
          storageRow(child, total: total)
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: AppTheme.corner, style: .continuous))
    .cardBackground()
  }

  private func storageRow(_ child: StorageNode, total: Int64) -> some View {
    let swatch = StorageStyle.swatch(for: child)
    let share = min(1, max(0, Double(child.allocatedBytes) / Double(total)))
    return HStack(spacing: 12) {
      selectionControl(child)
      HStack(spacing: 10) {
        Image(systemName: StorageStyle.icon(for: child))
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 30, height: 30)
          .background(swatch.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(child.name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(AppTheme.ink)
            .lineLimit(1)
            .truncationMode(.middle)
          Text(rowDetail(child))
            .font(.system(size: 11))
            .foregroundStyle(AppTheme.ink3)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      shareBar(share, swatch: swatch)
      Text(ByteFormatter.string(child.allocatedBytes))
        .font(AppTheme.number(13, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(AppTheme.ink)
        .frame(width: 78, alignment: .trailing)
      rowActions(child)
    }
    .padding(.horizontal, 16)
    .frame(minHeight: 48)
    .background(focused == child.id ? AppTheme.selection : Color.clear)
    .modifier(StorageRowHover())
    .overlay(alignment: .top) { Rectangle().fill(AppTheme.divider).frame(height: 1) }
    .contentShape(Rectangle())
    .contextMenu { contextMenu(for: child) }
  }

  @ViewBuilder
  private func selectionControl(_ child: StorageNode) -> some View {
    if model.storageRemovalAllowed(child) {
      Toggle(
        isOn: Binding(
          get: { model.selectedStoragePaths.contains(child.id) },
          set: { _ in model.toggleStorageSelection(child) })
      ) { EmptyView() }
      .toggleStyle(MintCheckboxStyle())
      .accessibilityLabel("Select \(child.name)")
    } else {
      Color.clear.frame(width: 16, height: 16)
    }
  }

  private func rowDetail(_ child: StorageNode) -> String {
    if child.cloudOnlyCount > 0 || child.kind == .inaccessible || child.kind == .otherVolume {
      return StorageStyle.note(for: child)
    }
    switch child.kind {
    case .file: return "File"
    case .package: return "Package"
    default: return "\(child.itemCount.formatted()) item\(child.itemCount == 1 ? "" : "s")"
    }
  }

  private func shareBar(_ share: Double, swatch: AppTheme.Swatch) -> some View {
    HStack(spacing: 8) {
      GeometryReader { bar in
        Capsule().fill(AppTheme.track)
          .overlay(alignment: .leading) {
            Capsule().fill(swatch.gradient)
              .frame(width: max(share > 0 ? 3 : 0, bar.size.width * CGFloat(share)))
          }
      }
      .frame(height: 6)
      Text("\(Int((share * 100).rounded()))%")
        .font(AppTheme.number(11, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(AppTheme.ink3)
        .frame(width: 34, alignment: .leading)
    }
    .frame(width: 170)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Share")
    .accessibilityValue("\(Int((share * 100).rounded())) percent")
  }

  private func rowActions(_ child: StorageNode) -> some View {
    HStack(spacing: 2) {
      if model.storageRemovalAllowed(child) {
        Button {
          model.reveal(child.url)
        } label: {
          Image(systemName: "folder")
            .font(.system(size: 13))
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.ink3)
        .help("Reveal in Finder")
        .accessibilityLabel("Reveal \(child.name) in Finder")
      }
      if model.canOpenStorageNode(child) {
        Button {
          model.openStorageNode(child)
        } label: {
          Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .accessibilityLabel("Open folder")
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.ink2)
        .help("Open \(child.name)")
      }
    }
    .frame(width: 52, alignment: .trailing)
  }

  @ViewBuilder
  private func contextMenu(for node: StorageNode) -> some View {
    if model.canOpenStorageNode(node) {
      Button("Open") { model.openStorageNode(node) }
    }
    if model.storageRemovalAllowed(node) {
      Button("Reveal in Finder") { model.reveal(node.url) }
      Button(model.selectedStoragePaths.contains(node.id) ? "Remove from Review" : "Add to Review") {
        model.toggleStorageSelection(node)
      }
      ExplainMenuItem(target: model.aiTarget(for: node))
      Divider()
      Button("Exclude from Future Scans") { model.ignore(node.url) }
    }
  }

  // MARK: Coverage

  private func coverage(_ scan: StorageScan) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) { coveragePills(scan) }
        VStack(alignment: .leading, spacing: 6) { coveragePills(scan) }
      }
      Label(
        "Sizes are space on this disk. On APFS, copies can share space, so removing a file may free less than its size. Freed space appears after you empty the Trash.",
        systemImage: "info.circle"
      )
      .font(.system(size: 11.5))
      .foregroundStyle(AppTheme.ink3)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private func coveragePills(_ scan: StorageScan) -> some View {
    StatusPill(title: "\(scan.coverage.scannedItems.formatted()) items", icon: "doc.on.doc", tint: AppTheme.ink2)
    if !scan.coverage.inaccessiblePaths.isEmpty {
      StatusPill(title: "\(scan.coverage.inaccessiblePaths.count) unreadable", icon: "lock", tint: AppTheme.warning)
        .help("Grant Full Disk Access in System Settings to include protected folders.")
    }
    if scan.coverage.cloudOnlyItems > 0 {
      StatusPill(
        title: "\(scan.coverage.cloudOnlyItems.formatted()) cloud-only (not downloaded)", icon: "icloud",
        tint: AppTheme.ink2)
    }
    if !scan.coverage.otherVolumes.isEmpty {
      StatusPill(
        title: "\(scan.coverage.otherVolumes.count) other drive(s) skipped", icon: "externaldrive",
        tint: AppTheme.ink2)
    }
    if scan.coverage.wasCancelled {
      StatusPill(title: "Partial — scan was stopped", icon: "exclamationmark.triangle", tint: AppTheme.warning)
    }
  }
}

/// Lays the treemap out once per folder and size. Hovering, selecting or focusing a block
/// redraws the page without measuring the blocks again.
final class TreemapLayoutCache {
  struct Block: Identifiable {
    let id: String
    let rect: Treemap.Rect
    /// For the block that stands for everything too small to draw.
    var restCount = 0
    var restBytes: Int64 = 0
  }

  private struct Key: Equatable {
    let id: String
    let bytes: Int64
    let count: Int
    let width: Int
    let height: Int
  }

  /// Blocks beyond this are drawn as one "more" block; they stay in the list below.
  static let maxBlocks = 48
  static let restID = "\u{0}rest"

  private var key: Key?
  private var cached: [Block] = []

  func blocks(for node: StorageNode, size: CGSize) -> [Block] {
    let key = Key(
      id: node.id, bytes: node.allocatedBytes, count: node.children.count,
      width: Int(size.width.rounded()), height: Int(size.height.rounded()))
    if key == self.key { return cached }
    self.key = key
    cached = Self.layout(node, size: size)
    return cached
  }

  private static func layout(_ node: StorageNode, size: CGSize) -> [Block] {
    guard size.width > 0, size.height > 0 else { return [] }
    let sorted = node.children.filter { $0.allocatedBytes > 0 }.sorted { $0.allocatedBytes > $1.allocatedBytes }
    let shown = Array(sorted.prefix(maxBlocks))
    let hidden = sorted.dropFirst(maxBlocks)
    let restBytes = hidden.reduce(Int64(0)) { $0 + $1.allocatedBytes }

    var entries: [(id: String, value: Double)] = shown.map { (id: $0.id, value: Double($0.allocatedBytes)) }
    if restBytes > 0 { entries.append((id: Self.restID, value: Double(restBytes))) }
    // The squarified layout expects the largest first.
    entries.sort { $0.value > $1.value }

    let bounds = Treemap.Rect(x: 0, y: 0, width: Double(size.width), height: Double(size.height))
    let rects = Treemap.layout(entries.map(\.value), in: bounds)
    var blocks: [Block] = []
    blocks.reserveCapacity(rects.count)
    for (index, rect) in rects.enumerated() where index < entries.count {
      let id = entries[index].id
      if id == restID {
        blocks.append(Block(id: id, rect: rect, restCount: hidden.count, restBytes: restBytes))
      } else {
        blocks.append(Block(id: id, rect: rect))
      }
    }
    return blocks
  }
}

/// A treemap block brightens a little under the pointer. No animation.
private struct StorageTileHover: ViewModifier {
  @State private var hovering = false
  func body(content: Content) -> some View {
    content.brightness(hovering ? 0.06 : 0).onHover { hovering = $0 }
  }
}

/// List rows show the panel color under the pointer.
private struct StorageRowHover: ViewModifier {
  @State private var hovering = false
  func body(content: Content) -> some View {
    content.background(hovering ? AppTheme.panel : Color.clear).onHover { hovering = $0 }
  }
}

enum StorageStyle {
  private static let video: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "webm", "mpg", "mts"]
  private static let audio: Set<String> = ["mp3", "m4a", "wav", "aiff", "aif", "flac", "aac", "logicx"]
  private static let images: Set<String> = ["jpg", "jpeg", "png", "heic", "raw", "cr2", "nef", "arw", "dng", "tiff", "psd", "gif"]
  private static let archives: Set<String> = ["zip", "dmg", "pkg", "iso", "xip", "tar", "gz", "rar", "7z", "ipa"]
  private static let models: Set<String> = ["gguf", "safetensors", "bin", "pt", "ckpt", "onnx", "mlmodel"]

  /// Other folders get a steady color from their name, so a folder keeps its color between visits.
  private static let folderSwatches: [AppTheme.Swatch] = [.indigo, .sky, .teal, .violet, .iris, .mint, .orange, .pink]

  static func swatch(for node: StorageNode) -> AppTheme.Swatch {
    switch node.kind {
    case .folder: return folderSwatch(node.name)
    case .package: return .sky
    case .aggregate: return .graphite
    case .inaccessible: return .rose
    case .otherVolume: return .slate
    case .file: return fileSwatch(node.url)
    }
  }

  static func color(for node: StorageNode) -> Color { swatch(for: node).color }

  /// The color of a file by its type: video pink, audio orange, images violet, archives amber,
  /// models teal, anything else slate.
  static func fileSwatch(_ url: URL) -> AppTheme.Swatch {
    let ext = url.pathExtension.lowercased()
    if video.contains(ext) { return .pink }
    if audio.contains(ext) { return .orange }
    if images.contains(ext) { return .violet }
    if archives.contains(ext) { return .amber }
    if models.contains(ext) { return .teal }
    return .slate
  }

  static func fileSymbol(_ url: URL) -> String {
    let ext = url.pathExtension.lowercased()
    if video.contains(ext) { return "film.fill" }
    if audio.contains(ext) { return "music.note" }
    if images.contains(ext) { return "photo.fill" }
    if archives.contains(ext) { return "archivebox.fill" }
    if models.contains(ext) { return "cpu.fill" }
    return "doc.fill"
  }

  private static func folderSwatch(_ name: String) -> AppTheme.Swatch {
    switch name.lowercased() {
    case "movies": return .pink
    case "music": return .orange
    case "pictures", "photos": return .violet
    case "downloads": return .teal
    case "documents": return .sky
    case "desktop": return .iris
    case "library": return .slate
    default:
      let sum = name.unicodeScalars.reduce(UInt32(0)) { $0 &+ $1.value }
      return folderSwatches[Int(sum % UInt32(folderSwatches.count))]
    }
  }

  private static func folderSymbol(_ name: String) -> String {
    switch name.lowercased() {
    case "movies": return "film.fill"
    case "music": return "music.note"
    case "pictures", "photos": return "photo.fill"
    case "downloads": return "arrow.down.circle.fill"
    case "documents": return "doc.text.fill"
    case "desktop": return "desktopcomputer"
    case "library": return "books.vertical.fill"
    case "developer", "projects", "code", "src": return "chevron.left.forwardslash.chevron.right"
    default: return "folder.fill"
    }
  }

  static func icon(for node: StorageNode) -> String {
    switch node.kind {
    case .folder: return folderSymbol(node.name)
    case .package: return "shippingbox.fill"
    case .aggregate: return "square.stack.3d.down.right"
    case .inaccessible: return "lock.fill"
    case .otherVolume: return "externaldrive.fill"
    case .file: return fileSymbol(node.url)
    }
  }

  static func note(for node: StorageNode) -> String {
    switch node.kind {
    case .inaccessible: return "Couldn't be read — size not included"
    case .otherVolume: return "Another drive — not scanned"
    default:
      return "\(node.cloudOnlyCount.formatted()) cloud-only item\(node.cloudOnlyCount == 1 ? "" : "s") (\(ByteFormatter.string(node.logicalBytes)) in the cloud)"
    }
  }
}
