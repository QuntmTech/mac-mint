# V2 Validation Record

Validation date: 2026-08-30

## Baseline preservation

V2 was evolved from the existing V1 folder. The V1 ZIP remained untouched during the upgrade.

- V1 ZIP SHA-256: `7cc84461dd4590b37859ab744ba6d1065e5e904b4184d1c5bb67700b7753decc`
- V2 keeps the same `MacCleanerCore` / `MacCleanerApp` architecture and extends it rather than replacing it.

## Checks actually run

### Core behavior

```text
swift test
Executed 18 tests, with 0 failures (0 unexpected).
```

Coverage includes:
- streaming SHA-256 correctness and cancellation;
- exact duplicate verification and exclusions;
- automatic-cleanup protected paths;
- category/path allowlists;
- reviewed-file restrictions;
- old-installer restrictions;
- cleanup selection defaults;
- persistent exclusions;
- app-leftover exact bundle-ID matching and longer-ID false-positive rejection;
- developer-cache category separation;
- large-file protected-root exclusion;
- destructive cleanup revalidation.

### Source quality

```text
swift-format lint -r Sources Tests
```

Result: PASS.

Every macOS app Swift source file was also parsed with:

```text
swiftc -frontend -parse Sources/MacCleanerApp/<file>.swift
```

Result: PASS for all app source files.

### Package/configuration

- `swift package dump-package`: PASS on the current host.
- `Resources/Info.plist`: parsed successfully; version `0.2.0`, minimum macOS `14.0`.
- `bash -n scripts/build_app.sh`: PASS.
- unresolved `TODO`, `FIXME`, and `fatalError(` scan across production/test/build sources: none found.

## Environment limitation

The available execution host for this package is Linux (`x86_64-unknown-linux-gnu`, Swift 6.2.1). Therefore **AppKit/SwiftUI semantic typechecking, the final macOS `.app` build, code-sign verification, and live UI launch were NOT RUN here**.

The repository includes a macOS GitHub Actions workflow and `scripts/build_app.sh` for those checks on a real macOS runner. Do not interpret the Linux parser pass as proof that the desktop app has already launched successfully on macOS.

## Release status

**PARTIAL / strongly validated base.** The Foundation core and destructive safety logic are executable and tested. The remaining release gate is a real macOS build + launch + interactive UI test.
