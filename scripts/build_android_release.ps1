# Compila el APK de release de un flavor de Android asegurando que la
# configuracion de Supabase (SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY) se
# incluya siempre. `flutter build apk --release` sin
# --dart-define-from-file compila igual, sin error, pero deja la app sin
# sincronizacion ("Servicio no esta configurado").
#
# Ademas invalida selectivamente cuatro directorios de build que pueden
# devolver un APK desactualizado con "SUCCESS" silencioso aunque el codigo
# Dart haya cambiado:
#   1. .dart_tool/flutter_build/
#      Cache de compilacion Dart de Flutter CLI.
#   2. build/app/intermediates/flutter/<Flavor>Release/
#      Staging + dependency tracking de la tarea FlutterTask de Gradle
#      (este proyecto redirige el buildDir de Gradle a build/, no usa
#      android/app/build/).
#   3. build/app/intermediates/merged_jni_libs/<Flavor>Release/
#      Output de la tarea `merge<Flavor>ReleaseJniLibFolders` - EL PUNTO
#      REAL donde se detecto la desincronizacion: esta tarea reportaba
#      UP-TO-DATE incluso cuando Gradle habia registrado explicitamente
#      (en el log -v) que su propio input (`app.so` copiado por
#      copyJniLibsflutterBuild<Flavor>Release) "has changed". Confirmado
#      trazando SHA-256 en cada etapa (Flutter output -> merged_jni_libs ->
#      merged_native_libs -> stripped_native_libs -> APK final): el primer
#      hash que no coincidia con el codigo fuente actual era el de esta
#      tarea; todo lo posterior solo hereda y propaga ese contenido viejo.
#      Ni desactivar el build cache de Gradle (-Dorg.gradle.caching=false)
#      ni correr sin daemon (--no-android-gradle-daemon) lo resolvian -
#      ninguno de los dos apunta al problema real, que es el historial de
#      up-to-date checking de ESTA tarea puntual.
#   4. build/app/intermediates/incremental/merge<Flavor>ReleaseJniLibFolders/
#      Historial incremental (snapshot de inputs) de esa misma tarea -
#      necesario borrarlo junto con su output (punto 3) para que Gradle no
#      tenga de donde recuperar el estado "up-to-date" incorrecto.
#
# Ninguno de los cuatro borra dependencias de pub ni cachés de Gradle/Kotlin
# de otros modulos (.gradle/, .pub-cache intactos), asi que esto agrega
# segundos, no minutos, a cada build - muy por debajo del costo de
# `flutter clean` (que ademas borra .dart_tool/package_config.json y fuerza
# un `pub get` completo).
#
# Despues del build, valida obligatoriamente que el APK resultante
# corresponda a ESTA corrida (no un artefacto viejo reusado) y muestra los
# datos necesarios para confirmar que se esta por instalar el build
# correcto.
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
    # --- Invalidacion selectiva de cache (ver nota arriba) ---------------
    $dartToolFlutterBuild = Join-Path $repoRoot ".dart_tool\flutter_build"
    if (Test-Path $dartToolFlutterBuild) {
        Remove-Item -Recurse -Force $dartToolFlutterBuild
    }

    $flavorVariant = ($Flavor.Substring(0,1).ToUpper() + $Flavor.Substring(1) + "Release")

    foreach ($relativePath in @(
        "build\app\intermediates\flutter\$flavorVariant",
        "build\app\intermediates\merged_jni_libs\$flavorVariant",
        "build\app\intermediates\incremental\merge$($flavorVariant)JniLibFolders",
        "build\app\intermediates\merged_native_libs\$flavorVariant",
        "build\app\intermediates\stripped_native_libs\$flavorVariant",
        "build\app\outputs\apk\$Flavor"
    )) {
        $path = Join-Path $repoRoot $relativePath
        if (Test-Path $path) {
            Remove-Item -Recurse -Force $path
        }
    }

    $buildStart = Get-Date

    flutter build apk --release --flavor $Flavor "--dart-define-from-file=.vscode/supabase.env.json"
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    # --- Validacion obligatoria post-build --------------------------------
    $apkPath = Join-Path $repoRoot "build\app\outputs\flutter-apk\app-$Flavor-release.apk"

    if (-not (Test-Path $apkPath)) {
        Write-Error "El build reporto exito pero no se encontro el APK esperado en $apkPath."
        exit 1
    }

    $apkFile = Get-Item $apkPath

    if ($apkFile.LastWriteTime -le $buildStart) {
        Write-Error (
            "El APK en $apkPath tiene fecha $($apkFile.LastWriteTime), anterior al " +
            "inicio de este build ($buildStart). Esto significa que se reutilizo un " +
            "artefacto desactualizado en vez de generarse uno nuevo - la invalidacion " +
            "de cache selectiva no fue suficiente esta vez."
        )
        exit 1
    }

    $sha256 = (Get-FileHash -Path $apkPath -Algorithm SHA256).Hash

    $versionLine = Select-String -Path (Join-Path $repoRoot "pubspec.yaml") -Pattern '^version:\s*(\S+)' | Select-Object -First 1
    $versionRaw = if ($versionLine) { $versionLine.Matches[0].Groups[1].Value } else { "desconocida" }
    $versionParts = $versionRaw -split '\+'
    $versionName = $versionParts[0]
    $versionCode = if ($versionParts.Length -gt 1) { $versionParts[1] } else { "desconocido" }
    if ($Flavor -eq "beta") { $versionName = "$versionName-beta" }

    Write-Host ""
    Write-Host "==================== BUILD VERIFICADO ====================" -ForegroundColor Green
    Write-Host "Flavor:        $Flavor"
    Write-Host "versionName:   $versionName"
    Write-Host "versionCode:   $versionCode"
    Write-Host "Ruta:          $apkPath"
    Write-Host "LastWriteTime: $($apkFile.LastWriteTime)  (build iniciado: $buildStart)"
    Write-Host "Tamano:        $([math]::Round($apkFile.Length / 1MB, 1)) MB ($($apkFile.Length) bytes)"
    Write-Host "SHA-256:       $sha256"
    Write-Host "============================================================" -ForegroundColor Green
}
finally {
    Pop-Location
}
