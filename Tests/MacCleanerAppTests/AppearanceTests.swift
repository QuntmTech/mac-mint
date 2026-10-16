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
        for background in [AppTheme.canvas, AppTheme.surface, AppTheme.panel, AppTheme.hero, AppTheme.selection] {
          for foreground in [AppTheme.ink, AppTheme.accentText, AppTheme.warning, AppTheme.danger, AppTheme.info, AppTheme.violet] {
            XCTAssertGreaterThanOrEqual(contrast(foreground, background), 4.5, "Text contrast in \(name.rawValue)")
          }
        }
        XCTAssertGreaterThanOrEqual(contrast(.white, AppTheme.accent), 4.5, "Primary button label")
      }
    }
  }

  func testAppearanceSelectionUsesSystemOrAnExplicitScheme() {
    XCTAssertNil(AppAppearance.system.colorScheme)
    XCTAssertEqual(AppAppearance.light.colorScheme, .light)
    XCTAssertEqual(AppAppearance.dark.colorScheme, .dark)
    XCTAssertEqual(Set(AppAppearance.allCases.map(\.rawValue)), ["system", "light", "dark"])
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
