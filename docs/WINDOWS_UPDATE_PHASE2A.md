# Windows Update Indicator and Download Popup (Phase 2A)

The Windows-only main-menu update indicator is backed by one
`WindowsUpdateIndicatorController`. `SuelosARApp` owns the controller, starts
its initialization without blocking the menu, and hosts the independent
download popup above the navigator. The indicator and popup observe the same
controller; there is no second download manager or copied progress state.

Selecting an available update opens the availability dialog. Choosing
`Descargar` pops that dialog first; after the dialog route returns, the screen
starts the controller's download operation. Progress is shown in the independent
popup anchored below the indicator. Tapping the indicator while a download
popup exists minimizes or reopens it. The popup displays determinate or
indeterminate progress, percentage, downloaded/total bytes, speed when
available, cancellation, completion, and error states.

The controller restores the last status and release snapshot from
`SharedPreferences`. It records attempted and successful check times and runs
an automatic release check when due; manual checks bypass that interval and
concurrent checks are rejected. A failed automatic check retains a known
available release, while a failure with no known update exposes the offline
state. A restored release snapshot is informational and is not itself download
authorization. A download requires a matching `WindowsUpdateCheckResult` with
an installer and checksum, issued by the same `WindowsUpdateService` instance;
the service rejects a result it did not issue. This is an in-process result and
identity validation, not a fresh server-side eligibility check when the dialog
opens or the download button is pressed.

The real Windows service can download to a temporary file, report byte
progress, cancel and remove partial files, verify the expected size and
SHA-256, and retain only the completed verified installer. Automatic installer
execution is deliberately unavailable: `launchInstaller()` returns
`lifecycleUnavailable` until the Windows install/close/restart lifecycle is
validated. Therefore this implementation supports update detection and verified
downloading, not complete automatic installation.

The optional preview is enabled only in debug builds with
`--dart-define=SUelosAR_UPDATE_PREVIEW=true`. It uses a development controller
and deterministic simulated progress; it makes no GitHub request, downloads no
file, and does not validate production transfer or installation behavior.

`UpdateFeedbackPresenter` and `UpdateFeedbackNotification` currently have
standalone implementations and widget tests but no observable application
call-site, so their transient feedback is not part of the active updater flow.
`WindowsUpdatePreviewDialog` is currently only a re-export of the availability
dialog and is also not integrated. Treat these files as unintegrated/experimental
until they are either connected in a separately reviewed change or explicitly
excluded from the feature scope.

Focused tests cover the controller, status indicator, availability dialog,
preview flow, popup progress and cancellation, and the service download,
checksum, and failure paths. Tests use mocked preferences and network responses;
they do not execute a real installer or validate the Windows installer
lifecycle.
