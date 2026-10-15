# Implementation Prompt 1: Set Up the Tablet Development and Testing Environment

You are setting up the foundation for **Greatnote**, a new handwriting-focused tablet application for both Android tablets and iPads. The repository is initially empty. Implement the environment and project structure described below; do not implement the product UI or handwriting features yet.

## Goal

Create a reproducible Flutter development environment and a minimal application that can be built, linted, and tested on Android and iOS. Optimize the setup for tablet-first development and automated testing.

## Required technology

- Use the current stable Flutter SDK and Dart version that are compatible with each other.
- Pin the Flutter version with FVM by committing `.fvmrc`. Do not rely on an unpinned global Flutter installation.
- Use Flutter's Material 3 support.
- Use `flutter_lints` and enable strict analysis options for casts, inference, and raw types.
- Use `flutter_test` for unit and widget tests, `integration_test` for end-to-end tests, and golden tests for visual regression coverage.
- Use GitHub Actions for continuous integration.
- Keep dependencies minimal. Do not add a state-management, routing, database, analytics, or networking package during this task.

## Platform requirements

- Support recent Android tablets and iPads in landscape and portrait orientations.
- Set the minimum Android SDK to a level supported by the selected Flutter stable release and document the exact value.
- Set the iOS deployment target to a version supported by the selected Flutter stable release and document the exact value.
- Keep phone layouts buildable, but treat widths below 600 logical pixels as a compact fallback rather than the primary experience.
- Use the application name `Greatnote`. If a reverse-domain application identifier is required and none exists in the repository, use `com.greatnote.app` and document how to change it.
- Do not configure signing certificates or commit secrets.

## Deliverables

1. Create the Flutter application and its Android and iOS projects.
2. Organize `lib/` into a small feature-oriented structure that can grow without premature abstraction:
   - `lib/app/` for app startup, theme wiring, and top-level configuration;
   - `lib/features/` for future product features;
   - `lib/shared/` for truly shared UI or utilities;
   - a thin `lib/main.dart` entry point.
3. Add a temporary home screen that displays `Greatnote` and a short message confirming that the environment is ready. This is scaffolding, not the final UI.
4. Add these test layers:
   - a unit-test example for a small pure-Dart utility;
   - a widget test that launches the app and verifies the temporary home screen;
   - one golden test at a representative tablet viewport;
   - one integration smoke test that launches the app and verifies the home screen.
5. Add reusable test helpers for pumping the app at these logical viewport sizes:
   - compact fallback: `390 x 844`;
   - 8-inch tablet portrait: `800 x 1280`;
   - 11-inch tablet landscape: `1194 x 834`.
6. Add scripts or documented commands for formatting, static analysis, unit/widget tests, golden tests, integration tests, Android debug builds, and iOS simulator builds.
7. Add GitHub Actions CI that runs formatting verification, analysis, and unit/widget tests on every pull request and push. Also run an Android debug build. Add an iOS simulator build on a macOS runner without attempting code signing.
8. Add a concise `README.md` containing prerequisites and exact setup commands for Windows, macOS, and Linux.

## Local environment documentation

The README must make these constraints explicit:

- Android development is supported on Windows, macOS, and Linux with Android Studio, the Android SDK, and an Android tablet emulator.
- iOS development and simulator builds require macOS, Xcode, CocoaPods, and acceptance of the Xcode license. Windows and Linux cannot produce or run an iOS build locally.
- Recommend testing pen input on physical devices because emulators do not reproduce stylus sampling, latency, pressure, or palm behavior accurately.
- Include `flutter doctor -v` and a short troubleshooting checklist for missing Android licenses, unavailable devices, CocoaPods issues, and an incompatible Java version.
- Describe how to create at least one Android tablet emulator and one iPad simulator, without hard-coding a machine-specific path.

## Configuration and quality rules

- Commit `.gitignore`, `.metadata`, dependency lockfile, platform configuration, and all test configuration required for a fresh clone.
- Do not commit generated build output, IDE-local settings, signing material, or golden-test failure artifacts.
- Ensure all text files use UTF-8 and consistent line endings.
- Avoid platform-specific behavior in application code unless it is isolated behind a clearly named adapter.
- The default app must run without network access and without environment secrets.
- Comment only where a decision is not evident from the code.

## Required verification

Run all checks available on the current host. At minimum, verify:

```text
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
flutter build apk --debug
```

On macOS, also verify an unsigned simulator build:

```text
flutter build ios --simulator
```

Run the integration smoke test on an available emulator or simulator. If the current environment cannot run a platform-specific check, do not claim it passed: report the exact command that remains and why it could not be executed.

## Acceptance criteria

- A new contributor can follow the README from a fresh clone and run the app and test suite.
- The app launches on an Android tablet emulator and an iPad simulator with no overflow or startup exception.
- Formatting and static analysis complete with no errors or warnings.
- Unit, widget, and golden tests pass deterministically.
- CI uses the pinned Flutter version and does not require secrets.
- No product functionality beyond the minimal environment-ready screen is introduced.

## Completion report

At the end, summarize the files created, the pinned Flutter/Dart and platform versions, the checks actually run and their results, and any checks that require a different host or physical device.
