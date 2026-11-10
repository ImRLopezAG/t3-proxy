# WidgetKit and Siri / Shortcuts packaging

Decision: defer both integrations; keep SwiftPM and build.sh unchanged in this task.

## Evidence checked (2026-11-06)

- Apple's [Creating a widget extension](https://developer.apple.com/documentation/widgetkit/creating-a-widget-extension) instructs developers to add an application-extension target. The installed Xcode Widget Extension template defines an extension product and WidgetKit extension metadata. Compiling a SwiftUI Widget type alone does not produce an installable widget.
- Package.swift currently declares library targets and one executable. build.sh copies that executable and resources into an ad-hoc-signed app. It does not produce, embed, register, or sign a `.appex` under `Contents/PlugIns`.
- Apple's [Creating your first app intent](https://developer.apple.com/documentation/appintents/creating-your-first-app-intent) describes the intent types and their system discovery. Discovery also needs extracted metadata in the app bundle.
- A build-only proof in `/tmp/t3-native-intents-poc` compiled an AppIntent in a minimal Swift-tools 6.2 executable package successfully. No executable was launched. The installed SwiftPM/Xcode build engine emitted Swift constant-value intermediates but no `Metadata.appintents` directory or `.actionsdata` output. Compilation alone is therefore insufficient evidence of Shortcuts or Siri discovery.
- `xcrun appintentsmetadataprocessor --help` is available locally. Its required inputs include the toolchain, SDK, target triple, Xcode version, source-file list and compiler-produced constant-value list. Reconstructing those inputs in build.sh is possible, but couples packaging to the installed Xcode toolchain and SwiftPM's intermediates. It is not a clean, supported one-line addition to the present build.

These findings do not claim that command-line packaging is impossible. They show that neither feature is ready through the existing build, and a custom extraction/extension toolchain would need its own installation and system-discovery acceptance tests.

## Recommended option: generated Xcode host and extension

Keep T3ProxyCore and T3ProxyUI as local Swift packages. Add an XcodeGen specification with a macOS app target and WidgetKit extension target; share the native entry point and UI resources. Let Xcode perform App Intents metadata extraction, extension embedding and signing. App intents can live in the host; a separate App Intents extension is optional, not required merely to add Shortcuts actions.

Use a stable bundle identifier and a signing team. Configure an App Group for the host and widget with matching entitlements/profiles; verify group-container access with the actual distribution signing identity. Ad-hoc signing is not acceptance evidence for shared-container access or extension discovery. Sandbox the widget and permit only its required capabilities.

Share an atomic, versioned JSON snapshot through the App Group, containing only timestamp, provider-level pooled quota and usage/cost summaries. Never share management keys, credentials, emails, raw auth indices or request logs. The host remains the only service client and usage reader. The widget reads snapshots and labels stale/unavailable data; widget refresh scheduling is system-controlled and cannot guarantee a live menu-bar cadence.

Initial Shortcuts actions: Open Panel, Open Settings, and Get Quota Summary from the same snapshot. Opening UI needs a supported foreground intent and app activation path; read-only summary actions must work while the host is not running. Do not expose account writes, service restart, or management secrets through intents. Explicitly define whether Siri speaks cost or quota figures before enabling spoken responses.

Estimated effort: 1–2 days for generated project, signing and reproducible packaging; 1–2 days for snapshot sharing and a native widget; 1 day for intents; 1–2 days for clean-install, upgrade and discovery tests. Signing/account setup can extend that estimate.

Acceptance: install in a stable Applications location; launch once (Apple requires this before gallery discovery); confirm widget appears in gallery, survives host quit and refreshes from snapshots; verify expired readings and stale data; find and invoke each action in Shortcuts and Siri; verify updates preserve registration, group access and login items. Test on a clean macOS account with the intended signing identity.

## Alternative: retain SwiftPM with custom packaging

Build a separate extension executable with extension-safe APIs and WidgetKit linkage; construct its `.appex` Info.plist and resources; embed it under `Contents/PlugIns`; generate App Intents metadata for the appropriate binaries; sign nested code first and the host last with matching entitlements. Maintain source/constant-value lists and target triples across Xcode updates. This avoids a checked-in project, but effectively creates a bespoke app-extension build system.

Estimated effort: 3–5 days for packaging/extraction experiments and installation tests, plus widget and intent implementation. Risks: private or changing processor arguments, SwiftPM intermediate paths, dead stripping of intent declarations, missing metadata, duplicate identifiers during development, extension registration, and signing/App Group failures. Prefer the generated Xcode option unless retaining a shell-only build is itself a product requirement.

## Smaller interim option

A user-created Shortcuts “Open App” action can activate the installed app; its existing reopen handler opens the panel. This needs no new metadata, but does not provide named T3 Proxy actions, quota results, or a widget. It is a manual user workflow, not an implemented native integration.
