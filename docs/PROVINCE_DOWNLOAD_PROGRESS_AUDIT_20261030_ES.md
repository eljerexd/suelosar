# Auditoría del progreso de descargas provinciales

Fecha de inspección: 2026-10-30  
Alcance: lectura de código y estado de Git; no se ejecutaron builds ni pruebas.

## Estado del repositorio

- Ruta verificada: `C:\Users\jerem\suelosar`.
- Rama: `beta`.
- HEAD: `299248598108992fd91cd88bef31d6d1da2a8a11`.
- El árbol ya contiene modificaciones rastreadas y archivos sin seguimiento. Se conservaron; esta auditoría no cambió código, pruebas, configuración ni datos. El único archivo creado es este informe solicitado.

## Arquitectura y recorrido de la descarga

Las tres provincias se registran como `MapCoverage` con su `ProvinceConfig` y su instancia de `PmtilesDelivery`: Buenos Aires (`BuenosAiresPmtilesDelivery`), Santa Fe (`SantaFePmtilesDelivery`) y Córdoba (`CordobaPmtilesDelivery`). La lista está en `lib/gis/map_coverage.dart:45-113`. Los anclajes y tamaños declarados están en `lib/gis/province_config.dart:109-112` (Buenos Aires), `:156-159` (Santa Fe) y `:194-198` (Córdoba).

En `GisMapScreen`, `initState` registra un listener por entrega, llama a `checkStatus()` y construye el repositorio con la disponibilidad de cada PMTiles (`lib/gis/gis_map_screen.dart:390-478`). El listener `_handleOnDemandStatusChanged` serializa los cambios de disponibilidad y, cuando la cobertura pasa a disponible o deja de estarlo, actualiza el repositorio y recarga mosaicos visibles si corresponde (`:3679-3738`). Los listeners se retiran al desmontar la pantalla (`:658-664`).

En la implementación actual de mapa, cada `_ProvincePmtilesBanner` crea su propia tarjeta flotante. El botón recibe el callback `onDownload` desde `GisMapScreen`; ese callback invoca `undownloadedCoverage.onDemandDelivery!.download()` (`lib/gis/gis_map_screen.dart:1959-1974`). La tarjeta lo conecta directamente con `FilledButton.onPressed` (`:11818-11829`). No hay una capa de descarga adicional en el widget.

El trabajo real se realiza mediante la entrega de cada provincia. Los tres proveedores implementan la misma interfaz y el mismo flujo de alto nivel: `download()` cambia el estado, abre la solicitud de instalación, escucha actualizaciones y comprueba que los assets queden legibles. Referencias: `lib/gis/buenos_aires_pmtiles_delivery.dart:203-241`, `lib/gis/santa_fe_pmtiles_delivery.dart:181-217` y `lib/gis/cordoba_pmtiles_delivery.dart:180-215`. En Android release, el canal Dart `PmtilesDeliveryChannel` solicita la instalación y recibe el stream de eventos (`lib/gis/pmtiles_delivery_channel.dart:93-176`); el puente Kotlin usa Play Feature Delivery, transmite estado y bytes, y atiende las solicitudes (`android/app/src/main/kotlin/ar/com/suelosar/PmtilesDeliveryBridge.kt:56-81`, `:100-198`, `:207-248`). En Windows y otras plataformas fuera de la entrega bajo demanda, los datos se consideran incluidos y `download()` no descarga nada (`lib/gis/pmtiles_delivery.dart:14-25`, `:88-118`; proveedores, métodos `checkStatus` y `download`).

## Estado y ciclo de vida

La interfaz común declara `PmtilesDeliveryStatus { notInstalled, downloading, available, error }` y los getters `downloadProgress` y `downloadBytes` (`lib/gis/pmtiles_delivery.dart:29`, `:88-118`). No existe un estado de aplicación separado llamado “loading” o “checking”: Android comienza como `notInstalled`, mientras que plataformas con archivos incluidos comienzan como `available`; `checkStatus()` actualiza el resultado de forma asíncrona (por ejemplo, `lib/gis/cordoba_pmtiles_delivery.dart:30-46`, `:144-178`).

1. **Sin instalar / comprobación:** `notInstalled` en Android. `checkStatus()` comprueba si el componente ya está instalado y accesible. Una comprobación no inicia una descarga.
2. **Descargando:** `download()` ignora llamadas repetidas mientras el estado ya sea `downloading`, limpia valores de progreso previos y publica el nuevo estado. En builds de desarrollo se usa una simulación local; en release se abre una sesión de Play.
3. **Progreso:** el proveedor escucha actualizaciones filtradas por nombre de módulo. Las actualizaciones de Play incluyen `bytesDownloaded` y `totalBytesToDownload`; si el total aún no es válido, el progreso queda nulo. La suscripción se abre antes de solicitar la instalación para no perder eventos tempranos.
4. **Instalado y legible:** Play informa `installed`; luego se refresca el acceso a assets y se reintenta leer el recurso de versión. Solo si esa comprobación termina correctamente el proveedor publica `available` (`lib/gis/cordoba_pmtiles_delivery.dart:180-287`; las otras dos provincias siguen el mismo patrón).
5. **Fallo o cancelación de Play:** las excepciones, el timeout y los estados terminales distintos de `installed` hacen que el proveedor limpie el progreso y publique `error`. `PmtilesInstallStatus` distingue estados de Play, incluidos `canceled` y `failed`, pero la interfaz de provincia los agrupa en el único estado de aplicación `error` (`lib/gis/pmtiles_delivery_channel.dart:7-35`; proveedor Córdoba `:203-215`, `:232-270`). La tarjeta puede ofrecer nuevamente `Descargar` cuando el estado no es `available` ni `downloading`, por lo que un reintento usa el mismo flujo.

No hay un botón de cancelación en la tarjeta del mapa ni una llamada Dart a `PmtilesDeliveryChannel.cancel()` desde la aplicación (la búsqueda de usos no encontró callers). El canal y el puente Android sí exponen cancelación de sesión (`lib/gis/pmtiles_delivery_channel.dart:164-176`; puente Kotlin `:180-198`), pero eso no equivale a una cancelación disponible al usuario en esta pantalla. Si Play comunica una cancelación o la sesión falla, el proveedor la representa como `error`; no existe un estado `cancelled` en `PmtilesDeliveryStatus`.

## Datos reales de progreso disponibles

Los datos llegan desde `SplitInstallSessionState.bytesDownloaded()` y `totalBytesToDownload()`; el puente Android los envía como `bytesDownloaded` y `totalBytesToDownload` (`PmtilesDeliveryBridge.kt:207-219`). Dart los convierte en `PmtilesDownloadBytes` (`lib/gis/pmtiles_delivery_channel.dart:33-64`).

`PmtilesDownloadBytes.fromCounts(downloaded, total)` devuelve `null` si `total <= 0`; si hay total, conserva valores acotados al rango y expone:

- `downloaded` y `total` en bytes;
- `fraction = downloaded / total`;
- `percent = round(fraction * 100)`;
- `label`, con ambos valores en MiB (`lib/gis/pmtiles_delivery.dart:31-72`).

Los getters `PmtilesDelivery.downloadProgress` y `downloadBytes` están implementados por los tres proveedores leyendo el mismo objeto de progreso (por ejemplo, Córdoba `lib/gis/cordoba_pmtiles_delivery.dart:39-56`). Por lo tanto, **el porcentaje y los bytes descargados/totales ya están disponibles sin cambiar la lógica de descarga**. Si Play todavía no comunica un total, ambos se mantienen honestamente indeterminados: no hay porcentaje ni bytes comparables que mostrar.

## Presentación actual y finalización

`_ProvincePmtilesBannerCard` muestra durante la descarga un `CircularProgressIndicator` con `value: progress?.fraction`. Si `progress` existe, coloca el porcentaje numérico junto al anillo (`lib/gis/gis_map_screen.dart:11856-11894`). El texto de la tarjeta recibe `downloadBytes.label` como progreso de bytes (`:11490-11500`, `:11675-11747`). El anillo gira indeterminado cuando el total todavía no está disponible.

La confirmación verde con el ícono de check y `Disponible offline` no se deduce de alcanzar el 100%: se activa cuando `delivery.status` cambia efectivamente a `available` mientras la tarjeta estaba visible (`:11352-11385`, `:11900-11924`). La disponibilidad requiere que la instalación haya terminado y que el asset se pueda leer. Si el aviso estaba visible, mantiene el éxito 620 ms y luego realiza una salida de 320 ms; finalmente desaparece porque `showCard` excluye el estado `available` (`:11435-11460`, `:11468-11503`). Si el componente ya estaba disponible antes de mostrar la tarjeta, esta no aparece, por lo que tampoco se reproduce esa confirmación de finalización.

Al cerrar manualmente, la tarjeta se anima durante 180 ms y persiste el estado cerrado por provincia y estado en `SharedPreferences` (`_ProvinceNoticeDismissal`, `lib/gis/gis_map_screen.dart:11047-11059`, `_startDismissExit` y `_dismiss`, `:11391-11428`). Cuando el estado cambia, el aviso puede volver a aparecer. Esta es la conducta actual de cierre; el informe no propone alterarla.

## Descarga al cambiar o cerrar la tarjeta

El estado y la sesión viven en los singletons de entrega (`MapCoverage`), no en la tarjeta. Cada proveedor conserva `_status` y `_downloadBytes` y notifica a sus listeners; `download()` continúa esperando el stream de instalación aunque el widget no esté visible. En la implementación actual, las tarjetas por provincia permanecen montadas en el `Stack` y cada una escucha su entrega, incluso si su contenido se oculta por disponibilidad, anclaje fuera de pantalla o cierre persistido. Si una futura UI compartida colapsa el panel o selecciona otra provincia, la descarga no se cancela por ese hecho: el estado global sigue avanzando, y al volver a seleccionar esa provincia la vista puede leer los valores actuales. La UI solo deja de mostrar temporalmente el progreso de la provincia que no está seleccionada.

## Evaluación del cambio visual solicitado

**Recomendación: `UI-ONLY CHANGE POSSIBLE`.**

La barra horizontal puede usar `LinearProgressIndicator(value: progress?.fraction)`, donde `null` conserva el modo indeterminado. La etiqueta puede seguir mostrando `progress.percent` y `progress.label` únicamente cuando `downloadBytes` no sea nulo. El cambio puede limitarse a la tarjeta Flutter, sin tocar proveedores, bridge nativo, repositorio, manejo de errores, reintentos ni estado offline.

Para conservar el comportamiento, la confirmación verde debe continuar gobernada por la transición a `PmtilesDeliveryStatus.available`, no por el progreso visual. La salida tras éxito y el cierre persistido también deben conservar sus temporizadores y reglas actuales. No se identificó una interfaz faltante para porcentajes o bytes.

## Verificación y limitaciones

- Se inspeccionaron las implementaciones de Buenos Aires, Santa Fe y Córdoba, el contrato común, el canal Dart, el puente Android y la tarjeta del mapa.
- No se ejecutaron pruebas, análisis, builds, ni acciones de descarga.
- Los estados intermedios de Play se comprimen en `downloading`; los estados terminales fallidos/cancelados se comprimen en `error` en la interfaz común.
- La pantalla de mapa no ofrece control de cancelación de una sesión en curso, aunque el puente Android tenga una operación de cancelación.
- Los porcentajes y bytes dependen de que Play reporte un total positivo; el modo indeterminado es necesario cuando esa información aún no está disponible.
