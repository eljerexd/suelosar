# Analytics and Crashlytics

## Architecture

Application code depends only on `AnalyticsService`. Firebase event names,
parameters, failure normalization, and SDK calls stay inside
`FirebaseAnalyticsService`. The implementation is registered once during
startup, after Firebase initialization.

Event calls are fire-and-forget. Callers use `unawaited`, the analytics service
silently absorbs SDK failures, and no analytics path performs synchronous disk
access. Analytics must never decide whether an application action succeeds.

## Event catalog

| Event | Trigger | Duplicate protection | Parameters |
| --- | --- | --- | --- |
| `app_open` | Once from `main` after Firebase initialization | One process entry point | None |
| `map_opened` | GIS screen `initState` | Never emitted from `build` or camera callbacks | None |
| `pdf_opened` | pdfrx `onViewerReady` | Per-viewer `_pdfOpenLogged` guard | None |
| `search` | Explicit submit or selection of a filtered GIS result | Never emitted by `onChanged` | None |
| `measure_area` | Successful persistence of a new area | Existing measurement edits are excluded | None |
| `measure_distance` | Successful persistence of a new distance | Existing measurement edits are excluded | None |
| `marker_created` | Successful persistence of a new marker | Edits and temporary placement are excluded | None |
| `favorite_added` | Successful favorite persistence | Removal is excluded | None |
| `gps_enabled` | Successful user location activation or enabling automatic follow | GPS stream updates are excluded | None |
| `sync_started` | Start of a serialized coordinator cycle | Concurrent requests share the active cycle | None |
| `sync_completed` | Successful end of that cycle | Mutually exclusive with `sync_failed` | `duration_ms` |
| `sync_failed` | Authentication or operational failure in that cycle | Mutually exclusive with `sync_completed` | `reason` |
| `feedback_opened` | External email client successfully opened | Failed launch attempts are excluded | None |

The only accepted `sync_failed.reason` values are `network`, `server`,
`authentication`, `timeout`, and `unknown`. Raw exceptions are never sent.

## Privacy guarantees

Custom events never include search text, coordinates, filenames, document
titles, email addresses, device or entity identifiers, user notes, marker
content, or other user-generated content. The automated contract test rejects
Firebase Analytics imports outside the implementation and rejects parameter
keys other than `duration_ms` and `reason`.

Firebase itself collects platform-level data according to its standard SDK
configuration. Review the Google Play Data safety declaration whenever the SDK
configuration changes.

## Adding an event safely

1. Add a canonical name to `analytics_events.dart`.
2. Add a strongly typed method to `AnalyticsService` and its inactive service.
3. Implement the method only in `FirebaseAnalyticsService`.
4. Emit it from a completed user action, never from `build`, animation, camera,
   text-change, or continuous stream callbacks.
5. Use `unawaited`; do not make application work wait for analytics.
6. Add only aggregate allowlisted parameters and update the contract tests.
7. Verify the event once in Firebase DebugView before release.

## Analytics debug logging on Android

Install and run a debug build, then start the repository tool in a second
PowerShell terminal:

```powershell
powershell -ExecutionPolicy Bypass -File tool/firebase_analytics_debug.ps1
```

The tool uses Firebase's Android debug mode and prints records as:

```text
[Analytics]
Event: sync_completed
duration_ms=1342
```

It first verifies the installed package with Android `run-as`; therefore it
refuses non-debuggable release builds. On exit it resets Firebase Analytics log
properties. Use the output together with Firebase Analytics DebugView to walk
through every event in the catalog exactly once.

## Crashlytics production verification

SuelosAR has no in-application crash-testing controls. Production reporting is
handled by the global `FlutterError.onError` and
`PlatformDispatcher.instance.onError` handlers installed during Firebase
startup. These paths report Flutter framework failures and uncaught
asynchronous failures as fatal events without exposing diagnostics in the UI.

For Android operational verification, enable native Crashlytics logging before
reproducing a real failure in a controlled test environment:

```powershell
adb shell setprop log.tag.FirebaseCrashlytics DEBUG
adb logcat -s FirebaseCrashlytics
```

Relaunch after a fatal crash, then look for HTTP status `204` or
`Crashlytics report upload complete` and confirm the report in the Firebase
Crashlytics dashboard. Reset verbose logging afterward:

```powershell
adb shell setprop log.tag.FirebaseCrashlytics INFO
```

The automated contract test protects both production handlers from accidental
removal.

References:

- https://firebase.google.com/docs/crashlytics/flutter/test-implementation
- https://firebase.google.com/docs/crashlytics/flutter/customize-crash-reports
- https://support.google.com/analytics/answer/9234069
