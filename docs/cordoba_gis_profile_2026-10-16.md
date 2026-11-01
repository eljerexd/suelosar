# Córdoba GIS rendering profile — 2026-10-16

## Setup

- Branch: `beta`; Android emulator `emulator-5554`, API 37; Flutter profile mode, Impeller OpenGLES.
- Camera fixed at latitude -32.5, longitude -63.5; viewport 426.67 × 952 logical pixels at every zoom.
- At z8, z10, z12, and z14, tiles were warmed and the same eight-step horizontal/vertical camera path plus a +0.15 zoom-and-return was repeated three times. Timeline was cleared before each measured repetition.
- Temporary profile-only probes sampled tile/geometry counts and timed the existing stages. They were removed after this report. Paint timing used the existing `_GisPaintProfiler` wrapper, which adds measurement overhead; these values must not be compared directly with uninstrumented builds.
- Table times are medians of the three repetition-level p50/p95 values, not pooled-frame quantiles. Each repetition produced 10 frames at z8 or 12 frames at other zooms.

## Warm rendering measurements

| Zoom | Visible tiles | Feature instances¹ | Parts / vertices in visible tiles | Vertices per part p50 / p95 / max | Parts / vertices submitted² | UI p50 / p95 ms | Raster p50 / p95 ms |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 8 | 10 | 622 | 8,545 / 82,387 | 5 / 27 / 599 | 7,511 / 73,134 | 43.22 / 52.77 | 57.65 / 65.56 |
| 10 | 15 | 663 | 10,641 / 123,983 | 7 / 31 / 2,092 | 5,076 / 64,701 | 28.62 / 46.99 | 52.83 / 59.39 |
| 12 | 15 | 189 | 1,207 / 64,681 | 32 / 162 / 1,500 | 605 / 37,115 | 6.21 / 7.50 | 32.70 / 46.96 |
| 14 | 10 | 50 | 102 / 4,102 | 34 / 105 / 160 | 70 / 3,539 | 1.55 / 2.44 | 29.52 / 34.30 |

¹ Sum of distinct feature IDs *within each visible tile*, not unique source features across tiles. For example, at z8 a single tile had 88 feature instances but 2,516 polygon parts. ² Geographic filter output before flutter_map's own culling; not the actual painted count.

| Zoom | Filter invocations / total ms | Polygon-layer cache hit / miss | Polygon child-paint calls / total CPU ms | UI / raster frames over 16.67 ms |
|---:|---:|---:|---:|---:|
| 8 | 100 / 2.92 | 28 / 72 | 100 / 359.65 | 10/10 / 10/10 |
| 10 | 150 / 2.40 | 60 / 90 | 174 / 304.53 | 12/12 / 12/12 |
| 12 | 150 / 0.35 | 60 / 90 | 174 / 48.00 | 0/12 / 12/12 |
| 14 | 120 / 0.12 | 64 / 56 | 140 / 6.78 | 0/12 / 12/12 |

Cache hit/miss here refers to `_GisTilePolygonLayerState` reusing or rebuilding its layer, not the PMTiles repository. The repository performed **zero reads and zero MVT decodes** in all warmed measured repetitions. CPU child-paint totals sum multiple tile layers over the interval and are not GPU raster times.

## Cold tile loading

| Zoom | PMTiles reads, p50 / p95 ms³ | MVT decodes, p50 / p95 ms | Decode isolate round-trip total ms | Geometry conversion: tiles / features / parts / vertices / total ms |
|---:|---:|---:|---:|---:|
| 8 | Not captured: z8 tiles were already cached before timeline started | Not captured | Not captured | Not captured |
| 10 | 45, 105.21 / 282.91 | 35, 2.45 / 16.15 | 998.39 | 35 / 1,668 / 22,093 / 270,637 / 50.15 |
| 12 | 35, 132.89 / 237.14 | 35, 1.03 / 22.50 | 954.51 | 35 / 421 / 2,538 / 137,676 / 16.30 |
| 14 | 28, 63.86 / 131.16 | 28, 0.14 / 0.59 | 381.21 | 28 / 119 / 313 / 12,468 / 5.13 |

³ `PMTilesRead` spans asynchronous archive lookup/read. Durations overlap across concurrent tile requests and must **not** be summed as elapsed wall time or interpreted as pure physical disk I/O. Cold counts include the one-tile prefetch ring and, where coverages intersect, can include multiple archives; they are not visible-tile counts. Decoding ran in isolates; conversion to rendered polygon parts ran after the results returned to the UI isolate.

## CPU sampling and interpretation

- In one additional warmed z8 path, 104 of 422 UI-isolate samples included `flutter_map`'s `PolygonPainter.paint`; 8 included `projectList`. At z10, 76 of 458 included `PolygonPainter.paint`. These are inclusive stack sample counts, **not** exclusive CPU percentages or exact durations. Native Flutter engine frames lack full symbolization.
- At low zoom, the load is predominantly **many small polygon parts**, not a few enormous parts: p50 is 5–7 vertices, yet 8,545–10,641 parts are mounted. The large part-to-feature ratio is consistent with multipart geometry and tile clipping/buffers. Per-tile identity across MVT tile edges was not counted, so the precise contribution of duplicate buffers remains unknown.
- Warm z8/10 UI work is strongly associated with CPU-side polygon paint/path construction. The existing translucent fill and border path handling in flutter_map can flush batches frequently. Projection and simplification appear in CPU samples, but much less often than paint in this captured path. No exact projection wall duration was available without instrumenting flutter_map itself.
- Raster frame time exceeds UI time at all four zooms and stays high at z14 with only 70 submitted parts. Therefore the GPU/raster cost **cannot be attributed exclusively** to Córdoba polygons; other map layers and emulator rendering overhead remain possible contributors. These measurements do not establish actual painted polygon counts or GPU utilization.
- Cold PMTiles read and isolate round-trip may explain loading stalls, but they do not explain the warmed z8/10 frame cost: no tile read/decode occurred during those paths. Viewport-filter work itself was 0.12–2.92 ms *total per repetition*, not a dominant stage.

## Next decision

No optimization was implemented. If an optimization is proposed later, compare it against this fixed camera/path with identical instrumentation and warm/cold cache states, three or more repetitions, and visual/selection/label checks. Do not drop features or simplify geometry based on these counts alone. The earlier viewport-filter A/B did not establish a frame-time benefit.

## Controlled A/B: Córdoba viewport filter

The table above is historical context, **not** the causal baseline for this comparison. This A/B used one Flutter 3.47.2 beta profile build on `emulator-5554` (API 37, Impeller OpenGLES), with a temporary profile-only runtime switch at the existing Córdoba paint-list filter. A retained the filter; B bypassed only that filter. All other rendering code, assets, cache policy, and instrumentation were identical. The temporary switch and probes were removed after measurement.

At each zoom, the camera started and ended at (-32.5, -63.5), with a 426.67 x 952 logical-pixel viewport. Each repetition warmed the same horizontal/vertical eight-pan path and a +0.15 zoom-and-return, then cleared the VM timeline and measured that path. Camera steps were 180 ms apart, with 220 ms at the zoom step and 500 ms after return. Order was A/B alternating, five measured repetitions per variant at each of z8, z10, z12, and z14. The exact sorted visible-tile IDs and camera dimensions matched between all 10 repetitions at each zoom. No PMTiles reads or MVT decodes occurred in any timed path. Each yielded 10-15 UI and raster frames. Values below are **medians of the five repetition-level p50/p95 frame times**, not pooled-frame percentiles; `delta` is (A/B - 1), so positive means the filter was slower.

| Zoom | Reps A/B | Decoded parts | Submitted parts A / B (delta) | Submitted vertices A / B | UI p50 A / B (delta), ms | UI p95 A / B (delta), ms | Raster p50 A / B (delta), ms | Raster p95 A / B (delta), ms |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 8 | 5 / 5 | 8,545 | 7,511 / 8,545 (-12.1%) | 73,134 / 82,387 | 48.09 / 34.89 (+37.8%) | 60.49 / 37.51 (+61.3%) | 62.06 / 61.11 (+1.6%) | 76.27 / 68.20 (+11.8%) |
| 10 | 5 / 5 | 10,641 | 5,076 / 10,641 (-52.3%) | 64,701 / 123,983 | 32.51 / 25.52 (+27.4%) | 43.66 / 31.40 (+39.1%) | 58.15 / 55.87 (+4.1%) | 79.55 / 65.48 (+21.5%) |
| 12 | 5 / 5 | 1,207 | 605 / 1,207 (-49.9%) | 37,115 / 64,681 | 7.06 / 5.17 (+36.5%) | 10.38 / 8.87 (+17.0%) | 34.73 / 35.12 (-1.1%) | 53.59 / 47.08 (+13.8%) |
| 14 | 5 / 5 | 102 | 70 / 102 (-31.4%) | 3,539 / 4,102 | 1.66 / 1.45 (+14.2%) | 4.47 / 2.19 (+104.2%) | 30.75 / 28.95 (+6.2%) | 37.92 / 43.83 (-13.5%) |

The filter's timed-path cost was small: median 3.03, 2.63, 0.40, and 0.08 ms **total per repetition** at z8/10/12/14. More consequentially, its visible-list changes caused polygon-layer cache misses: median cache hits out of 100/150/150/120 layer builds were 28/60/60/64 for A versus 100/147/147/115 for B. Median polygon-object creation during the timed path was 59,922/18,136/2,604/297 for A versus 0/1,603/240/65 for B. These are cumulative construction counters, not unique source features or actual polygons painted. The differing cache behavior is a consequence of the filter under the unchanged cache policy, not a separate A/B configuration change.

**Interpretation:** the filter reduced submitted parts and vertices, but did **not** improve frames on this emulator/path. UI p50 was higher for A in all five paired repetitions at z8, z10, and z12, and four of five at z14. UI p95 and raster p95 varied more, including outliers; raster p50 differences were small or mixed. This supports a repeatable UI regression for the tested camera path, not a claim of a general GPU effect. Submitted parts are the list passed to `PolygonLayer`; flutter_map subsequently projects and culls them, and the actual painted-polygon count was unavailable. The timeline did not isolate paint duration without adding a paint wrapper that would change the benchmark. Results may differ on physical Android devices, other locations, cold caches, or longer gesture sequences.

**Functional sampling:** fixed-center screenshots at z8 and z14 showed the same visible linework and labels in both variants, including small units near the viewport edge; no static gaps were observed. The same z14 unit (`Mf1`) was selected by tapping in both variants; the highlight and label position remained visible, and a second tap in B opened its details, confirming hit-testing. Timed pans/zoom completed without exceptions, but screenshots do not prove the absence of transient flicker or delayed appearance on every path. Other provinces were not exercised; the temporary toggle and production filter condition were Córdoba-only.

**Recommendation:** revise the filter/cache interaction before treating this as a performance optimization. Do not retain it on the strength of submitted-part counts alone; a subsequent separately approved change could compare removal or a cache-preserving design on a physical device and additional camera paths. No production optimization was made in this experiment.

## Follow-up removal experiment: stopped before measurement

On `beta`, the Córdoba paint-list filter was temporarily bypassed with a single change to `paintPolygons`; the decoded tiles, cache policy, labels, selection, and other provinces were left untouched. `flutter build apk --profile --flavor beta --dart-define-from-file=.vscode/supabase.env.json` succeeded, and that APK was started on `emulator-5554` (API 37). The profile VM service reported a running main isolate. However, the emulator/app stopped responding promptly on the GIS search screen: Back and repeated taps did not dismiss it during the observation window. The user reported that it responded later, after the profile session had been stopped. The requested stationary, pan, and zoom-transition paths could not be started, and no Córdoba frames or functional checks were collected. The delayed response was not treated as performance data.

| Zoom | New repetitions (filter off) | UI p50/p95 | Raster p50/p95 | Submitted parts | Cache activity |
|---:|---:|---:|---:|---:|---:|
| 8 | 0 | unavailable | unavailable | unavailable | unavailable |
| 10 | 0 | unavailable | unavailable | unavailable | unavailable |
| 12 | 0 | unavailable | unavailable | unavailable | unavailable |
| 14 | 0 | unavailable | unavailable | unavailable | unavailable |

The controlled A/B table above remains the only comparable frame evidence, and it covers one fixed camera path, not the three new paths requested here. It cannot establish the effect of permanently removing the filter across other views or gestures. No new percentage changes or actual painted-polygon counts can be computed. No gaps, flicker, selection behavior, or label stability could be assessed in this attempt.

**Decision:** inconclusive. The original Córdoba viewport filter was restored exactly (the GIS source SHA-256 matches the pre-experiment value `656464E451F205679F8DB8979279AAAA4A2E1729A104527A8F4C5CBEAFFCF305`). Do not remove it based on this failed run. A later attempt established that the apparent emulator hang was transient; see the resumed experiment below.

## Resumed removal experiment: measured B, invalid A comparison

On `beta`, the sole temporary source change again replaced the Córdoba-filtered `paintPolygons` list with `widget.tile.polygons`. The beta profile APK built successfully and ran on `emulator-5554` (API 37, Impeller OpenGLES). The map was moved from its initial z7 view into Córdoba using two fixed ADB swipes, then double-tapped to z8. A warmed z8 pilot pan produced 20 `Frame` and 20 `GPURasterizer::Draw` duration samples, so the measurement mechanism was confirmed before extending the run. At each zoom, the timed path used a 600 ms horizontal swipe in each direction, with a 500 ms settling period; each path was warmed with the same two swipes and measured three times. Two double-taps advanced to each subsequent zoom. All values below are **medians of three repetition-level percentiles**, in milliseconds, for **B (filter bypassed) only**.

| Zoom | Reps / UI frames per rep | UI p50 / p95 ms | Raster p50 / p95 ms | Stationary / zoom-transition measurements |
|---:|---:|---:|---:|---|
| 8 | 3 / 34, 37, 39 | 14.44 / 23.35 | 30.04 / 48.47 | Three one-second warmed stationary windows produced no frames; z8-to-z10 produced 22 frames, but no percentile capture. |
| 10 | 3 / 16, 13, 15 | 3.83 / 10.21 | 92.68 / 117.45 | Not measured separately. |
| 12 | 3 / 29, 36, 22 | 2.47 / 6.00 | 34.90 / 103.74 | Not measured separately. |
| 14 | 3 / 45, 35, 45 | 2.02 / 7.79 | 25.30 / 36.13 | Not measured separately. |

The z10 raster p95 values per repetition were 105.15, 340.18, and 117.45 ms; the high outlier and the very different z10 map area underscore run variability. Screenshots confirmed Córdoba soil boundaries at z8, z10, z12, and z14. At z14, tapping unit `MNto-9` selected it with a visible highlight and unchanged label position in that sample; a second tap opened its cartographic-unit details. This is a limited spot check, not exhaustive edge/flicker validation. The timeline exposed UI/raster frame events but no reliable submitted-part, vertex, polygon-layer cache, or PMTiles/MVT counters in this run; absence of matching tile-read events is **not** proof of zero reads. Submitted parts must not be confused with polygons actually painted.

The attempt to install the corresponding **A (filter enabled)** profile APK first returned `INSTALL_FAILED_INSUFFICIENT_STORAGE`. `flutter run` automatically uninstalled the previous beta package and then installed and launched A. The z8 screenshot showed reference-map linework but **no Córdoba soil polygons** at that moment. No A timings were taken, and the B measurements above must **not** be compared numerically with the historical A/B table, which used a different camera and gesture path. No percentage improvement or regression is claimed from this resumed attempt.

**Correction after installation diagnosis:** `pm path` showing only `base.apk` was normal for this profile APK: Córdoba's PMTiles archive is bundled in the base APK. The complete 77,400,595-byte archive was copied into the app's private cache, and the soil polygons became visible after cold initialization. The earlier screenshot did not establish missing provincial data or a failed split installation. The precise package-install constraint behind `INSTALL_FAILED_INSUFFICIENT_STORAGE` remains unknown because `/data` was not measured at the instant of failure.

**Decision:** inconclusive; leave the original filter enabled. The temporary bypass was removed, and `gis_map_screen.dart` again matches the pre-experiment SHA-256 `656464E451F205679F8DB8979279AAAA4A2E1729A104527A8F4C5CBEAFFCF305`. A valid retry would first confirm fully loaded Córdoba soil data in both variants, then verify identical visible tiles/camera and capture paired frame timings without uninstalling between runs.

## Follow-up A/B after confirming Córdoba data availability

On `beta`, A was the already-installed filter-enabled beta profile APK on `emulator-5554` (API 37). B was built with the sole temporary source difference `paintPolygons = widget.tile.polygons` in the Córdoba polygon-layer path, using `flutter build apk --profile --flavor beta --dart-define-from-file=.vscode/supabase.env.json`. Its 541.0 MB APK installed successfully with `adb install -r -t` without uninstalling or clearing app data. Both variants showed Córdoba soil outlines, not merely the independent reference map. The source filter was restored after measurement; its SHA-256 again matches `656464E451F205679F8DB8979279AAAA4A2E1729A104527A8F4C5CBEAFFCF305`.

The A pilot at z8 captured 70 UI `Frame` and 70 `GPURasterizer::Draw` events across three back-and-forth swipes; polygons remained visible. B's z8 pilot also produced valid events (18–19 pairs per repetition) with polygons present. At each zoom, the measured path was a 600 ms horizontal swipe from (720,1300) to (520,1300) and the reverse swipe, preceded by the same warm-up pair and followed by 450 ms of settling. The VM timeline was cleared immediately before each measured pair. Three repetitions were captured for A and B at z8, z10, z12, and z14. Two center-screen double-taps advanced each two-level zoom step. Screenshots at every zoom were used to align the same recognizable Córdoba boundaries before B measurements; this was visual matching, **not** a logged exact camera coordinate or identical sorted tile-ID verification. The 1280 x 2856 emulator viewport was unchanged. A ran before B rather than alternating because switching required a 541 MB rebuild/install. Stationary screenshots and zoom transitions were checked, but they were not separately timed.

The table gives medians of the three repetition-level p50/p95 values in milliseconds, not pooled-frame quantiles. Delta is B relative to A; negative is faster without the filter. Each timed repetition yielded 9–25 UI frames (depending on zoom/variant). These are **new** profile-mode measurements, separate from the earlier controlled A/B and B-only run.

| Zoom | Reps A/B | UI p50 A / B (delta) | UI p95 A / B (delta) | Raster p50 A / B (delta) | Raster p95 A / B (delta) |
|---:|---:|---:|---:|---:|---:|
| 8 | 3 / 3 | 52.95 / 37.51 (-29.2%) | 108.44 / 66.03 (-39.1%) | 84.11 / 71.42 (-15.1%) | 112.40 / 93.64 (-16.7%) |
| 10 | 3 / 3 | 30.52 / 20.41 (-33.1%) | 45.62 / 31.73 (-30.4%) | 159.02 / 148.68 (-6.5%) | 186.12 / 213.39 (+14.7%) |
| 12 | 3 / 3 | 5.98 / 5.79 (-3.2%) | 19.76 / 17.77 (-10.1%) | 114.52 / 108.57 (-5.2%) | 133.08 / 133.70 (+0.5%) |
| 14 | 3 / 3 | 3.46 / 2.90 (-16.2%) | 6.85 / 7.05 (+2.9%) | 50.32 / 51.20 (+1.7%) | 65.48 / 61.75 (-5.7%) |

The z8/10 UI medians favor B in all three repetitions and agree directionally with the earlier controlled A/B. Raster results are mixed and sometimes very slow on this emulator (z10 raster p50 around 149–159 ms), so these data do not establish a general raster benefit. The timeline exposed frame events but no reliable new tile-read, MVT-decode, polygon-layer cache, or submitted-part counters. Warm-up swipes do not prove identical cache state. Submitted parts for this new run and actual polygons painted are **unavailable**; the earlier controlled A/B's part counts must not be relabeled as new measurements.

Static screenshots showed boundaries and small units at the viewport edges for both variants, without a persistent blank polygon layer. B's z14 tap selected a Córdoba soil polygon and displayed its highlight/card; its `CoB3` label did not move in that before/after selection sample. Some label placements differed between the two separately launched variants at near-matched z12/14 views. The reason was not established, and neither exact tile equality nor exhaustive flicker/label correctness was verified. Other provinces were not exercised.

**Decision:** the observed low-zoom UI improvement is promising but this follow-up alone does not meet the strict identical-camera/tile and full correctness checks needed to leave a behavior change in place. The filter was restored exactly. A future decision should use exact camera/tile IDs and comparable cache counters, ideally alternating variants on a device without a costly reinstall. Do not infer that fewer submitted parts means fewer polygons actually painted.

After restoring the source, the filter-enabled beta profile APK was rebuilt successfully and reinstalled on `emulator-5554` with `adb install -r -t` (`Success`), again without uninstalling or clearing app data. The existing Córdoba PMTiles cache was preserved. Focused Córdoba/render tests passed (33 tests), targeted `flutter analyze` found no issues, and `git diff --check` passed.

## Follow-up z8/z10 bypass experiment (17 October 2026)

The filter-enabled beta profile APK (A) was already installed on `emulator-5554` (API 37, 1280 x 2856). Córdoba soil outlines were visible before timing. The only temporary source change for B replaced the Córdoba-filtered `paintPolygons` expression in `_GisTilePolygonLayerState._buildPolygonLayer` with `widget.tile.polygons`; it left decoded data, hit-testing, labels, cache conditions, and every other province unchanged. `flutter build apk --profile --flavor beta --dart-define-from-file=.vscode/supabase.env.json` succeeded (541.0 MB); `adb install -r -t` installed B over A without clearing data.

Both runs started from Home, used the same two ADB swipes into Córdoba, and reached the same visually matched z8 view. Each of five repetitions per variant/zoom warmed the view with a 600 ms horizontal swipe from (720,1300) to (520,1300) and its reverse, settled for 400 ms, cleared the profile VM timeline, repeated the swipe pair, and settled for 450 ms. UI `Frame` and `GPURasterizer::Draw` begin/end trace events were paired to obtain durations. Each repetition yielded 12–15 frame pairs; the table is the median of the five repetition-level p50/p95 values, in milliseconds. A ran before B because switching required a 541 MB rebuild/install, so order was not alternated.

| Zoom | Reps A/B | UI p50 A / B | UI p95 A / B | Raster p50 A / B | Raster p95 A / B |
|---:|---:|---:|---:|---:|---:|
| 8 | 5 / 5 | 57.64 / 49.86 (-13.5%) | 103.36 / 65.60 (-36.5%) | 84.19 / 95.24 (+13.1%) | 108.12 / 113.06 (+4.6%) |
| 10 | 5 / 5 | 28.05 / 20.69 (-26.2%) | 57.92 / 28.84 (-50.2%) | 101.38 / 104.26 (+2.8%) | 124.17 / 116.02 (-6.6%) |

Negative deltas mean B was faster. z8 screenshots were nearly identical, including soil outlines at the viewport edge. At z10, B was aligned to A by matching the 10 km scale bar and landmarks (`Co35`, `GC1`, Río Cuarto); exact camera coordinates, tile IDs, and cache contents were **not** logged, so this is a close visual match rather than a controlled identical-camera comparison. The same warmed pan commands and viewport were used, but the A/B order and cache state were not controlled. No new submitted-part, actual-painted-polygon, vertex, or cache-hit measurements were available. The historic A/B figures above must not be treated as measurements of this run.

Both variants rendered Córdoba soil polygons. Static inspection showed small outlines at viewport edges and no persistent gaps. In B, tapping a Córdoba unit selected and highlighted it, opened its information card, and left the `MA1` label at its apparent pre-tap anchor. Hit-testing thus worked in that sample. Timed pans showed no visible failure, but static captures cannot exclude brief flicker or validate all labels and edges.

**Decision:** B again improved the measured UI path, but z8 raster p50 worsened 13.1% and raster was the slower frame stage on this emulator. Along with the unmatched exact camera/tile/cache state, this does not establish better whole-map fluency. Per the experiment's stop criterion, the bypass was removed and the original viewport filter remains enabled in source; its SHA-256 again matches `656464E451F205679F8DB8979279AAAA4A2E1729A104527A8F4C5CBEAFFCF305`. Do not report a conclusive performance win or remove the filter on these data alone.

The four focused Córdoba/render test files passed (33 tests), targeted `flutter analyze` reported no issues, and `git diff --check` passed. The filter-enabled beta profile APK was rebuilt and installed on the same emulator with `adb install -r -t` (`Success`) so the installed variant again matches the restored source, without clearing app data.

## Path preparation and painting audit (17 October 2026)

**Hypothesis examined:** reuse projected geometry or prepared paths during warmed Córdoba pans to reduce UI and raster frame time without changing cartography. No source optimization was made. The existing profile measurements above are the baseline; there is no new A/B result or before/after percentage for this audit.

The tile repository (`lib/gis/gis_repository.dart`) caches decoded `GisLayer` values and coalesces concurrent tile loads. `_cacheRenderedTile` and `_buildRenderedPolygons` (`lib/gis/gis_map_screen.dart`) convert each decoded feature into persistent `_RenderedGisPolygon` parts per rendered tile. Each part caches normal/selected `Polygon` objects in `toPolygon`. `_GisTilePolygonLayerState._buildPolygonLayer` keeps an identical `PolygonLayer` widget while tile identity, floored zoom, selection, style, and (for Córdoba) the viewport-filtered part list match. The Córdoba filter remains enabled and unchanged.

In installed `flutter_map` 8.3.1, `ProjectionSimplificationManagement.build` caches projected coordinates and the simplified list per floored zoom and device-pixel ratio. Its `didUpdateWidget` clears both caches whenever a new `PolygonLayer` widget updates the same element. `PolygonLayer.build` then culls by geographic bounding box. `_PolygonPainter.paint` converts projected coordinates to camera-relative offsets, constructs fill and border paths, and draws them for the surviving polygons on each paint; camera movement changes the required screen-space offsets. The painter creates new paths for a repaint and flushes fill/border paths during the polygon loop. The app already uses `polygonCulling: true`, `painterFillMethod: evenOdd`, no FlutterMap polygon labels, and `drawInSingleWorld: true`. Changing opacity, outlines, geometry, simplification, draw order, or the filter to reduce these operations is outside the permitted visual/accuracy scope; there is no public FlutterMap API here to reuse a camera-independent screen-space `Path`.

The existing warmed profile counted 8,545 parts at z8 and 10,641 at z10 in visible tiles, with 7,511 and 5,076 parts submitted after the current filter. Repository reads and MVT decodes were zero in the warmed measured paths. At z8, 104/422 sampled UI stacks included `PolygonPainter.paint` versus 8/422 including `projectList`; at z10, 76/458 included `PolygonPainter.paint`. These are **inclusive samples**, not exclusive CPU cost. Existing child-paint totals (359.65 ms across 100 tile paints at z8; 304.53 ms across 174 at z10) include measurement-wrapper overhead and cannot isolate offset conversion, path construction, `canvas.drawPath`, or native raster work. The raster p50 was already high at z14 with only 70 submitted parts, so raster delay cannot be attributed solely to Córdoba polygon paths.

**Decision:** no supported minimal source optimization was found. The app-side polygon-object and layer reuse already address the clearly avoidable reconstruction; bypassing the viewport filter improved UI but worsened z8 raster in the latest experiment. A custom path cache, alternative fill renderer, or polygon reordering would need visual and selection guarantees not supplied by these measurements. Therefore no production code, dependency, or viewport-filter change was made, and there is no new frame-performance claim.

**Smallest next measurement:** on the same fixed z8/z10 cameras and warmed path, collect frame-aligned exclusive timings for FlutterMap's projection/simplification, `PolygonLayer.build` culling, and the painter's offset conversion, fill-path construction, solid-border path construction, and `canvas.drawPath` calls, plus the existing UI/raster frame timeline. This would require temporary measurement-only probes inside the installed FlutterMap 8.3.1 implementation (or an equivalent local instrumented copy), removed after profiling. Compare at least five repetitions against an identically instrumented baseline and verify exact camera/tile IDs. Only then choose one path-stage change that can preserve translucent fills, holes, boundaries, hit-testing, and label stability. Native raster attribution remains unavailable from the existing Dart-side counters.

## Stage-by-stage sampled profile (17 October 2026)

**Scope and setup.** The source remained on `beta` with the Córdoba viewport filter enabled and unchanged. No production or temporary source instrumentation was added. The already-installed beta profile app ran on `emulator-5554` (Android API 37, 1280 x 2856). Screenshots confirmed Córdoba soil polygons at z8 and z10 before measurement. The map was reached from Home using two fixed ADB swipes and then advanced by center double-taps. Each repetition warmed the view with a 600 ms horizontal swipe from (720,1300) to (520,1300) and its reverse, settled for 400 ms, cleared the VM timeline, repeated the swipe pair, and settled for 450 ms. The same viewport and input coordinates were used; exact camera coordinates and sorted tile IDs were **not** captured. Thus this is stage diagnosis, not a controlled before/after comparison or proof of identical geometry across repetitions.

The profile VM's 1 ms CPU sampler was enabled at runtime. Paired `Frame` and `GPURasterizer::Draw` timeline events provide UI and raster frame durations. The CPU table counts *inclusive sampled stacks* containing the named functions during the same trace interval; categories overlap and counts are not exclusive milliseconds, precise call durations, or GPU time. No Dart paint callback duration was interpreted as native raster execution. Runtime sampling and VM-service timeline collection add overhead, so these frame values should not be compared numerically with earlier uninstrumented runs.

| Zoom | Valid reps / planned | UI p50 per rep (ms) | UI p95 per rep (ms) | Raster p50 per rep (ms) | Raster p95 per rep (ms) |
|---:|---:|---|---|---|---|
| 8 | 5 / 5 | 36.45, 37.78, 40.74, 40.04, 37.37 | 71.65, 68.42, 77.77, 63.64, 68.70 | 51.10, 51.53, 52.46, 52.67, 51.11 | 60.83, 58.30, 58.98, 58.55, 62.22 |
| 10 | 2 / 5 | 15.59, 15.08 | 28.79, 23.85 | 24.85, 24.49 | 27.22, 26.40 |

| Zoom / rep | CPU samples | `PolygonPainter.paint` | `getOffsetsXY` inside paint | `_addBorderToPath` inside paint | `Path.addPolygon` inside paint | `Canvas.drawPath` inside paint | `projectList` | `simplifyPoints` |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| z8 / 1 | 375 | 258 | 62 | 48 | 22 | 107 | 17 | 9 |
| z8 / 2 | 366 | 258 | 68 | 52 | 25 | 95 | 13 | 11 |
| z8 / 3 | 408 | 288 | 68 | 50 | 28 | 124 | 16 | 15 |
| z8 / 4 | 374 | 277 | 65 | 40 | 35 | 120 | 11 | 12 |
| z8 / 5 | 397 | 266 | 61 | 48 | 33 | 106 | 13 | 10 |
| z10 / 1 | 301 | 167 | 29 | 39 | 22 | 70 | 13 | 15 |
| z10 / 2 | 168 | 44 | 8 | 9 | 3 | 19 | 3 | 6 |

At z8, every valid repetition included more samples in `PolygonPainter.paint` than in `projectList` or `simplifyPoints`; the paint stack included offset conversion, border construction, path addition, and `drawPath`. This supports *paint-side UI work as an important cost in the sampled path*, but cannot rank those sub-stages by exclusive duration. `Canvas.drawPath` samples represent synchronous UI-thread work entering the drawing API, **not** GPU execution. Raster p50 was about 51-53 ms in these z8 repetitions, but the timeline cannot assign that raster time specifically to Córdoba polygons versus other map/UI content.

The installed FlutterMap 8.3.1 source confirms a possible redundant calculation: in `layer/polygon_layer/painter.dart`, `drawIfVisible` obtains `fillOffsets` for projected polygon points (line 362), then, when drawing a border, calls `getOffsetsXY` again for those same points and shift (lines 424-429). The fill path uses `filledPath.addPolygon` (line 411), border path construction calls `_addBorderToPath` (line 415), and `drawPaths` flushes drawing (line 165). `layer/shared/layer_projection_simplification/state.dart` caches projection and simplified elements in `build` but clears them on `didUpdateWidget` (lines 54-90). These are source facts, not an A/B measurement of a deduplicated-offset implementation. The VM samples cannot distinguish the first from the second offset call or isolate FlutterMap cache-hit/miss counts and projection/simplification execution time. No new tile-read, MVT-decode, submitted-part, vertex, or actually-painted-polygon counts were available; the previous counts in this document must not be attributed to this run.

**Incomplete z10 run.** The third through fifth z10 attempts produced no Flutter `Frame` or `GPURasterizer::Draw` events despite ADB input events and therefore are excluded, not counted as fast/zero-duration frames. A subsequent one-way swipe also produced zero frame events and the map image did not move. Android logcat then recorded a fatal **system Zygote** exception at 07:47:43 (`IllegalStateException: Invalid @IntRange(from = -1): -2` in `AppOpsManager$NoteOpEvent`); the app process and VM service disappeared. This is a concrete emulator/system failure during the session, not evidence that SuelosAR or the viewport filter caused it. The five-repetition z10 target and exact cache/content equivalence were not achieved.

**Decision.** No optimization was implemented. Although the duplicate offset calculation is a plausible, narrow candidate, changing it requires altering FlutterMap's painter rather than a safe app-level switch. The present inclusive samples do not quantify its exclusive cost, potential allocation savings, or frame-time effect; introducing a permanent fork for it would be premature. The minimum missing evidence is an instrumented, identical-camera/tile, warmed A/B measurement that separates first/second offset conversion, fill-path creation, border-path construction and draw-call CPU time, with UI/raster frames and cache activity for at least five valid repetitions at **both** z8 and z10. Preserve holes, fill/border order, selection, and visual equivalence in that comparison. No before/after improvement or percentage is claimed here. Only this report was edited; no dependency, GIS source, viewport filter, or PMTiles asset was changed.

## Duplicate-offset experiment: blocked before baseline (17 October 2026)

**Source inspection.** Installed FlutterMap 8.3.1 is the unchanged hosted dependency declared in `pubspec.yaml`; no `pubspec_overrides.yaml` existed. In `lib/src/layer/polygon_layer/painter.dart`, `drawIfVisible` computes `fillOffsets` from `projectedPolygon.points` and the current world `shift` at lines 362-368. The border branch recomputes offsets from the same points and shift at lines 424-429. `OffsetHelper.getOffsetsXY` in `lib/src/misc/offsets.dart` derives its world-width adjustment from the first point, then transforms every point using the camera scale, pixel origin, and shift. With `useAltRendering == false`, the first call receives no extra `holePoints`, so both returned exterior offset lists have the same values. `SolidPixelHiker` reads its input offsets without modifying them. Holes are converted and bordered separately afterward (painter lines 436-445); multipart pieces are separate projected polygons. Reusing the first exterior list for the border in this normal path therefore appears semantically safe without changing fill rules, ordering, joins, culling, simplification, or hit-testing.

That conclusion does **not** authorize an unconditional replacement: with alternate triangulated rendering, the first call may concatenate hole points, whereas the border call receives only exterior points. Passing the complete first list to the border would incorrectly connect the exterior and holes. Any experiment must either retain the original border conversion in that path or pass only the exterior prefix. Inverted filling and multi-world shifts have separate control flow and must remain unchanged.

**Attempted baseline.** `emulator-5554` remained connected and the installed beta profile app started with a new Dart VM service and running main isolate. However, repeated screenshots of the focused SuelosAR activity were entirely black after startup, while pressing Home produced a normal Android launcher screenshot. The app had not displayed the Córdoba map, so soil-polygon loading, z8/z10 camera coordinates, visible tile IDs, warm-up equivalence, and valid pan frames could not be confirmed. No baseline repetitions were accepted. The earlier session's fatal system Zygote exception is not attributed to this app without evidence; the cause of this black app surface was not established. A VM timeline containing frame events does not turn a black surface into a valid Córdoba rendering measurement.

| Variant | z8 valid reps | z10 valid reps | UI p50/p95 | Raster p50/p95 | Conversion/path timing |
|---|---:|---:|---|---|---|
| Hosted FlutterMap 8.3.1 baseline | 0 | 0 | unavailable | unavailable | unavailable |
| Temporary offset-reuse variant | not created | not created | unavailable | unavailable | unavailable |

**Decision and cleanup.** The required visible, fully loaded baseline could not be established, so the comparison stopped before creating a local FlutterMap copy, dependency override, or temporary instrumentation. There is no before/after improvement to report and no production optimization recommendation yet. The only file edited for this attempt is this existing report; the viewport filter, GIS source, PMTiles, dependencies, installed Pub cache, and pre-existing work remain unchanged. The next valid attempt should first restore a responsive beta profile map, log exact camera centers/zooms and tile IDs, then measure both variants with identical instrumentation and at least five valid warmed repetitions per zoom. If offset reuse proves negligible, measure border-path construction next; the current inclusive samples cannot rank it against fill-path construction by exclusive time.

## Requested temporary offset-reuse A/B: emulator disconnected before baseline (17 October 2026)

On `beta`, the working-tree diff and hosted `flutter_map: 8.3.1` dependency were inspected first. The viewport filter in `lib/gis/gis_map_screen.dart` remained enabled; its SHA-256 before the attempted measurement was `656464E451F205679F8DB8979279AAAA4A2E1729A104527A8F4C5CBEAFFCF305`. The pre-existing modifications and untracked `witch beta` were preserved. No `pubspec_overrides.yaml` existed.

`adb devices -l` initially reported `emulator-5554` connected, and the beta application process (`ar.com.suelosar.beta`, PID 29563) was the resumed activity. During the **first baseline screenshot**, ADB returned `device 'emulator-5554' not found`; the subsequent ADB check listed no devices, and Windows listed no emulator or QEMU process. The screenshot was not captured. The previously observed black-screen condition was not investigated, because the current blocker was loss of the emulator itself. There is no evidence in this attempt identifying why it exited.

| Variant | z8 valid repetitions | z10 valid repetitions | Camera / tile IDs | UI p50/p95 | Raster p50/p95 |
|---|---:|---:|---|---|---|
| Original hosted FlutterMap baseline | 0 / 5 | 0 / 5 | unavailable | unavailable | unavailable |
| Temporary offset-reuse variant | not created | not created | unavailable | unavailable | unavailable |

Per the experiment's stop rule, no renderer, Pub cache, dependency configuration, source data, or instrumentation was changed. There is no measured before/after result, no visual-equivalence claim, and no basis to keep an optimization. The only new project edit is this report section; focused tests and analysis were not run because there was no code change or executable variant to validate. `git diff --check` is the applicable repository check. A future retry requires a connected profile-mode emulator with fully loaded Córdoba polygons **before** constructing the experimental dependency copy.

## Temporary offset-reuse experiment: baseline saved before renderer change

This new attempt used the running `emulator-5554` (Pixel Tablet, Android API 35, 1080 x 1920 physical pixels). Its previously installed beta `1.5.1-beta` lacked Córdoba, so the already-built, current `app-beta-profile.apk` (beta `1.6.0`, versionCode 19) was installed over it with `adb install -r -t`, preserving app data. The app's profile VM service and screenshots confirmed fully visible Córdoba soil polygons at z8 and z10. The hosted FlutterMap 8.3.1 renderer and Córdoba viewport filter were unchanged for these baseline runs.

The z8 starting camera was latitude `-32.4016453889117`, longitude `-63.3050087520058`, zoom 8. Its visible tile map contained `8/82/150-153` and `8/83/150-153`. After five warmed round-trip gestures, longitude was `-63.3308151790206`. At z10, the camera started at latitude `-32.4016453889117`, longitude `-63.3308151790206`, zoom 10, with visible tiles `10/331/608-610` and `10/332/608-610`. It stabilized near longitude `-63.331513` during measurement. These are live VM heap readings, not inferred from screenshots. The physical viewport stayed 1080 x 1920; FlutterMap's logical camera size was approximately 411.43 x 731.43.

Each repetition warmed the view with a 600 ms horizontal swipe `(680,1000) -> (480,1000)` and its reverse, settled 300 ms, cleared the profile VM timeline, repeated the same swipe pair, and settled 450 ms. `Frame` begin/end and `GPURasterizer::Draw` begin/end events were paired by thread and timestamp. The values below are **per-repetition percentiles**, in milliseconds; all ten repetitions returned matched UI/raster frame counts. No CPU sampler or stage-level instrumentation was enabled in this baseline.

| Zoom | Rep | End camera latitude, longitude (approx.) | UI frames | UI p50 | UI p95 | Raster frames | Raster p50 | Raster p95 |
|---:|---:|---|---:|---:|---:|---:|---:|---:|
| 8 | 1 | -32.401645, -63.326632 | 17 | 51.35 | 84.11 | 17 | 61.09 | 66.60 |
| 8 | 2 | -32.401645, -63.327329 | 17 | 61.90 | 82.26 | 17 | 65.88 | 90.22 |
| 8 | 3 | -32.401645, -63.327329 | 18 | 48.86 | 85.07 | 18 | 62.72 | 71.16 |
| 8 | 4 | -32.401645, -63.330118 | 16 | 83.94 | 89.20 | 16 | 64.96 | 68.57 |
| 8 | 5 | -32.401645, -63.330815 | 16 | 52.42 | 88.59 | 16 | 65.43 | 73.82 |
| 10 | 1 | -32.401645, -63.331338 | 24 | 32.78 | 71.96 | 24 | 45.93 | 50.09 |
| 10 | 2 | -32.401645, -63.331513 | 21 | 33.52 | 75.70 | 21 | 48.77 | 66.10 |
| 10 | 3 | -32.401645, -63.331513 | 22 | 33.19 | 74.90 | 22 | 48.01 | 51.59 |
| 10 | 4 | -32.401645, -63.331513 | 22 | 33.93 | 75.50 | 22 | 48.53 | 58.47 |
| 10 | 5 | -32.401645, -63.331513 | 22 | 33.65 | 76.53 | 22 | 49.61 | 54.00 |

Median of repetition-level values: z8 UI p50/p95 `52.42/85.07`, raster p50/p95 `64.96/71.16`; z10 UI `33.52/75.50`, raster `48.53/54.00`. The fourth z8 UI p50 (83.94 ms) is a valid slow run, not discarded. This baseline is saved **before** any renderer experiment. It does not itself quantify the second conversion, and matching the exact z8 camera/tiles after installing another APK remains a required comparability check.

### Temporary variant, comparison, and decision

The only experimental source change was in an isolated copy of FlutterMap 8.3.1 outside the repository: when `polygonTriangles == null`, `_PolygonPainter.drawIfVisible` passed the already-computed `fillOffsets` to `addBorderToPath` instead of calling `getOffsetsXY` a second time. The original second conversion remained for alternate triangulated rendering, where the first list may also contain hole points. The app's own `PolygonLayer` leaves `useAltRendering` at its default `false`; hole rings, multipart ordering, clipping, simplification, fill rule, and hit-testing code were untouched. No Pub-cache file was edited. A temporary `pubspec_overrides.yaml` pointed to that copy; `flutter pub get --offline` and `flutter build apk --profile --flavor beta --dart-define-from-file=.vscode/supabase.env.json --no-pub` succeeded. The resulting profile APK installed with `adb install -r -t` without clearing app data.

The same 1080 x 1920 emulator, swipe coordinates/durations, warm-up, timeline pairing, and five-repetition procedure were used. Córdoba soil polygons were visible in screenshots before both variant zoom runs. The z8 variant camera began at `-32.397418, -63.314556` after a manual alignment swipe, compared with baseline `-32.401645, -63.305009`: residual differences were about `0.00423` latitude and `0.00955` longitude. Both had the same eight visible tile IDs (`8/82-83/150-153`). At z10, variant camera began at `-32.397418, -63.320135`, compared with baseline `-32.401645, -63.330815`; both had the same six tile IDs (`10/331-332/608-610`). The cameras therefore remained **nearby but not identical** (roughly a kilometre apart), and exact cache contents were not verified. Baseline ran before variant rather than alternating because switching required a 541 MB rebuild/install. These limitations prevent a strict causal performance claim from the percentages below.

| Zoom | Rep | End camera latitude, longitude (approx.) | UI frames | UI p50 | UI p95 | Raster frames | Raster p50 | Raster p95 |
|---:|---:|---|---:|---:|---:|---:|---:|---:|
| 8 | 1 | -32.397418, -63.314556 | 16 | 74.19 | 82.89 | 16 | 65.12 | 69.57 |
| 8 | 2 | -32.397418, -63.315253 | 16 | 52.49 | 86.56 | 16 | 63.16 | 75.31 |
| 8 | 3 | -32.397418, -63.315253 | 17 | 60.06 | 92.11 | 17 | 64.94 | 70.32 |
| 8 | 4 | -32.397418, -63.315950 | 18 | 50.42 | 93.48 | 18 | 62.42 | 68.91 |
| 8 | 5 | -32.397418, -63.320135 | 15 | 61.95 | 89.10 | 15 | 64.03 | 75.38 |
| 10 | 1 | -32.397418, -63.320135 | 25 | 31.97 | 38.36 | 25 | 48.37 | 53.10 |
| 10 | 2 | -32.397418, -63.320135 | 25 | 31.19 | 39.08 | 25 | 45.46 | 50.09 |
| 10 | 3 | -32.397418, -63.318915 | 24 | 31.57 | 72.16 | 24 | 47.05 | 50.38 |
| 10 | 4 | -32.397418, -63.319089 | 22 | 32.92 | 74.02 | 22 | 49.62 | 53.56 |
| 10 | 5 | -32.397418, -63.319089 | 22 | 33.65 | 73.10 | 22 | 45.30 | 51.09 |

No repetitions were discarded: all ten variant passes had matched UI/raster frame pairs. Values below are medians of the five repetition-level percentiles, **variant relative to baseline**, not pooled-frame statistics:

| Zoom | UI p50 baseline / variant | UI p95 baseline / variant | Raster p50 baseline / variant | Raster p95 baseline / variant |
|---:|---:|---:|---:|---:|
| 8 | 52.42 / 60.06 ms (+14.6%) | 85.07 / 89.10 ms (+4.7%) | 64.96 / 64.03 ms (-1.4%) | 71.16 / 70.32 ms (-1.2%) |
| 10 | 33.52 / 31.97 ms (-4.6%) | 75.50 / 72.16 ms (-4.4%) | 48.53 / 47.05 ms (-3.0%) | 54.00 / 51.09 ms (-5.4%) |

The variant did not show a repeatable, meaningful improvement across zooms: z8 UI median worsened, while z10 changes were small relative to variation and camera/cache uncertainty. Fewer conversions in source are not evidence of exclusive stage-time savings. No per-stage Stopwatch instrumentation was added because it would perturb this high-frequency path; inclusive CPU samples from the prior investigation cannot supply exclusive conversion, path-building, or GPU durations for this A/B. Native raster time remains separate from Dart paint work.

Static screenshots showed exterior boundaries, fills, small units, and viewport-edge geometry in both variants, without a persistent gap or obvious border misalignment at the sampled views. In the variant, tapping a Córdoba polygon selected and highlighted several visible fragments and opened its information card, confirming one hit-test/selection path. These spot checks do not prove pixel-identical holes, all multipart cases, or label stability under every interaction; camera mismatch also prevents image differencing. Focused Córdoba tests passed (29 tests) with the temporary dependency, and targeted `flutter analyze` reported no issues.

**Decision: revert the experiment, retain the hosted renderer.** The temporary override was deleted, `flutter pub get --offline` restored FlutterMap 8.3.1 from the hosted Pub cache, and the `pubspec.lock`, `.dart_tool/package_config.json`, and `.flutter-plugins-dependencies` SHA-256 values matched their pre-experiment values. The original baseline APK was restored byte-for-byte in `build/app/outputs/flutter-apk/`, reinstalled with `adb install -r -t` (`Success`), and launched without clearing data. The isolated local FlutterMap copy and APK backup were removed after verifying their resolved path was under the intended Temp directory. The Córdoba viewport filter and all pre-existing source changes remain untouched. Only this existing report was edited for the final result; no production optimization, dependency override, or instrumentation remains. A more conclusive offset A/B would require exact camera restoration, identical loaded/cached geometry, variant-order control, and an instrumented measurement of the *second* conversion's exclusive CPU time. Given these results, separately measuring border-path construction is a more promising next diagnostic target than keeping offset reuse.
