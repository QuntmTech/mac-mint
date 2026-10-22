import AppKit
import SwiftUI
import XCTest
@testable import MacCleanerApp

@MainActor
final class AppearanceTests: XCTestCase {
  func testPrimaryAndStatusTextContrastInBothAppearances() throws {
    for name in [NSAppearance.Name.aqua, .darkAqua] {
      let appearance = try XCTUnwrap(NSAppearance(named: name))
      appearance.performAsCurrentDrawingAppearance {
        for background in [AppTheme.canvas, AppTheme.surface, AppTheme.elevated, AppTheme.panel, AppTheme.selection, AppTheme.sidebar] {
          for foreground in [AppTheme.ink, AppTheme.ink2, AppTheme.accentText, AppTheme.warning, AppTheme.danger, AppTheme.info, AppTheme.violet] {
            XCTAssertGreaterThanOrEqual(contrast(foreground, background), 4.5, "Text contrast in \(name.rawValue)")
          }
        }
        for background in [AppTheme.canvas, AppTheme.surface, AppTheme.elevated, AppTheme.sidebar] {
          XCTAssertGreaterThanOrEqual(contrast(AppTheme.ink3, background), 4.5, "Tertiary text in \(name.rawValue)")
        }
        XCTAssertGreaterThanOrEqual(contrast(.white, AppTheme.accent), 4.5, "Primary button label")
        XCTAssertGreaterThanOrEqual(contrast(.white, AppTheme.dangerFill), 4.5, "Destructive button label")
        for stop in AppTheme.heroStops {
          XCTAssertGreaterThanOrEqual(contrast(.white, stop), 4.5, "White type on the Overview hero")
        }
        for swatch in AppTheme.Swatch.all {
          XCTAssertGreaterThanOrEqual(contrast(.white, swatch.start), 4.5, "White on a colored tile")
          XCTAssertGreaterThanOrEqual(contrast(.white, swatch.end), 4.5, "White on a colored tile")
          for background in [swatch.tint, AppTheme.canvas, AppTheme.surface] {
            XCTAssertGreaterThanOrEqual(contrast(swatch.text, background), 4.5, "\(swatch.name) text in \(name.rawValue)")
          }
        }
      }
    }
  }

  func testAppearanceSelectionUsesSystemOrAnExplicitScheme() {
    XCTAssertNil(AppAppearance.system.colorScheme)
    XCTAssertEqual(AppAppearance.light.colorScheme, .light)
    XCTAssertEqual(AppAppearance.dark.colorScheme, .dark)
    XCTAssertEqual(Set(AppAppearance.allCases.map(\.rawValue)), ["system", "light", "dark"])
  }

  func testResponsiveHeadersKeepTheirIntrinsicHeight() {
    _ = NSApplication.shared
    for width in [CGFloat(360), 640, 1000] {
      let heading = PageHeader(title: "Cleanup", subtitle: "Inspect caches and generated data before reviewing your selection.") {
        HStack {
          Button("Rescan") {}
          Button("Review 2.8 GB") {}
        }
      }.frame(width: width)
      let hosting = NSHostingView(rootView: heading)
      XCTAssertGreaterThan(hosting.fittingSize.height, 35)
      XCTAssertLessThan(hosting.fittingSize.height, 190, "Header at \(width) must leave room for results")
    }
  }

  private func contrast(_ foreground: Color, _ background: Color) -> Double {
    let first = luminance(foreground), second = luminance(background)
    return (max(first, second) + 0.05) / (min(first, second) + 0.05)
  }

  private func luminance(_ color: Color) -> Double {
    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { XCTFail("Missing sRGB color"); return 0 }
    func linear(_ component: CGFloat) -> Double {
      let value = Double(component)
      return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
  }
}
