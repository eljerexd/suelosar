# F5 / `flutter run` for the beta flavor hits the exact same Gradle bug
# documented in scripts/build_android_release.ps1: the
# `merge<Flavor><BuildType>JniLibFolders` task can report UP-TO-DATE even
# when its own input (the freshly recompiled app.so copied by
# copyJniLibsflutterBuild<Flavor><BuildType>) has genuinely changed -
# confirmed the same way, tracing SHA-256/content through Flutter output ->
# merged_jni_libs -> merged_native_libs -> stripped_native_libs -> the
# installed APK. Everything after that task just inherits and repackages
# its stale output.
#
# This is the DEBUG-variant counterpart of that fix, kept as a separate
# script (not merged into build_android_release.ps1) because F5/`flutter
# run` is a different invocation path than the release build script and
# should not be forced to go through it. It only deletes the same four
# categories of *regenerable* build output used by the release fix, scoped
# to the Debug variant - nothing persistent (.gradle/, .pub-cache,
# .dart_tool/package_config.json) is touched, and android/prod is
# unaffected unless you pass -Flavor prod.
#
# Wired up as a VS Code preLaunchTask on "SuelosAR Beta (MapLibre)" in
# .vscode/launch.json, so F5 always runs this first. Also safe to run by
# hand before `flutter run --flavor beta ...`:
#   powershell -File scripts/invalidate_debug_build_cache.ps1 -Flavor beta

param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("prod", "beta")]
    [string]$Flavor = "beta"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$flavorVariant = ($Flavor.Substring(0,1).ToUpper() + $Flavor.Substring(1) + "Debug")

foreach ($relativePath in @(
    "build\app\intermediates\flutter\$flavorVariant",
    "build\app\intermediates\merged_jni_libs\$flavorVariant",
    "build\app\intermediates\incremental\merge$($flavorVariant)JniLibFolders",
    "build\app\intermediates\merged_native_libs\$flavorVariant",
    "build\app\intermediates\stripped_native_libs\$flavorVariant",
    "build\app\outputs\apk\$Flavor\debug"
)) {
    $path = Join-Path $repoRoot $relativePath
    if (Test-Path $path) {
        Remove-Item -Recurse -Force $path
    }
}
