import MacCleanerCore
import SwiftUI

struct StorageExplorerView: View {
  @EnvironmentObject private var model: AppViewModel
  @State private var hovered: String?
  @State private var focused: String?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if let node = model.storageCurrentNode, let scan = model.storageScan {
        breadcrumbs
        Divider()
        HSplitView {
          treemap(node)
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            .padding(14)
          itemList(node)
            .frame(minWidth: 340, idealWidth: 400, maxWidth: 520)
        }
        Divider()
        coverageBar(scan)
      } else if model.isScanning && model.operationTitle == "Storage" {
        VStack(spacing: 12) {
          ProgressView().controlSize(.large)
          Text("Mapping \(model.storageRoot.lastPathComponent)…").font(.headline)
          Text("\(model.storageScannedCount.formatted()) items so far")
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
          Text("Nothing is opened or downloaded — cloud-only files stay in the cloud.")
            .font(.caption)
            .foregroundStyle(.tertiary)
          Button("Cancel") { model.cancelCurrentOperation() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        EmptyState(
          icon: "chart.pie", title: "See what's using your space",
          detail: "Map your home folder or any drive. Click a block to dive in; select items to review them.")
      }
    }
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Storage").font(.system(size: 30, weight: .bold, design: .rounded))
        Text("A size map of \(model.storageRoot.path). Nothing changes until you review it.")
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer()
      if !model.selectedStoragePaths.isEmpty {
        Button("Deselect") { model.selectedStoragePaths = [] }
        Button {
          model.reviewStorageSelection()
        } label: {
          Label(
            "Review \(model.selectedStoragePaths.count) Selected (\(ByteFormatter.string(model.queuedStorageNodes.reduce(0) { $0 + $1.allocatedBytes })))",
            systemImage: "trash")
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isWorking || model.isScanning)
      }
      Menu {
        Button("Home Folder") {
          model.storageRoot = FileManager.default.homeDirectoryForCurrentUser
          model.scanStorage()
        }
        Button("Choose Folder or Drive…") { model.chooseStorageFolder() }
      } label: {
        Label("Location", systemImage: "folder")
      }
      .fixedSize()
      Button(model.storageScan == nil ? "Scan" : "Rescan") { model.scanStorage() }
        .buttonStyle(.borderedProminent)
        .disabled(model.isScanning || model.isWorking)
    }
    .padding(AppTheme.pagePadding)
  }

  private var breadcrumbs: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 4) {
        ForEach(Array(model.storageTrail.enumerated()), id: \.element.id) { index, node in
          if index > 0 {
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
          }
          Button {
            model.storagePath = index == 0 ? nil : node.id
          } label: {
            HStack(spacing: 4) {
              Text(node.name).fontWeight(index == model.storageTrail.count - 1 ? .semibold : .regular)
              Text(ByteFormatter.string(node.allocatedBytes)).foregroundStyle(.secondary)
            }
            .font(.callout)
          }
          .buttonStyle(.plain)
          .disabled(index == model.storageTrail.count - 1)
        }
      }
      .padding(.horizontal, AppTheme.pagePadding)
      .padding(.vertical, 9)
    }
    .background(.bar)
  }

  // MARK: Treemap

  private func treemap(_ node: StorageNode) -> some View {
    GeometryReader { geometry in
      let tiles = Array(node.children.filter { $0.allocatedBytes > 0 }.prefix(160))
      let rects = Treemap.layout(
        tiles.map { Double($0.allocatedBytes) },
        in: .init(x: 0, y: 0, width: geometry.size.width, height: geometry.size.height))
      ZStack(alignment: .topLeading) {
        if tiles.isEmpty {
          Text("Nothing here uses local space.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        ForEach(Array(zip(tiles, rects)), id: \.0.id) { child, rect in
          tile(child, rect: rect)
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Storage map of \(node.name)")
  }

  private func tile(_ node: StorageNode, rect: Treemap.Rect) -> some View {
    let isSelected = model.selectedStoragePaths.contains(node.id)
    let isHovered = hovered == node.id || focused == node.id
    return tileInteractions(
      tileFace(node, rect: rect, isSelected: isSelected, isHovered: isHovered), node: node,
      isHovered: isHovered
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(tileLabel(node))
    .accessibilityValue(isSelected ? "Selected for review" : "")
    .accessibilityHint(opensFolder(node) ? "Opens this folder" : "")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { model.openStorageNode(node) }
    .accessibilityAction(named: isSelected ? "Remove from Review" : "Add to Review") {
      model.toggleStorageSelection(node)
    }
  }

  private func tileLabel(_ node: StorageNode) -> String {
    "\(node.name), \(ByteFormatter.string(node.allocatedBytes))"
  }

  private func opensFolder(_ node: StorageNode) -> Bool {
    node.kind == .folder && !node.children.isEmpty
  }

  private func tileFace(_ node: StorageNode, rect: Treemap.Rect, isSelected: Bool, isHovered: Bool)
    -> some View
  {
    let color = StorageStyle.color(for: node)
    let gradient = LinearGradient(
      colors: [color.opacity(isHovered ? 1 : 0.88), color.opacity(isHovered ? 0.85 : 0.68)],
      startPoint: .topLeading, endPoint: .bottomTrailing)
    let corner: CGFloat = rect.width > 24 && rect.height > 24 ? 6 : 2
    let border: Color = isSelected ? .white : Color.black.opacity(0.08)
    return RoundedRectangle(cornerRadius: corner, style: .continuous)
      .fill(gradient)
      .overlay {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .strokeBorder(border, lineWidth: isSelected ? 3 : 1)
      }
      .overlay(alignment: .topLeading) { tileCaption(node, rect: rect) }
      .frame(width: max(0, rect.width - 2), height: max(0, rect.height - 2))
      .offset(x: rect.x + 1, y: rect.y + 1)
  }

  @ViewBuilder
  private func tileCaption(_ node: StorageNode, rect: Treemap.Rect) -> some View {
    if rect.width > 70 && rect.height > 34 {
      VStack(alignment: .leading, spacing: 1) {
        Text(node.name).font(.caption.weight(.semibold)).lineLimit(1)
        Text(ByteFormatter.string(node.allocatedBytes)).font(.caption2).opacity(0.85)
      }
      .foregroundStyle(.white)
      .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
      .padding(6)
    }
  }

  private func tileInteractions<Face: View>(_ face: Face, node: StorageNode, isHovered: Bool)
    -> some View
  {
    let help = "\(tileLabel(node))\(node.kind == .folder ? " • click to open" : "")"
    return face
      .contentShape(Rectangle())
      .onHover { inside in hovered = inside ? node.id : (hovered == node.id ? nil : hovered) }
      .onTapGesture(count: 2) { model.openStorageNode(node) }
      .onTapGesture {
        focused = node.id
        if opensFolder(node) { model.openStorageNode(node) }
      }
      .help(help)
      .contextMenu { contextMenu(for: node) }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
  }

  // MARK: List

  private func itemList(_ node: StorageNode) -> some View {
    let total = max(node.allocatedBytes, 1)
    return List(node.children) { child in
      HStack(spacing: 10) {
        if child.isActionable {
          Toggle(
            "",
            isOn: Binding(
              get: { model.selectedStoragePaths.contains(child.id) },
              set: { _ in model.toggleStorageSelection(child) })
          )
          .labelsHidden()
          .accessibilityLabel("Select \(child.name)")
        } else {
          Color.clear.frame(width: 20)
        }
        Image(systemName: StorageStyle.icon(for: child))
          .foregroundStyle(StorageStyle.color(for: child))
          .frame(width: 18)
        VStack(alignment: .leading, spacing: 3) {
          Text(child.name).lineLimit(1).truncationMode(.middle)
          GeometryReader { bar in
            Capsule().fill(Color.primary.opacity(0.07))
              .overlay(alignment: .leading) {
                Capsule().fill(StorageStyle.color(for: child))
                  .frame(width: bar.size.width * CGFloat(Double(child.allocatedBytes) / Double(total)))
              }
          }
          .frame(height: 4)
          if child.cloudOnlyCount > 0 || child.kind == .inaccessible || child.kind == .otherVolume {
            Text(StorageStyle.note(for: child)).font(.caption2).foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 6)
        Text(ByteFormatter.string(child.allocatedBytes))
          .font(.callout.monospacedDigit())
          .frame(width: 78, alignment: .trailing)
        if child.kind == .folder && !child.children.isEmpty {
          Button {
            model.openStorageNode(child)
          } label: {
            Image(systemName: "chevron.right.circle")
              .accessibilityLabel("Open folder")
          }
          .buttonStyle(.borderless)
          .help("Open \(child.name)")
        }
      }
      .padding(.vertical, 2)
      .listRowBackground(focused == child.id ? AppTheme.accent.opacity(0.12) : Color.clear)
      .contextMenu { contextMenu(for: child) }
      .onHover { inside in hovered = inside ? child.id : (hovered == child.id ? nil : hovered) }
    }
    .listStyle(.inset)
  }

  @ViewBuilder
  private func contextMenu(for node: StorageNode) -> some View {
    if node.kind == .folder && !node.children.isEmpty {
      Button("Open") { model.openStorageNode(node) }
    }
    if node.isActionable {
      Button("Reveal in Finder") { model.reveal(node.url) }
      Button(model.selectedStoragePaths.contains(node.id) ? "Remove from Review" : "Add to Review") {
        model.toggleStorageSelection(node)
      }
      Divider()
      Button("Exclude from Future Scans") { model.ignore(node.url) }
    }
  }

  // MARK: Coverage

  private func coverageBar(_ scan: StorageScan) -> some View {
    HStack(spacing: 14) {
      Label("\(scan.coverage.scannedItems.formatted()) items", systemImage: "doc.on.doc")
      if !scan.coverage.inaccessiblePaths.isEmpty {
        Label("\(scan.coverage.inaccessiblePaths.count) unreadable", systemImage: "lock")
          .foregroundStyle(.orange)
          .help("Grant Full Disk Access in System Settings to include protected folders.")
      }
      if scan.coverage.cloudOnlyItems > 0 {
        Label("\(scan.coverage.cloudOnlyItems.formatted()) cloud-only (not downloaded)", systemImage: "icloud")
      }
      if !scan.coverage.otherVolumes.isEmpty {
        Label("\(scan.coverage.otherVolumes.count) other drive(s) skipped", systemImage: "externaldrive")
      }
      if scan.coverage.wasCancelled {
        Label("Partial — scan was stopped", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
      }
      Spacer()
      Text("Sizes show space used on this disk; freed space appears after emptying the Trash.")
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, AppTheme.pagePadding)
    .padding(.vertical, 8)
  }
}

enum StorageStyle {
  private static let video: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "webm", "mpg", "mts"]
  private static let audio: Set<String> = ["mp3", "m4a", "wav", "aiff", "aif", "flac", "aac", "logicx"]
  private static let images: Set<String> = ["jpg", "jpeg", "png", "heic", "raw", "cr2", "nef", "arw", "dng", "tiff", "psd", "gif"]
  private static let archives: Set<String> = ["zip", "dmg", "pkg", "iso", "xip", "tar", "gz", "rar", "7z", "ipa"]
  private static let models: Set<String> = ["gguf", "safetensors", "bin", "pt", "ckpt", "onnx", "mlmodel"]

  static func color(for node: StorageNode) -> Color {
    switch node.kind {
    case .folder: return AppTheme.accent
    case .package: return Color(red: 0.25, green: 0.47, blue: 0.95)
    case .aggregate: return Color.gray
    case .inaccessible: return Color.red.opacity(0.7)
    case .otherVolume: return Color.gray.opacity(0.6)
    case .file:
      let ext = node.url.pathExtension.lowercased()
      if video.contains(ext) { return Color(red: 0.55, green: 0.33, blue: 0.92) }
      if audio.contains(ext) { return Color(red: 0.93, green: 0.33, blue: 0.56) }
      if images.contains(ext) { return Color(red: 0.97, green: 0.55, blue: 0.18) }
      if archives.contains(ext) { return Color(red: 0.62, green: 0.45, blue: 0.30) }
      if models.contains(ext) { return Color(red: 0.10, green: 0.62, blue: 0.75) }
      return Color(red: 0.42, green: 0.48, blue: 0.56)
    }
  }

  static func icon(for node: StorageNode) -> String {
    switch node.kind {
    case .folder: return "folder.fill"
    case .package: return "shippingbox.fill"
    case .aggregate: return "square.stack.3d.down.right"
    case .inaccessible: return "lock.fill"
    case .otherVolume: return "externaldrive.fill"
    case .file:
      let ext = node.url.pathExtension.lowercased()
      if video.contains(ext) { return "film.fill" }
      if audio.contains(ext) { return "music.note" }
      if images.contains(ext) { return "photo.fill" }
      if archives.contains(ext) { return "archivebox.fill" }
      if models.contains(ext) { return "cpu.fill" }
      return "doc.fill"
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
