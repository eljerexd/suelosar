# Windows update infrastructure (Phase 1)

The updater uses two repositories with separate responsibilities:

- `eljerexd/suelosar` is the main SuelosAR source-code repository, where
  application development and source-code tags are maintained.
- `eljerexd/Web-SuelosAR` is the Windows distribution repository. Its GitHub
  Releases host installer assets and SHA-256 checksums.

The service and Windows UI integration are described in this document and
`WINDOWS_UPDATE_PHASE2A.md`. Results and errors are typed in
`windows_update_models.dart`. Web uses a stub; the IO implementation returns
`unsupportedPlatform` outside Windows.

## Release discovery and versioning

The service queries the stable-release API in the Windows distribution
repository, not the source-code repository's tags page or releases:

`https://api.github.com/repos/eljerexd/Web-SuelosAR/releases/latest`

It validates published, non-draft, non-prerelease metadata and compares parsed
SemVer major, minor, patch, then prerelease precedence. Flutter build metadata
(for example `+20`) does not affect precedence. A higher patch release is an
update just like a higher minor or major release.

The only eligible installer is the unique asset named exactly
`SuelosAR-Setup-<major>.<minor>.<patch>.exe`, matching the version in the stable
release tag. Its HTTPS URL must be the matching
`github.com/eljerexd/Web-SuelosAR/releases/download/<tag>/<filename>` asset.
Only assets published on a matching release in `Web-SuelosAR` are eligible;
source-code repository tags and releases do not provide Windows updater
metadata or installer assets.
The authoritative script is preserved at `SetupSuelosAR.iss`. It retains
AppId `{C7098677-ADDE-4FE4-A0FA-E24AC63B3CD0}` and sets
`OutputBaseFilename=SuelosAR-Setup-{#MyAppVersion}`. `pubspec.yaml` is the
single maintained version definition. `tool/build_windows_installer.ps1`
extracts its stable `major.minor.patch+build` value and supplies the
major/minor/patch as the `SUELOSAR_VERSION` environment variable. The `.iss`
fails preprocessing when compiled without that value. This means the current
`1.7.0+20` project version yields `SuelosAR-Setup-1.7.0.exe`, exactly the name
the updater accepts for release tag `v1.7.0`. The project root is resolved from
the location of `SetupSuelosAR.iss`; the Release files, `app_icon.ico`, and
installer output directory are all project-relative. No checkout-specific
path needs to be edited in the script.

To package an already-built Windows Release from any working directory, run:

```powershell
powershell -ExecutionPolicy Bypass -File "<checkout>\tool\build_windows_installer.ps1"
```

The wrapper requires `build\windows\x64\runner\Release\suelosar.exe`, a
nonempty Release output directory, `windows\runner\resources\app_icon.ico`,
and Inno Setup `ISCC.exe`. If ISCC is not on `PATH`, pass its full path with
`-IsccPath`. It checks required inputs before invoking the compiler and writes
the installer to `artifacts\windows-installer`. It packages the existing
Flutter Release output; it does not build the application. This task did not
compile an installer.

## Integrity and download

Prefer GitHub asset metadata `digest: "sha256:<64 hex chars>"`. Otherwise
publish a same-release sidecar named exactly `<installer-name>.sha256` containing
the SHA-256 and, optionally, that exact installer filename. The downloader
streams to a unique OS temporary directory, reports actual bytes, supports
cancellation, checks the published size when available, calculates SHA-256,
and only renames the complete verified `.part` file. Failures remove temporary
partial data. Redirects are followed manually and HTTPS is required at every
hop. No credentials or application-folder writes are used.

## Installer lifecycle and Phase 2

The script explicitly sets `CloseApplications=yes`; `RestartApplications` is
omitted and therefore defaults to `yes`. Per Inno Setup, an interactive setup
uses Restart Manager to detect processes holding files being updated, then asks
whether Setup may close them and restart them. In silent mode it closes and
restarts affected applications automatically unless command-line overrides say
otherwise. For automatic restart after installation, the application must call
Windows `RegisterApplicationRestart`; this repository has no such call, so do
not promise that Inno will restart SuelosAR automatically. The `[Run]` entry is
`postinstall nowait skipifsilent`; an additional `Check` suppresses this entry
for helper-driven updates and when the VC++ prerequisite requires a reboot.
For a normal interactive setup, the finish page offers an optional app launch;
`nowait` means Setup does not wait for that process. In silent mode the entry is
skipped. The updater launches without silent switches, so the intended route
is interactive. The script omits `PrivilegesRequired`, whose Inno default is
`admin`, so elevation is requested when required.

`downloadUpdate()` accepts only the latest check-result object issued by that
same service instance; callers cannot construct an arbitrary URL and supply
their own digest to authorize a download. Downloaded bytes are size-checked
when possible and SHA-256 verified before the `.exe` is registered. On Windows,
installer launch also requires the bundled helper to exist and have a valid PE
header; the service rechecks the digest immediately before starting it. The
helper is copied to a temporary directory outside the installation folder,
validates the installer path/name/hash and installed AppId, waits for SuelosAR
to exit, then starts normal interactive Inno Setup. After Setup exits it checks
the installed executable version, restarts the app, and writes a one-time
confirmation marker only for the expected successful version. The app consumes
that marker after restart and independently checks its installed package version
before displaying success. Failure or cancellation restarts without a success
marker. Cleanup of the temporary installer/helper directory is best-effort if
Windows still holds a file open.

This lifecycle passed the recorded Windows Sandbox 1.6.0-to-1.7.0 test in
`docs/RESULTADO_E2E_ACTUALIZADOR.md`. That evidence does not validate a separate
host UAC prompt or a visible interactive desktop in Sandbox. Inno's
`RestartApplications` default remains `yes`, but the helper owns the explicit
SuelosAR restart sequence because the app does not register with
`RegisterApplicationRestart`. The normal user-launched Setup still uses Inno's
interactive finish-page launch behavior. Focused tests use mocked services for
the app-side state and marker checks; they do not replace the Sandbox evidence.

Inno lifecycle references: [CloseApplications](https://jrsoftware.org/ishelp/topic_setup_closeapplications.htm),
[RestartApplications](https://jrsoftware.org/ishelp/topic_setup_restartapplications.htm),
[Run section](https://jrsoftware.org/ishelp/topic_runsection.htm).

## Phase 1 integration follow-up

The installer filename/version contract is now tied to the Flutter version:
the installer build wrapper reads `pubspec.yaml`, injects `SUELOSAR_VERSION`,
and the Inno script refuses to preprocess without it. A targeted test reads
the same project version, checks the preserved AppId and Inno output-name
macro, then verifies that the updater accepts the exact corresponding stable
release asset name. The installed Inno compiler's preprocess-only mode produced
`OutputBaseFilename=SuelosAR-Setup-1.7.0` for project version `1.7.0+20`.

Verification history: focused service, controller, preview, indicator,
confirmation, and installation-helper tests accompany the current
implementation. Re-run the focused updater tests before creating a release
installer. The release asset and its checksum are maintained separately in
`eljerexd/Web-SuelosAR`; changing this source repository does not publish or
replace them.

## Full-suite audit caveat

The full Flutter test run recorded the following 12 failures. Their test files
are outside the updater changes, but no clean pre-change full-suite run was
captured; therefore these are **not certified as pre-existing**. No updater
logic regression is indicated by their failure paths, and the updater's own
focused tests pass, but each item remains a current repository test failure
until independently resolved:

| Test | Observed failure |
| --- | --- |
| `generic optimizer removes attributes outside the schema and verifies every tile` | Expected retained `FASE1`; actual attribute set only contained `taxo_ppal`. |
| `publication a valid archive is published with its sidecar and metadata` | Actual publication schema contained `FASE1`, absent from expected schema. |
| `GIS map search returns the selected feature internally` | Expected one `Arroyo Dulce` widget; found two. |
| `GIS map measures and clears a two-point distance` | Expected `Unidad medida`; none found. |
| `GIS map search includes and ranks unit symbols` | Expected `Complejo Junín 18`; none found. |
| `GIS search groups results and orders series units` | Expected `Unidad C`; none found. |
| `GIS bottom sheet toggles and persists a favorite feature` | Selected map unit did not open its detail card within 2 seconds. |
| `Córdoba 1:500,000 displays available taxonomy fields` | Expected two `No hay series disponibles.` labels; none found. |
| `Buenos Aires title omits type and the series composition` | `pumpAndSettle` timed out during map-result selection. |
| `Santa Fe MLA-04 resolves each source series and its memory` | Expected three `Abrir PDF` labels; none found. |
| `GIS favorite reuses search centering and selection workflow` | Expected `Unidad favorita`; none found. |
| `GIS map search recenters on consecutive selections` | Selected map unit did not open its detail card within 2 seconds. |

The two `phase2_test.dart` failures reproduced when that file was rerun alone;
three map-search failures reproduced in an isolated name-filtered widget run.
The original JSON run log is in the user's temporary directory, outside the
repository: `%TEMP%\\suelosar-full-test-audit.json`.
