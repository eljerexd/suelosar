[CmdletBinding()]
param(
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

try {
    $projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $environmentFile = Join-Path $projectRoot '.vscode\supabase.env.json'

    if (-not (Test-Path -LiteralPath $environmentFile -PathType Leaf)) {
        throw "Required environment file is missing: $environmentFile. No build was started."
    }

    $flutterCommand = Get-Command 'flutter' -ErrorAction SilentlyContinue
    if (-not $flutterCommand) {
        throw 'Flutter was not found on PATH. Install/configure Flutter and retry.'
    }

    $flutterExecutable = if ($flutterCommand.Source) {
        $flutterCommand.Source
    } else {
        $flutterCommand.Name
    }
    $flutterArguments = @(
        'build',
        'windows',
        '--release',
        '--dart-define-from-file=.vscode/supabase.env.json'
    )

    Write-Host "Project root: $projectRoot"
    Write-Host 'Required environment file: present (contents not displayed).'
    Write-Host 'Command: flutter build windows --release --dart-define-from-file=.vscode/supabase.env.json'

    if ($DryRun) {
        Write-Host 'DryRun: Flutter was not invoked and no build was performed.'
        exit 0
    }

    Push-Location $projectRoot
    try {
        & $flutterExecutable @flutterArguments
        $flutterExitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if ($flutterExitCode -ne 0) {
        throw "Flutter Windows Release build failed with exit code $flutterExitCode."
    }

    $buildDirectory = 'build'
    $configOutput = & $flutterExecutable config --list
    if ($LASTEXITCODE -eq 0) {
        $configuredBuildDir = $configOutput |
            ForEach-Object {
                if ($_ -match '^\s*build-dir:\s*(?<path>.+?)\s*$') {
                    $Matches.path
                }
            } |
            Select-Object -First 1
        if ($configuredBuildDir) {
            $buildDirectory = $configuredBuildDir
        }
    }

    if ([IO.Path]::IsPathRooted($buildDirectory)) {
        throw "Flutter build directory must be project-relative: $buildDirectory"
    }

    $executablePath = Join-Path $projectRoot (Join-Path $buildDirectory 'windows\x64\runner\Release\suelosar.exe')
    if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
        throw "Flutter returned success, but the expected application executable was not found: $executablePath"
    }

    Write-Host "Windows Release build completed successfully: $executablePath"
    exit 0
}
catch {
    [Console]::Error.WriteLine("Windows Release build error: $($_.Exception.Message)")
    exit 1
}
