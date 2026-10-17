import SwiftUI

struct PermissionHelpSheet: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Access & setup").font(.title2.bold())
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
      .padding(20)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("Permissions can affect coverage. Missing files, exclusions, cloud-only items and other errors can also explain a scan issue. Check its details before changing access, then rescan when you are ready.")
            .font(.callout).foregroundStyle(.secondary)
          PermissionsSettingsCard()
        }
        .padding(20)
      }
    }
    .frame(width: 680, height: 620)
    .background(AppTheme.canvas)
    .onExitCommand { dismiss() }
  }
}
