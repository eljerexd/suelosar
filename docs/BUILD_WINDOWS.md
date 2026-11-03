# Compilacion Windows Release

La compilacion Release de SuelosAR requiere las variables locales de Supabase
desde `.vscode/supabase.env.json`. No se debe compilar para Windows Release sin
pasar ese archivo a Flutter. El script no lee ni muestra su contenido, y el
archivo no se distribuye como un recurso independiente.

## Procedimiento oficial

Desde la raiz del repositorio, ejecutar:

```powershell
powershell -ExecutionPolicy Bypass -File tool/build_windows_release.ps1
```

El script tambien puede invocarse desde otro directorio: determina la raiz a
partir de su propia ubicacion, comprueba Flutter y el archivo de entorno, y
ejecuta exactamente:

```powershell
flutter build windows --release --dart-define-from-file=.vscode/supabase.env.json
```

En VS Code se puede usar la tarea **SuelosAR: Build Windows Release**.

Para comprobar las rutas y el comando sin iniciar una compilacion:

```powershell
powershell -ExecutionPolicy Bypass -File tool/build_windows_release.ps1 -DryRun
```

El `-DryRun` sigue exigiendo que Flutter y `.vscode/supabase.env.json` existan,
pero no invoca Flutter ni compila. Si falta el archivo de entorno, el script
falla antes de compilar; no se debe generar una compilacion incompleta como
alternativa. El archivo es local: no modificarlo automaticamente, no mostrar
ni copiar sus valores a logs, y no incluirlo en commits, releases o instaladores
como archivo independiente. No reemplazar sus valores por datos ficticios.

## Salida de Flutter

El ejecutable de Release se genera en:

`build/windows/x64/runner/Release/suelosar.exe`

El script informa la ruta y comprueba que el archivo exista tras un codigo de
salida exitoso de Flutter. No ejecuta `flutter clean`, no elimina salidas
anteriores ni cambia configuraciones globales.

## Instalador Inno Setup

Primero generar el binario Release con el procedimiento oficial anterior. Solo
despues, con Inno Setup instalado, crear el instalador mediante el wrapper
existente:

```powershell
powershell -ExecutionPolicy Bypass -File tool/build_windows_installer.ps1
```

Este wrapper empaqueta el contenido de
`build/windows/x64/runner/Release` y deja el instalador en
`artifacts/windows-installer`. No usarlo para distribuir un directorio Release
que no haya sido generado con `--dart-define-from-file=.vscode/supabase.env.json`.
