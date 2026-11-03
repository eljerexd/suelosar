# Resultado E2E del actualizador Windows

Fecha: 2026-11-02

Sandbox de actualización: `3ebb0015-43c9-433b-ab85-c380d7c2e931`

Sandbox instalación limpia: `48c9b7f1-56ef-4f1a-b99e-5dffec0750fb`

## Prueba 1: instalación limpia de 1.7.0

Artefacto probado: `D:\SuelosAR_TLS_Final_20261102\SuelosAR-Setup-1.7.0.exe`.

- Host/guest verificaron el mismo archivo y checksum: `47C40BEFBBC780DCFD0CDDCF679528026CD878F1E29E86C1DE8AF4DD54F66DA1`.
- Tamaño: `698,536,892` bytes.
- Inno Setup finalizó con exit code `0`; su log indica instalación exitosa y que no se requiere reiniciar Windows.
- Microsoft VC++ x64 quedó instalado, versión `v14.51.36247.00`, registro `Installed=1`.
- `C:\Program Files\SuelosAR\suelosar.exe` es versión `1.7.0+20`.
- `C:\Program Files\SuelosAR\rhttp.dll` está instalado y fue observado cargado por `suelosar.exe`.
- El actualizador consultó el release público `eljerexd/Web-SuelosAR`; las preferencias persistidas indican `upToDate`, `v1.7.0` y hora de éxito `2026-11-02T23:01:36.181156Z`.

La comprobación visual no pudo ejecutarse: no había sesión interactiva en Sandbox y el arranque `ExistingLogin` devolvió `0x80070520`. El proceso se inició bajo SYSTEM, respondió y persistió el resultado del chequeo, pero no se afirma que el menú haya sido inspeccionado. El sondeo posterior observó dos procesos en sesión 0; ese sondeo no demuestra instancia única ni prueba funciones offline con interacción.

## Prueba 2: actualización 1.6.0 → 1.7.0

La 1.6.0 original mostró repetidos errores TLS de BoringSSL al consultar el endpoint oficial. La compilación de prueba 1.6.0 conservó `1.6.0+10` y añadió `rhttp` solamente para Sandbox. Desde ella, el transporte con raíces del sistema y verificación habilitada recibió la release real pública `v1.7.0`, interpretó el JSON, seleccionó `SuelosAR-Setup-1.7.0.exe` y obtuvo el digest público. El resultado quedó en `rhttp-live-check-from-160.json`.

El asset de GitHub aún tenía el hash público anterior; por eso el resto del flujo usó metadata de prueba explícitamente identificada y sirvió el Setup candidato local a través del servicio de descarga existente. **No fue una descarga del asset nuevo desde GitHub.** El servicio recibió los `698,536,892` bytes y verificó el SHA-256 local `47c40befbbc780dcfd0cddcf679528026cd878f1e29e86c1de8af4dd54f66da1` antes de iniciar el helper.

Secuencia registrada:

1. Descarga con checkpoints 0%, 25%, 50%, 75% y 100%.
2. Verificación del hash y preparación del helper.
3. Inicio del Setup 1.7.0 desde el helper.
4. Inno Setup completó con código `0`, sin reinicio requerido.
5. El helper verificó la versión instalada, reinició SuelosAR y limpió el directorio temporal del instalador.
6. La verificación final registró `1.7.0+20`, `rhttp.dll` cargado desde `Program Files`, versión de VC++ `v14.51.36247.00` y una instancia del proceso.
7. El marcador `created-by-suelosar-1.6.0-sandbox-test` siguió presente después del upgrade; `pendingRelease` quedó nulo.

La actualización ocurrió solo dentro del Sandbox. El log confirma el lanzamiento del helper como proceso y el resultado de instalación; no se registró una ventana UAC separada en esta sesión, que ya tenía contexto administrativo. Esto no equivale a validar prompts UAC del host.

## Instalador y publicación

Setup local final: `D:\SuelosAR_TLS_Final_20261102\SuelosAR-Setup-1.7.0.exe`

Sidecar: `D:\SuelosAR_TLS_Final_20261102\SuelosAR-Setup-1.7.0.exe.sha256`

SHA-256: `47C40BEFBBC780DCFD0CDDCF679528026CD878F1E29E86C1DE8AF4DD54F66DA1`

`Get-FileHash`, `certutil` y el sidecar coinciden. No se modificó GitHub: el digest publicado sigue siendo `7FB370F5D9367C016BCDF8555C97BB46605E9EE42A72DFC88B4FDED0AACE9F65`. El usuario reemplazará manualmente el Setup y el checksum si aprueba este candidato.

## Evidencia guardada

- Upgrade y trazas: `D:\SuelosAR_Update_Sandbox_Test_Experimental_20261102\Results\Upgrade-1.6.0-to-1.7.0-20261102`
- Instalación limpia: `D:\SuelosAR_Update_Sandbox_Test_Experimental_20261102\Results\Clean-170-20261102`
- Instalador, sidecar y logs de análisis/pruebas: `D:\SuelosAR_TLS_Final_20261102`

La instalación original de terceros 1.6.0 no tiene una ruta automática validada bajo el TLS observado. Para ese usuario único de prueba se usó una 1.6.0 temporal corregida; no debe confundirse con soporte automático para la 1.6.0 pública. La instalación limpia y el resultado de chequeo están verificados por artefactos, con la limitación gráfica descrita arriba.
