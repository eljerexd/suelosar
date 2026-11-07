# MapLibre Native Alpha: Acceptance Status (2026-11-04)

## Verdict

**NOT ACCEPTED — integration remains experimental.** The MapLibre candidate is connected to `GisMapScreen`, but the acceptance conditions for interaction, visual parity, offline behavior, Android, Release packaging, and comparative performance have not been demonstrated. FlutterMap remains the default renderer.

## Repository state

- Workspace: `C:\Users\jerem\suelosar-alpha`
- Branch: `alpha`
- HEAD: `148d0980a7dc9d40e4a35a25ee54ba3e6ef42de9`
- MapLibre package: `maplibre 0.4.0-pre.1`
- No staged changes; all implementation and pre-existing dependency/registrant changes remain uncommitted.
- No dedicated MapLibre report was present under `docs/`; this file records acceptance evidence, not a second architecture specification.

## Candidate implementation

`GisMapScreen` selects `MapLibreEngine` only with `--dart-define=SUelosAR_MAPLIBRE_NATIVE=true`; without the define, it uses FlutterMap. The engine supplies a transparent native MapLibre style and local vector sources for available PMTiles archives. `GisNativeMapSourceProvider` exposes resolved archive paths, and `MultiCoverageRepository` associates them with coverage IDs. A loopback HTTP server reads requested tiles from those local PMTiles archives. Android permits cleartext only for `127.0.0.1` through its network security configuration. Application state and decoded feature repositories remain in Flutter.

The current composition keeps reference and annotation layers in synchronized FlutterMap surfaces above/below the native map. This is a transitional hybrid renderer, not a complete native replacement. It still performs Flutter overlay rendering and does not establish parity for all MapLibre style attributes, platform behaviors, or layers.

## Evidence

### Builds and devices

- A Windows **Debug** build with `SUelosAR_MAPLIBRE_NATIVE=true` completed earlier in this validation sequence. Output: `%TEMP%\SuelosAR_MapLibre_Alpha_Verify_20261104\windows\x64\runner\Debug\suelosar.exe` (3,938,816 bytes).
- The binary was not launched or visually inspected. The Windows computer-use helper failed to initialize with `failed to write kernel assets` / OS error 3.
- `flutter devices` found only Windows desktop and Edge. `emulator -list-avds` could not run because `emulator` is not on PATH. No Android device/emulator was available.
- Android build validation was not completed. An earlier attempt was stopped after Gradle was found writing through the repository `build` junction into the preserved external build target; no APK was produced. Do not retry into that junction without an isolated build strategy.
- Windows Release validation was not possible: `.vscode/supabase.env.json` and `tool/build_windows_release.ps1` are absent. Do not generate a Release build without the required defines file.

### Tests and static checks

- Focused repository/native-source tests: **19 passed** (`gis_native_map_source_test.dart`, `gis_repository_lifecycle_test.dart`, `multi_coverage_repository_test.dart`).
- Full `flutter test --no-pub`: **232 passed, 1 failed**. The remaining grouped-suite failure is `Home launcher opens and filters soil memories`: Junín did not appear while the catalog spinner remained visible. That test passes alone; it remains an order/async-isolation issue and is not classified as pre-existing.
- Two other tests that failed in the first grouped run (`GIS map measures and clears a two-point distance`, `saved area geometry opens the existing editor`) pass alone. The measurement regression was caused by awaiting the FlutterMap engine's null native hit-test; `GisMapScreen` now calls the asynchronous hit-test only when the engine renders polygons internally.
- Targeted `dart analyze`: exit 0, with two existing informational `prefer_initializing_formals` findings in `multi_coverage_repository.dart` lines 34–35; no errors.
- Full `flutter analyze --no-pub`: exit 1 because the analyzer reports three infos and no errors: the same two `prefer_initializing_formals` findings plus `depend_on_referenced_packages` for `crypto` imported by `tool/optimize_buenos_aires_pmtiles.dart`.
- `dart format --output=none --set-exit-if-changed` on touched Dart files: exit 0, no formatting changes needed.
- `git diff --check`: exit 0; Git printed only LF-to-CRLF working-copy notices for generated registrants.

## Blocking acceptance issue: pointer routing

`MapLibreEngine.buildMapSurface` places a full-screen `FlutterMap` annotation overlay after `MapLibreMap`. The installed FlutterMap 8.3.2 surface includes an opaque hit-test background even when its interaction flags are disabled. Consequently, the top overlay can consume pointer hit tests before they reach the native platform view. This has not been verified on a running app, but source composition makes native pan/zoom and map taps unsafe to assume. Simply wrapping the overlay in `IgnorePointer` would also disable existing Flutter annotation interactions, including interactive measurement vertices and marker actions. A tested pointer-routing design preserving those interactions is required before acceptance.

## Not yet validated

- Native map pan, pinch/wheel zoom, camera restoration, and tap selection on Android and Windows.
- Original feature IDs and full soil-series attributes after native rendered-feature queries across all coverages.
- Marker, GPS, saved-measurement editing, province controls, and every other overlay interaction on the native renderer.
- Screenshot comparison of identical regions, layers, zoom, selection, and viewport against FlutterMap.
- Offline restart with real local PMTiles on both platforms; Windows packaged installation paths and Android private extraction/persistence.
- Android Release and Windows Release builds, native texture/resource lifecycle, memory stability, and runtime diagnostics.
- Before/after Android and Windows performance measurements (frame-time percentiles, loading, selection latency, CPU/GPU, memory).

No performance improvement is claimed. The available Windows Debug compile is not a Release or runtime acceptance result.

## Preserve current rollout gate

Keep FlutterMap as the default. Keep MapLibre opt-in only. Do not remove the FlutterMap fallback, publish, or describe the migration as complete until the blockers above have been tested and resolved.
