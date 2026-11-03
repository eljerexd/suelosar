# Validación TLS y artefacto SuelosAR 1.7.0

Fecha de validación: 2026-11-02

Repositorio: `C:\Users\jerem\suelosar`

Rama/HEAD: `main` / `5ab4dbdce34cc022cfd4d476c86f44dd719c9f63`

## Resumen

La causa del fallo observado en la aplicación original 1.6.0 fue una falla de cadena de certificados en el transporte TLS de `dart:io`/BoringSSL dentro de Windows Sandbox (`CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate`). La ruta nueva para Windows usa `rhttp 0.18.0`, raíces de certificados del sistema y validación TLS habilitada. No se desactivó la validación del certificado ni la verificación de hostname.

La corrección fue probada dentro de Sandbox y el instalador corregido 1.7.0 quedó preparado localmente. No se modificaron los assets ni la release de GitHub. La publicación/reemplazo sigue pendiente de la acción manual del usuario.

## Evidencia TLS

La aplicación 1.6.0 original falló repetidamente al consultar `https://api.github.com/repos/eljerexd/Web-SuelosAR/releases/latest`; los registros `update-check-diagnostic.jsonl` guardan `HandshakeException` y `CERTIFICATE_VERIFY_FAILED`.

Después se instaló una compilación de prueba 1.6.0 basada en el código experimental de 1.6.0, conservando `1.6.0+10`, pero incorporando `rhttp`. Esta compilación era exclusivamente diagnóstica, con parámetros de prueba Sandbox y no es un artefacto distribuible. Desde ella, una petición real al endpoint público, con validación de certificados del sistema, terminó en 497 ms e interpretó `v1.7.0` como actualización disponible. También seleccionó `SuelosAR-Setup-1.7.0.exe` y el digest publicado `7fb370f5d9367c016bcdf8555c97bb46605e9ee42a72dfc88b4fded0aace9f65`.

En una instalación limpia posterior del Setup corregido 1.7.0, la aplicación volvió a consultar la release pública y persistió `last_status=upToDate`, `last_successful_at=2026-11-02T23:01:36.181156Z` y los metadatos reales de `v1.7.0`. El log de alto nivel no guarda el código HTTP crudo; el resultado exitoso y el JSON persistido prueban que la respuesta se recibió y procesó, pero no constituyen un registro de paquete con el status HTTP numérico.

**Compatibilidad:** la instalación pública original 1.6.0 no detecta automáticamente 1.7.0 en este entorno debido a TLS. La prueba con 1.6.0 corregida demuestra que el servicio nuevo sí consulta el release, pero no convierte a la instalación original 1.6.0 en compatible. Para un usuario con esa compilación antigua, la actualización inicial requiere instalar manualmente 1.7.0; luego el transporte corregido está disponible.

## Instalación limpia y dependencias nativas

El Setup final se instaló en un Sandbox nuevo. El instalador terminó con código `0`; Inno Setup registró instalación exitosa y sin reinicio requerido. El prerequisito oficial Microsoft Visual C++ Redistributable x64 se instaló correctamente: registro `Installed=1`, versión `v14.51.36247.00`. La app instalada informó `1.7.0+20` y `rhttp.dll` quedó junto a la aplicación en `C:\Program Files\SuelosAR\rhttp.dll`.

El proceso iniciado cargó `rhttp.dll` desde esa ruta de instalación. En la verificación de inicio se observaron procesos `suelosar.exe` respondiendo, ambos en sesión 0 porque el Sandbox no tenía una sesión de usuario activa. Las preferencias del proceso SYSTEM muestran la consulta exitosa `upToDate`.

**Limitación visual:** `ExistingLogin` devolvió `0x80070520` (“no existe una sesión de inicio especificada”). Por eso no se pudo verificar el menú en una sesión gráfica interactiva ni las funciones offline mediante interacción visual. El inicio del proceso, la carga de DLL, la lectura del estado persistido y la consulta del actualizador sí quedaron registrados. En el sondeo de esta instalación limpia aparecieron dos procesos, no uno; no se usa ese sondeo como afirmación de instancia única. En el flujo de actualización 1.6.0→1.7.0, en cambio, el registro final mostró una sola instancia.

## Suite de pruebas y análisis

- Tests focalizados del actualizador, indicador, preview, popover, notificación e instalación: `83` pasaron, `1` opt-in omitido. Comando con `--dart-define=SUelosAR_UPDATE_PREVIEW=true`: salida `0`.
- `windows_update_preview_mode_test.dart` con la bandera apagada: `2` pasaron, salida `0`.
- Una inconsistencia real de la matriz de tests se corrigió: el test “preview is disabled by default” fallaba al ejecutar correctamente los tests de UI con la bandera habilitada. Ahora comprueba el valor derivado de la configuración explícita de build.
- Suite completa: no se obtuvo un resultado final. La corrida predeterminada registró 18 casos fallidos antes de quedar sin progreso en `Home launcher opens and filters soil memories`; el evento de ese test quedó iniciado pero sin completar. La detuve tras más de un minuto sin avance. La corrida completa anterior informada (544 ejecutados, 7 omitidos, 19 fallidos) no pudo reproducirse ni reconciliarse exactamente con esta ejecución. Otra corrida con preview activado evidenció además una carrera asíncrona en `queued marker changes wake the coordinator immediately`. No se atribuyen estos resultados a cambios previos ni se modificó GIS/sincronización ajenos al actualizador.
- Casos exactos registrados en la corrida predeterminada:
  - Preview sin el define requerido: `preview state is volatile and cannot run a real update check`; `update indicator opens the preview and Más tarde closes it`; `Descargar closes the dialog and starts popup progress`; `popup cancellation returns to a dismissible cancelled state`; `simulation completes at 100 percent without a real callback`; `centered update dialog remains usable in a narrow window`.
  - Herramientas de datos: `generic optimizer removes attributes outside the schema and verifies every tile`; `publication a valid archive is published with its sidecar and metadata` (ambas expectativas de `FASE1`).
  - GIS: `GIS map search returns the selected feature internally`; `GIS map measures and clears a two-point distance`; `GIS map search includes and ranks unit symbols`; `GIS search groups results and orders series units`; `GIS bottom sheet toggles and persists a favorite feature`; `Córdoba 1:500,000 displays available taxonomy fields`; `Buenos Aires title omits type and the series composition`; `Santa Fe MLA-04 resolves each source series and its memory`; `GIS favorite reuses search centering and selection workflow`; `GIS map search recenters on consecutive selections`.
- Los seis casos de preview fallaron porque esa corrida fue compilada sin el define requerido. Con `--dart-define=SUelosAR_UPDATE_PREVIEW=true`, los tests focalizados de preview y el test de configuración pasan; el test de modo ahora valida tanto el valor por defecto como el define explícito. Los dos fallos de `test/tool/suelosar_data/phase2_test.dart` son expectativas de campos (`FASE1`) distintas de los datos observados. Los diez casos GIS/cartográficos fallaron por resultados de búsqueda duplicados/ausentes, tarjeta o acción ausente, o timeout de animación. Son rutas ajenas al actualizador, pero sin una corrida idéntica sobre una línea base limpia no se etiquetan como preexistentes.
- `flutter analyze`: dos infos preexistentes `prefer_initializing_formals` en `lib/gis/multi_coverage_repository.dart:32,33`; exit `1` por esos infos. Se quitó un import innecesario del test TLS live; el nuevo diagnóstico desapareció.
- `git diff --check`: sin errores.

## Instalador final local

- Ruta: `D:\SuelosAR_TLS_Final_20261102\SuelosAR-Setup-1.7.0.exe`
- Tamaño: `698,536,892` bytes (`698.54 MB` decimales; `665.99 MiB`).
- SHA-256: `47C40BEFBBC780DCFD0CDDCF679528026CD878F1E29E86C1DE8AF4DD54F66DA1`
- Sidecar: `D:\SuelosAR_TLS_Final_20261102\SuelosAR-Setup-1.7.0.exe.sha256`
- `Get-FileHash` y `certutil -hashfile` dieron el mismo SHA-256; el sidecar coincide.
- El Setup se instaló en Sandbox con éxito. La instalación validó el producto `1.7.0+20`, AppId preservado y el helper del actualizador en el recorrido de upgrade. La prueba no reemplazó ni ejecutó el instalador en el host.

El digest público de GitHub continúa siendo `7FB370F5D9367C016BCDF8555C97BB46605E9EE42A72DFC88B4FDED0AACE9F65`, distinto del candidato local. No subir este candidato automáticamente: el usuario decidirá y reemplazará manualmente tanto el Setup como su sidecar.

## Configuración temporal pendiente

La preferencia Flutter quedó en `C:\Users\jerem\AppData\Roaming\.flutter_settings` con `build-dir: build`. Sigue existiendo `C:\Users\jerem\suelosar\.tls-build`, confirmado como junction a `D:\SuelosAR_TLS_Build_20261102_01`. Una operación normal de remoción ya había sido bloqueada por la política de ejecución; no se intentó otro método para eludirla. El directorio D: y los artefactos de evidencia se preservaron.

## Evidencia de Sandbox

La evidencia detallada permanece en:

- `D:\SuelosAR_Update_Sandbox_Test_Experimental_20261102\Results\Upgrade-1.6.0-to-1.7.0-20261102`
- `D:\SuelosAR_Update_Sandbox_Test_Experimental_20261102\Results\Clean-170-20261102`
- `D:\SuelosAR_TLS_Final_20261102`

No se publicaron assets, no se creó una release y no se cambió Git.
