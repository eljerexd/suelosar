# Local GIS Release Benchmark

`tool/benchmarks/gis_release_benchmark_main.dart` is a standalone benchmark
entrypoint. It is not imported by `lib/main.dart` and does not affect the
normal SuelosAR application target.

The byte-exact Beta-era source is preserved at
`tool/benchmarks/archive/gis_release_benchmark_main_beta.dart`. It depended on
the old private `GisMapScreenState` implementation and is excluded from normal
analysis; use the current entrypoint above for benchmark builds.

From the repository root, build the benchmark with the same MapLibre and
Supabase defines used for the Windows Debug configuration:

```powershell
flutter build windows --release `
  --target=tool/benchmarks/gis_release_benchmark_main.dart `
  --dart-define=SUelosAR_MAPLIBRE_NATIVE=true `
  --dart-define-from-file=.vscode/supabase.env.json
```

Run `build/windows/x64/runner/Release/suelosar.exe`. The benchmark emits
`GIS_RELEASE_SAMPLE` tile/cache/render metrics and `GIS_RELEASE_FRAMES` frame
timing summaries to the debug console. The application entrypoint remains
`lib/main.dart` for normal builds.

The tile counts are read through `GisRenderMetrics`, the existing public
diagnostics object passed to `GisMapScreen`; the benchmark does not depend on
the screen's private State implementation.
