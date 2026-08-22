# Compila el APK de release de un flavor de Android asegurando que la
# configuracion de Supabase (SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY) se
# incluya siempre. `flutter build apk --release` sin
# --dart-define-from-file compila igual, sin error, pero deja la app sin
# sincronizacion ("Servicio no esta configurado").
#
# Uso:
#   powershell -File scripts/build_android_release.ps1 -Flavor prod
#   powershell -File scripts/build_android_release.ps1 -Flavor beta

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("prod", "beta")]
    [string]$Flavor
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $repoRoot ".vscode\supabase.env.json"

if (-not (Test-Path $envFile)) {
    Write-Error "No se encontro $envFile. Copia .vscode/supabase.env.example.json y completa SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY antes de compilar un release."
    exit 1
}

Push-Location $repoRoot
try {
    flutter build apk --release --flavor $Flavor "--dart-define-from-file=.vscode/supabase.env.json"
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}
finally {
    Pop-Location
}
