param(
    [string]$IsccPath,
    [string]$OutputDir,
    [string]$BuildDir
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pubspecPath = Join-Path $projectRoot 'pubspec.yaml'
$setupPath = Join-Path $projectRoot 'SetupSuelosAR.iss'
$defaultBuildDir = Join-Path $projectRoot 'build\windows\x64\runner\Release'
if (-not $BuildDir) {
    $BuildDir = $defaultBuildDir
}
$BuildDir = [IO.Path]::GetFullPath($BuildDir)
$buildDir = $BuildDir
$appExe = Join-Path $buildDir 'suelosar.exe'
$updateHelper = Join-Path $buildDir 'suelosar_update_helper.exe'
$iconPath = Join-Path $projectRoot 'windows\runner\resources\app_icon.ico'
$vcRedistPath = Join-Path $projectRoot 'tool\prerequisites\vc_redist.x64.exe'
$defaultOutputDir = Join-Path $projectRoot 'artifacts\windows-installer'
if (-not $OutputDir) {
    $OutputDir = $defaultOutputDir
}
$OutputDir = [IO.Path]::GetFullPath($OutputDir)

foreach ($requiredFile in @($pubspecPath, $setupPath, $appExe, $updateHelper, $iconPath, $vcRedistPath)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required installer input is missing: $requiredFile"
    }
}

$helperStream = [IO.File]::OpenRead($updateHelper)
try {
    $helperHeader = New-Object byte[] 2
    if ($helperStream.Read($helperHeader, 0, 2) -ne 2 -or
        $helperHeader[0] -ne 0x4D -or $helperHeader[1] -ne 0x5A) {
        throw "Installer helper is not a valid Windows executable: $updateHelper"
    }
}
finally {
    $helperStream.Dispose()
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

$setup = Get-Content -Raw -LiteralPath $setupPath
$runtimeRequirementMatch = [regex]::Match(
    $setup,
    '(?m)^#define VCRuntimeRequiredVersion "(?<version>\d+\.\d+\.\d+\.\d+)"\s*$'
)
if (-not $runtimeRequirementMatch.Success) {
    throw 'SetupSuelosAR.iss must define VCRuntimeRequiredVersion.'
}

$minimumRuntimeVersion = [version]$runtimeRequirementMatch.Groups['version'].Value
$bundledRuntimeVersion = [version](Get-Item -LiteralPath $vcRedistPath).VersionInfo.FileVersion
if ($bundledRuntimeVersion -lt $minimumRuntimeVersion) {
    throw "Bundled Visual C++ Redistributable $bundledRuntimeVersion is older than required $minimumRuntimeVersion."
}

$runtimeSignature = Get-AuthenticodeSignature -LiteralPath $vcRedistPath
if ($runtimeSignature.Status -ne 'Valid' -or
    $runtimeSignature.SignerCertificate.Subject -notlike 'CN=Microsoft Corporation,*') {
    throw 'The bundled Visual C++ Redistributable must have a valid Microsoft Corporation signature.'
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

$null = New-Item -ItemType Directory -Path $OutputDir -Force
$versionVariable = 'SUELOSAR_VERSION'
$buildDirVariable = 'SUELOSAR_BUILD_DIR'
$previousVersion = [Environment]::GetEnvironmentVariable($versionVariable, 'Process')
$previousBuildDir = [Environment]::GetEnvironmentVariable($buildDirVariable, 'Process')
Push-Location $projectRoot
try {
    [Environment]::SetEnvironmentVariable(
        $versionVariable,
        $versionMatch.Groups['version'].Value,
        'Process'
    )
    [Environment]::SetEnvironmentVariable($buildDirVariable, $BuildDir, 'Process')
    & $IsccPath "--output-dir=$OutputDir" $setupPath
    if ($LASTEXITCODE -ne 0) {
        throw "Inno Setup failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
    [Environment]::SetEnvironmentVariable($versionVariable, $previousVersion, 'Process')
    [Environment]::SetEnvironmentVariable($buildDirVariable, $previousBuildDir, 'Process')
}
