param(
    [string]$PackageName = "ar.com.suelosar"
)

$ErrorActionPreference = "Stop"

$adb = Get-Command adb -ErrorAction SilentlyContinue
if ($null -eq $adb) {
    $fallback = Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\adb.exe"
    if (-not (Test-Path -LiteralPath $fallback)) {
        throw "adb was not found. Install Android platform-tools or add adb to PATH."
    }
    $adbPath = $fallback
} else {
    $adbPath = $adb.Source
}

& $adbPath get-state | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "No Android device is connected."
}

$runAsOutput = & $adbPath shell run-as $PackageName pwd 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "The installed $PackageName application is not a debug build: $runAsOutput"
}

& $adbPath shell setprop debug.firebase.analytics.app $PackageName
& $adbPath shell setprop log.tag.FA VERBOSE
& $adbPath shell setprop log.tag.FA-SVC VERBOSE
& $adbPath logcat -c

Write-Host "Firebase Analytics debug logging enabled for $PackageName."
Write-Host "Use SuelosAR normally. Press Ctrl+C to stop."

try {
    & $adbPath logcat -v brief FA:V FA-SVC:V '*:S' | ForEach-Object {
        $line = $_
        $eventName = $null
        if ($line -match 'Logging event \(FE\):\s*origin=[^,]+,name=([^,]+),') {
            $eventName = $Matches[1]
        } elseif ($line -match 'Logging event \(FE\):\s*([^,\s]+)') {
            $eventName = $Matches[1]
        }

        if ($null -ne $eventName) {
            Write-Host ""
            Write-Host "[Analytics]"
            Write-Host "Event: $eventName"
            if ($line -match 'duration_ms[=:]\s*([0-9]+)') {
                Write-Host "duration_ms=$($Matches[1])"
            }
            if ($line -match 'reason[=:]\s*([^,}\]]+)') {
                Write-Host "reason=$($Matches[1].Trim())"
            }
        }
    }
} finally {
    & $adbPath shell setprop debug.firebase.analytics.app .none.
    & $adbPath shell setprop log.tag.FA INFO
    & $adbPath shell setprop log.tag.FA-SVC INFO
}
