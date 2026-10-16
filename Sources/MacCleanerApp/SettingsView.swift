import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var model: AppViewModel
  @State private var confirmClear = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Settings").font(.system(size: 30, weight: .bold, design: .rounded))
          Text("Safety, exclusions, permissions, and local privacy controls.")
            .foregroundStyle(.secondary)
        }

        SurfaceCard {
          VStack(alignment: .leading, spacing: 12) {
            Label("Safety model", systemImage: "checkmark.shield.fill")
              .font(.headline)
              .foregroundStyle(.green)
            settingRow("Deletion mode", value: "Trash-first")
            settingRow("Automatic personal-file cleanup", value: "Blocked")
            settingRow("System-owned cleanup", value: "Read-only")
            Divider()
            Text(
              "Automatic cleanup never targets Documents, Desktop, Pictures, Movies, or Music. Generic Large Files and Duplicates review also excludes ~/Library and system-owned paths."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
          }
        }

        SurfaceCard {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Label("Scan exclusions", systemImage: "hand.raised.fill")
                .font(.headline)
              Spacer()
              if !model.ignoredPaths.isEmpty {
                Button("Clear all", role: .destructive) { confirmClear = true }
                  .controlSize(.small)
              }
            }
            Text(
              "Excluded folders are skipped by cleanup, large-file, duplicate, and app-leftover scans."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if model.ignoredPaths.isEmpty {
              Text("No exclusions saved.")
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
            } else {
              ForEach(model.ignoredPaths.sorted(), id: \.self) { path in
                HStack(spacing: 10) {
                  Image(systemName: "folder.badge.minus")
                    .foregroundStyle(AppTheme.accent)
                  Text(path)
                    .font(.caption)
                    .lineLimit(1)
                    .textSelection(.enabled)
                  Spacer()
                  Button {
                    model.removeIgnore(path: path)
                  } label: {
                    Image(systemName: "xmark.circle.fill")
                  }
                  .buttonStyle(.plain)
                  .foregroundStyle(.secondary)
                }
                if path != model.ignoredPaths.sorted().last { Divider() }
              }
            }
          }
        }

        SurfaceCard {
          VStack(alignment: .leading, spacing: 12) {
            Label("Permissions", systemImage: "lock.shield")
              .font(.headline)
            Text(
              "macOS may deny access to protected Library locations. The scanner records access problems and continues; it never tries to bypass system privacy controls."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            Button("Open System Settings") { model.openSystemSettings() }
          }
        }

        SurfaceCard {
          VStack(alignment: .leading, spacing: 12) {
            Label("Privacy", systemImage: "hand.raised.square")
              .font(.headline)
            settingRow("Telemetry", value: "None")
            settingRow("Network calls", value: "None in base")
            settingRow("Cleanup history", value: "Local JSON")
            settingRow("Exclusions", value: "Local JSON")
          }
        }
      }
      .padding(AppTheme.pagePadding)
      .frame(maxWidth: 900, alignment: .leading)
    }
    .alert("Clear all scan exclusions?", isPresented: $confirmClear) {
      Button("Cancel", role: .cancel) {}
      Button("Clear Exclusions", role: .destructive) { model.clearIgnores() }
    }
  }

  private func settingRow(_ title: String, value: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value).foregroundStyle(.secondary)
    }
    .font(.callout)
  }
}
