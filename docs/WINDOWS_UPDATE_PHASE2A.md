# Windows Update Indicator and Download Popup (Phase 2A)

The Windows-only main-menu update indicator is backed by one
`WindowsUpdateIndicatorController`. `SuelosARApp` owns the controller, starts
its initialization without blocking the menu, and hosts the independent
download popup above the navigator. The indicator and popup observe the same
controller; there is no second download manager or copied progress state.

Repository roles are separate: `eljerexd/suelosar` contains application source
and source-code tags, while `eljerexd/Web-SuelosAR` is the Windows distribution
repository queried for stable GitHub Releases, installer assets, and checksums.

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
SHA-256, and retain only the completed verified installer. On Windows it can
start the bundled `suelosar_update_helper.exe` only after confirming that the
helper exists, has a PE header, and the installer is still registered as
verified; the installer digest is rechecked before launch. The helper runs
outside the install directory, waits for the app to close, starts interactive
Inno Setup, verifies the installed executable version, then restarts SuelosAR.
A single-use marker is written only after a successful install with the
expected version; on restart, the app consumes the marker and checks its actual
package version before showing the success dialog. Failure/cancellation do not
produce success confirmation. The helper removes its temporary update files
after the restart path where Windows permits cleanup.

The recorded Sandbox test validated the 1.6.0-to-1.7.0 path; its evidence and
limits are documented in `RESULTADO_E2E_ACTUALIZADOR.md`. In particular, the
Sandbox run did not provide a separately observed host UAC prompt or an
interactive graphical desktop. The lifecycle is not described as host-UAC or
visual-Sandbox validated.

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
preview flow, popup progress and cancellation, confirmation-marker validation,
and service download/checksum/failure paths. Most use mocked preferences and
network responses; the separate Sandbox report records the installer lifecycle
trial. The optional live TLS test runs only when explicitly enabled.
