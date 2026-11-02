param(
    [string]$IsccPath
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pubspecPath = Join-Path $projectRoot 'pubspec.yaml'
$setupPath = Join-Path $projectRoot 'SetupSuelosAR.iss'
$buildDir = Join-Path $projectRoot 'build\windows\x64\runner\Release'
$appExe = Join-Path $buildDir 'suelosar.exe'
$iconPath = Join-Path $projectRoot 'windows\runner\resources\app_icon.ico'
$outputDir = Join-Path $projectRoot 'artifacts\windows-installer'

foreach ($requiredFile in @($pubspecPath, $setupPath, $appExe, $iconPath)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required installer input is missing: $requiredFile"
    }
}

if (-not (Get-ChildItem -LiteralPath $buildDir -File -Recurse | Select-Object -First 1)) {
    throw "Flutter Windows Release directory is empty: $buildDir"
}

$pubspec = Get-Content -Raw -LiteralPath $pubspecPath
$versionMatch = [regex]::Match(
    $pubspec,
    '(?m)^version:\s*(?<version>(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))\+\d+\s*$'
)

if (-not $versionMatch.Success) {
    throw 'pubspec.yaml must define a stable major.minor.patch+build version.'
}

if (-not $IsccPath) {
    $compiler = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
    if ($compiler) {
        $IsccPath = $compiler.Source
    }
}

if (-not $IsccPath -or -not (Test-Path -LiteralPath $IsccPath -PathType Leaf)) {
    throw 'Inno Setup ISCC.exe was not found. Pass its path with -IsccPath.'
}

$null = New-Item -ItemType Directory -Path $outputDir -Force
$versionVariable = 'SUELOSAR_VERSION'
$previousVersion = [Environment]::GetEnvironmentVariable($versionVariable, 'Process')
Push-Location $projectRoot
try {
    [Environment]::SetEnvironmentVariable(
        $versionVariable,
        $versionMatch.Groups['version'].Value,
        'Process'
    )
    & $IsccPath $setupPath
    if ($LASTEXITCODE -ne 0) {
        throw "Inno Setup failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
    [Environment]::SetEnvironmentVariable($versionVariable, $previousVersion, 'Process')
}
