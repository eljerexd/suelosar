import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../analytics/analytics_actions.dart';
import '../analytics/analytics_service.dart';
import '../app/app_theme.dart';
import '../app/instant_pop_material_page_route.dart';
import '../constants/asset_paths.dart';
import '../constants/app_icons.dart';
import '../export/measurement_export.dart';
import '../models/favorite_soil_feature.dart';
import '../models/measurement_color_option.dart';
import '../models/personal_marker.dart';
import '../models/parcel_analysis.dart';
import '../models/saved_measurement.dart';
import '../repositories/pdf_series_repository.dart';
import '../repositories/sync_aware_local_repository.dart';
import '../screens/gis_favorites_screen.dart';
import '../screens/measurements_screen.dart';
import '../screens/pdf_viewer_screen.dart';
import '../screens/personal_markers_screen.dart';
import '../services/settings_service.dart';
import '../services/desktop_window_service.dart';
import '../services/gis_favorites_service.dart';
import '../sync/sync_state.dart';
import '../sync/uuid_v4.dart';
import '../utils/app_motion.dart';
import '../widgets/app_notification.dart';
import '../widgets/desktop_fullscreen_state_builder.dart';
import '../widgets/destructive_action_confirmation.dart';
import '../widgets/floating_app_bar_card.dart';
import '../widgets/measurement_color_selector.dart';
import '../widgets/personal_marker_category_icon.dart';
import '../widgets/responsive_desktop_shell.dart';
import '../widgets/saved_measurement_overflow_menu.dart';
import 'gis_feature.dart';
import 'gis_layer.dart';
import 'gis_location_service.dart';
import 'gis_map_occlusion_observer.dart';
import 'offline_reference_map_layer.dart';
import 'gis_render_metrics.dart';
import 'gis_repository.dart';
import 'gis_soil_series.dart';
import 'widgets/expandable_tools_fab.dart';

/// Interactive offline viewer for the spatial layers available in SuelosAR.
class GisMapScreen extends StatefulWidget {
  const GisMapScreen({
    super.key,
    this.repository,
    this.pdfSeriesRepository,
    this.renderMetrics,
    this.locationService,
    this.desktopWindowService,
  });

  final GisRepository? repository;
  final PdfSeriesRepository? pdfSeriesRepository;
  final GisRenderMetrics? renderMetrics;
  final GisLocationService? locationService;
  final DesktopWindowService? desktopWindowService;

  @override
  State<GisMapScreen> createState() => _GisMapScreenState();
}

class _GisMapScreenState extends State<GisMapScreen>
    with TickerProviderStateMixin {
  static const double _mapOcclusionThreshold = 0.9;
  static const double _androidLandscapeToolClearance = 64;
  static const LatLng _buenosAiresCenter = LatLng(-36.5, -60);
  static const double _minimumMapZoom = 7;
  static const double _initialZoom = _minimumMapZoom;
  static const GisArchiveInfo _defaultArchiveInfo = GisArchiveInfo(
    minZoom: 4,
    maxZoom: 14,
    centerLatitude: -36.5,
    centerLongitude: -60,
  );
  static const int _maxRenderedTileCacheEntries = 96;
  static const String _showSoilPolygonsPreferenceKey = 'gis.show_soil_polygons';
  static const String _showReferenceBasemapPreferenceKey =
      'gis.show_reference_basemap';
  static const bool _disableGisTilePipelineForDiagnostic = bool.fromEnvironment(
    'DISABLE_GIS_TILE_PIPELINE',
  );
  static const bool _disableGeolocatorForDiagnostic = bool.fromEnvironment(
    'DISABLE_GEOLOCATOR',
  );

  final MapController _mapController = MapController();
  final GlobalKey _mapKey = GlobalKey();

  late final GisRepository _repository;
  late final GisLocationService _locationService;
  late final PdfSeriesRepository _pdfSeriesRepository;
  late final GisRenderMetrics _renderMetrics;
  late final DesktopWindowService _desktopWindowService;
  late final bool _ownsRenderMetrics;

  final LinkedHashMap<GisTileCoordinates, _RenderedGisTile> _renderedTileCache =
      LinkedHashMap<GisTileCoordinates, _RenderedGisTile>();
  final Map<GisTileCoordinates, int> _parcelAnalysisTilePins =
      <GisTileCoordinates, int>{};
  final Map<String, _SoilSeriesSearchEntry> _soilSeriesSearchIndex =
      <String, _SoilSeriesSearchEntry>{};
  final Map<String, GisFeature> _searchFeatureSnapshots =
      <String, GisFeature>{};
  final Map<String, FavoriteSoilFeature> _favoriteFeatures =
      <String, FavoriteSoilFeature>{};
  final GisFavoritesService _gisFavoritesService = GisFavoritesService();
  final ValueNotifier<_VisibleTileSnapshot> _visibleTileSnapshot =
      ValueNotifier(const _VisibleTileSnapshot());
  final ValueNotifier<_MapOverlayState> _overlayState = ValueNotifier(
    const _MapOverlayState(isLoading: true),
  );
  final ValueNotifier<_MapViewportState> _mapViewportState = ValueNotifier(
    const _MapViewportState(
      center: _buenosAiresCenter,
      zoom: _initialZoom,
      rotation: 0,
    ),
  );
  final ValueNotifier<int> _parcelRevisionState = ValueNotifier<int>(0);
  final ValueNotifier<GisFeature?> _selectionPreview =
      ValueNotifier<GisFeature?>(null);
  final ValueNotifier<_DesktopPanelSection?> _desktopPanelSectionState =
      ValueNotifier<_DesktopPanelSection?>(null);
  Map<GisTileCoordinates, _RenderedGisTile> _visibleTiles =
      const <GisTileCoordinates, _RenderedGisTile>{};
  Set<GisTileCoordinates> _visibleTileCoordinates =
      const <GisTileCoordinates>{};
  Set<GisTileCoordinates> _prefetchedTileCoordinates =
      const <GisTileCoordinates>{};
  AnimationController? _searchCameraAnimation;
  AnimationController? _northRotationAnimation;
  StreamSubscription<GisLocation>? _locationSubscription;
  Timer? _tileLoadDebounce;
  GisArchiveInfo _archiveInfo = _defaultArchiveInfo;
  bool _isMapReady = false;
  bool _isLocating = false;
  bool _gpsEnabledLogged = false;
  bool _showSoilPolygons = true;
  bool _showReferenceBasemap = true;
  _InteractionMode _interactionMode = _InteractionMode.none;
  bool _isFollowingLocation = false;
  bool _isInvalidMeasurementWarningVisible = false;
  bool _isMeasurementDialogVisible = false;
  bool _isSearchViewOpen = false;
  bool _mapVisualsPaused = false;
  bool _desktopToolsPanelCollapsed = false;
  OverlayEntry? _desktopLayersOverlay;
  PersonalMarker? _desktopSelectedMarker;
  final List<_SoilSeriesSearchEntry> _desktopRecentSearches =
      <_SoilSeriesSearchEntry>[];
  final Object _searchOcclusionToken = Object();
  final Object _routeOcclusionToken = Object();
  final Map<Object, double> _mapOcclusions = <Object, double>{};
  Route<dynamic>? _registeredMapRoute;
  final List<PersonalMarker> _personalMarkers = <PersonalMarker>[];
  _MeasurementMode? _retainedMeasurementMode;
  final List<LatLng> _distanceMeasurementPoints = <LatLng>[];
  final List<LatLng> _areaMeasurementPoints = <LatLng>[];
  final List<SavedMeasurement> _savedMeasurements = <SavedMeasurement>[];
  String? _highlightedSavedMeasurementId;
  String? _activeSavedMeasurementId;
  String? _savedMeasurementGeometrySignature;
  String? _savedMeasurementColorId;
  _MapToolHintType? _activeToolHint;
  int? _draggedAreaVertexIndex;
  bool _suppressNextMapTap = false;
  MeasurementColorOption _measurementColor = MeasurementColorOption.blue;
  GisFeature? _currentLocationFeature;
  GisLocation? _currentLocation;
  GisFeature? _searchSelectedFeature;
  ParcelAnalysis? _latestParcelAnalysis;
  String? _selectedFeatureId;
  int _tileRequestId = 0;
  int _parcelRevision = 0;
  int? _visibleTileZoom;

  _MeasurementMode? get _measurementMode => switch (_interactionMode) {
    _InteractionMode.measureDistance => _MeasurementMode.distance,
    _InteractionMode.measureArea => _MeasurementMode.area,
    _InteractionMode.none || _InteractionMode.addMarker => null,
  };

  bool get _isPersonalMarkerMode =>
      _interactionMode == _InteractionMode.addMarker;

  void _setInteractionMode(_InteractionMode mode) {
    if (_interactionMode == mode) return;
    _interactionMode = mode;
    _draggedAreaVertexIndex = null;
    _suppressNextMapTap = false;
    _activeToolHint = null;
  }

  @visibleForTesting
  GisFeature? get currentLocationFeature => _currentLocationFeature;

  @visibleForTesting
  GisFeature? get searchSelectedFeature => _searchSelectedFeature;

  @visibleForTesting
  List<LatLng> get areaMeasurementPoints =>
      List<LatLng>.unmodifiable(_areaMeasurementPoints);

  @visibleForTesting
  ParcelAnalysis? get latestParcelAnalysis => _latestParcelAnalysis;

  @visibleForTesting
  int get renderedTileCacheSize => _renderedTileCache.length;

  @visibleForTesting
  int get visibleTileCount => _visibleTileCoordinates.length;

  @visibleForTesting
  int get prefetchedTileCount => _prefetchedTileCoordinates.length;

  @visibleForTesting
  int get maxRenderedTileCacheEntries => _maxRenderedTileCacheEntries;

  @visibleForTesting
  int get searchIndexSize => _soilSeriesSearchIndex.length;

  @visibleForTesting
  bool get mapVisualsPaused => _mapVisualsPaused;

  @visibleForTesting
  String get activeInteractionMode => _interactionMode.name;

  @visibleForTesting
  bool get showSoilPolygons => _showSoilPolygons;

  @visibleForTesting
  bool get showReferenceBasemap => _showReferenceBasemap;

  @override
  void initState() {
    super.initState();
    unawaited(AnalyticsService.instance.logMapOpened());
    _ownsRenderMetrics = widget.renderMetrics == null;
    _renderMetrics = widget.renderMetrics ?? GisRenderMetrics.disabled();
    _desktopWindowService =
        widget.desktopWindowService ?? DesktopWindowService.instance;
    _repository =
        widget.repository ??
        PmTilesGisRepository.fromAsset(
          assetPath: AssetPaths.gisPmTiles,
          versionAssetPath: AssetPaths.gisPmTilesVersion,
          layerName: AssetPaths.gisLayerName,
        );
    _pdfSeriesRepository = widget.pdfSeriesRepository ?? PdfSeriesRepository();
    _locationService =
        widget.locationService ?? const DeviceGisLocationService();
    if (_disableGisTilePipelineForDiagnostic) {
      _updateOverlay(isLoading: false);
      debugPrint('GIS diagnostic: tile pipeline disabled.');
    } else {
      unawaited(_initializeArchive());
    }
    if (_disableGeolocatorForDiagnostic) {
      debugPrint('GIS diagnostic: Geolocator disabled.');
    }
    unawaited(_loadFavorites());
    unawaited(_loadMapDisplayPreferences());
    unawaited(_loadMeasurementColor());
    unawaited(_loadSavedMeasurements());
    unawaited(_loadPersonalMarkers());
    if (!_disableGeolocatorForDiagnostic &&
        SettingsService.instance.followLocationAutomatically) {
      _isFollowingLocation = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_centerMapOnCurrentLocation());
        }
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (isSuelosArDesktopPlatform(context)) {
      unawaited(_desktopWindowService.initialize());
    }
    final route = ModalRoute.of(context);
    if (route == null || identical(route, _registeredMapRoute)) return;
    final previousRoute = _registeredMapRoute;
    if (previousRoute != null) {
      GisMapOcclusionObserver.instance.unregister(previousRoute);
    }
    _registeredMapRoute = route;
    GisMapOcclusionObserver.instance.register(
      route,
      (coverage) => _updateMapOcclusion(_routeOcclusionToken, coverage),
    );
  }

  @override
  void dispose() {
    _removeDesktopLayersOverlay();
    final registeredRoute = _registeredMapRoute;
    if (registeredRoute != null) {
      GisMapOcclusionObserver.instance.unregister(registeredRoute);
    }
    _tileLoadDebounce?.cancel();
    unawaited(_locationSubscription?.cancel());
    _searchCameraAnimation?.dispose();
    _northRotationAnimation?.dispose();
    for (final tile in _renderedTileCache.values) {
      tile.dispose();
    }
    _visibleTileSnapshot.dispose();
    _overlayState.dispose();
    _mapViewportState.dispose();
    _parcelRevisionState.dispose();
    _selectionPreview.dispose();
    _desktopPanelSectionState.dispose();
    if (_ownsRenderMetrics) {
      _renderMetrics.dispose();
    }
    unawaited(_repository.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final measurementMode = _measurementMode;
    final showsMeasurement = measurementMode != null && _hasMeasurementPoints;
    final mediaQuery = MediaQuery.of(context);
    final desktopLayout = isSuelosArDesktopPlatform(context);
    final compactLayout = !desktopLayout && mediaQuery.size.width < 600;
    final androidPhoneLandscape = isSuelosArAndroidPhoneLandscape(context);
    final portraitMobile =
        compactLayout && mediaQuery.orientation == Orientation.portrait;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        preferredSize: Size.fromHeight(compactLayout ? 148 : 88),
        child: desktopLayout
            ? _buildDesktopMapHeader(context)
            : compactLayout
            ? _buildCompactMapHeader(
                context,
                showsMeasurement,
                portraitMobile: portraitMobile,
                androidPhoneLandscape: androidPhoneLandscape,
              )
            : SafeArea(
                minimum: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                child: AppBar(
                  automaticallyImplyLeading: false,
                  toolbarHeight: 64,
                  elevation: 0,
                  scrolledUnderElevation: 0,
                  backgroundColor: Colors.transparent,
                  surfaceTintColor: Colors.transparent,
                  titleSpacing: 0,
                  title: _MapTopBarCard(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FloatingAppBarBackButton(
                          onPressed: () => Navigator.maybePop(context),
                        ),
                        const SizedBox(width: 14),
                        Text(
                          'Mapa de suelos',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(width: 8),
                      ],
                    ),
                  ),
                  actions: [
                    if (!desktopLayout)
                      Padding(
                        padding: EdgeInsets.only(
                          right: androidPhoneLandscape
                              ? _androidLandscapeToolClearance
                              : 0,
                        ),
                        child: _MapTopBarCard(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _MapChromeIconButton(
                                tooltip: 'Abrir marcadores personales',
                                icon: const Icon(Icons.bookmarks),
                                onPressed: _openPersonalMarkers,
                              ),
                              _MapChromeIconButton(
                                tooltip: 'Abrir mediciones',
                                icon: const Icon(Icons.history),
                                onPressed: _openMeasurements,
                              ),
                              _AnimatedMapHeaderItem(
                                visible:
                                    showsMeasurement &&
                                    _activeSavedMeasurementId == null,
                                child: _MapChromeIconButton(
                                  tooltip: 'Deshacer último punto',
                                  icon: const Icon(AppIcons.undo),
                                  onPressed: _undoMeasurementPoint,
                                ),
                              ),
                              _AnimatedMapHeaderItem(
                                visible: showsMeasurement,
                                child: _MapChromeIconButton(
                                  tooltip: 'Limpiar medición',
                                  icon: const Icon(AppIcons.delete),
                                  onPressed: _clearMeasurement,
                                ),
                              ),
                              SearchAnchor(
                                viewBuilder: _buildSearchView,
                                viewOnOpen: _handleSearchViewOpen,
                                viewOnClose: _handleSearchViewClose,
                                viewHintText:
                                    'Buscar localidad, unidad o serie...',
                                viewBackgroundColor: Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerLow,
                                viewSurfaceTintColor: Colors.transparent,
                                viewElevation: 8,
                                viewShape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(24),
                                ),
                                viewSide: BorderSide(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outlineVariant
                                      .withValues(alpha: 0.55),
                                ),
                                viewBarPadding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                headerHeight: 64,
                                headerTextStyle: Theme.of(context)
                                    .textTheme
                                    .bodyLarge
                                    ?.copyWith(fontWeight: FontWeight.w500),
                                headerHintStyle: Theme.of(context)
                                    .textTheme
                                    .bodyLarge
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                                dividerColor: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant
                                    .withValues(alpha: 0.45),
                                viewConstraints: const BoxConstraints(
                                  minWidth: 420,
                                  maxWidth: 680,
                                  maxHeight: 620,
                                ),
                                viewPadding: const EdgeInsets.fromLTRB(
                                  8,
                                  8,
                                  8,
                                  16,
                                ),
                                builder: (context, controller) {
                                  return _MapChromeIconButton(
                                    tooltip: 'Buscar',
                                    icon: const Icon(AppIcons.search),
                                    onPressed: () {
                                      controller.openView();
                                    },
                                  );
                                },
                                suggestionsBuilder: _buildSearchSuggestions,
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
      ),
      body: desktopLayout
          ? _buildDesktopMapShell(_archiveInfo)
          : _buildMap(_archiveInfo),
    );
  }

  Widget _buildDesktopMapHeader(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: SizedBox(
        height: 66,
        width: double.infinity,
        child: _MapTopBarCard(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          elevation: 5,
          shadowAlpha: 0.22,
          side: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.42),
          ),
          child: Row(
            children: [
              FloatingAppBarBackButton(
                onPressed: () => Navigator.maybePop(context),
              ),
              const SizedBox(width: 12),
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(AppIcons.map, size: 20, color: colorScheme.primary),
              ),
              const SizedBox(width: 10),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Mapa de suelos',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    'Provincia de Buenos Aires',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              ValueListenableBuilder<_MapViewportState>(
                valueListenable: _mapViewportState,
                builder: (context, viewState, child) {
                  return _DesktopHeaderMapStatus(zoom: viewState.zoom);
                },
              ),
              const SizedBox(width: 6),
              _DesktopFullscreenButton(service: _desktopWindowService),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopMapShell(GisArchiveInfo archiveInfo) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape):
            _cancelDesktopTemporaryMode,
        const SingleActivator(LogicalKeyboardKey.f11): () =>
            unawaited(_desktopWindowService.toggleFullScreen()),
      },
      child: Focus(
        autofocus: true,
        child: SuelosArDesktopPageScaffold(
          panelTopInset: 76,
          sidePanelVerticalInset: 28,
          sidePanel: ValueListenableBuilder<_DesktopPanelSection?>(
            valueListenable: _desktopPanelSectionState,
            builder: (context, selectedSection, child) {
              return SuelosArFloatingSidePanel(
                padding: _desktopToolsPanelCollapsed
                    ? const EdgeInsets.all(8)
                    : null,
                child: _DesktopMapToolsPanel(
                  collapsed: _desktopToolsPanelCollapsed,
                  selectedSection: selectedSection,
                  onCollapsedChanged: (collapsed) {
                    setState(() => _desktopToolsPanelCollapsed = collapsed);
                  },
                  onSelectSection: _selectDesktopPanelSection,
                  activeMode: _desktopActiveMode,
                  onMeasureDistance: () =>
                      _selectMeasurementOption(_MeasurementMenuOption.distance),
                  onMeasureArea: () =>
                      _selectMeasurementOption(_MeasurementMenuOption.area),
                  onAddMarker: _togglePersonalMarkerMode,
                ),
              );
            },
          ),
          informationPanel: ValueListenableBuilder<_DesktopPanelSection?>(
            valueListenable: _desktopPanelSectionState,
            builder: (context, selectedSection, child) {
              return _buildDesktopInformationPanel(selectedSection);
            },
          ),
          informationAlignment: Alignment.centerRight,
          child: _buildMap(archiveInfo, desktopShell: true),
        ),
      ),
    );
  }

  Widget _buildDesktopInformationPanel(_DesktopPanelSection? selectedSection) {
    final selectedMeasurement = _savedMeasurements
        .where(
          (measurement) =>
              measurement.id == _highlightedSavedMeasurementId &&
              measurement.isVisible,
        )
        .firstOrNull;

    return ValueListenableBuilder<GisFeature?>(
      valueListenable: _selectionPreview,
      builder: (context, feature, child) {
        final activeMode = _desktopActiveMode;
        if (activeMode != null) {
          final vertexCount = switch (activeMode) {
            _DesktopActiveMode.distance => _distanceMeasurementPoints.length,
            _DesktopActiveMode.area => _areaMeasurementPoints.length,
            _DesktopActiveMode.marker => null,
          };
          final liveValue = switch (activeMode) {
            _DesktopActiveMode.distance
                when _distanceMeasurementPoints.length >= 2 =>
              _MeasurementLayer._formatDistance(
                _MeasurementLayer._calculatePathDistance(
                  _distanceMeasurementPoints,
                ),
              ),
            _DesktopActiveMode.area when _areaMeasurementPoints.length >= 3 =>
              _MeasurementLayer._formatArea(
                _MeasurementLayer._calculateArea(_areaMeasurementPoints),
              ),
            _ => null,
          };
          return _DesktopPanelTransition(
            panelKey: activeMode,
            child: SuelosArFloatingInformationPanel(
              child: _DesktopActiveModePanel(
                mode: activeMode,
                vertexCount: vertexCount,
                liveValue: liveValue,
                onDismiss: _cancelDesktopTemporaryMode,
              ),
            ),
          );
        }
        final section = selectedSection;
        if (section != null) {
          if (section == _DesktopPanelSection.layers) {
            return const SizedBox.shrink();
          }
          final panel = SuelosArFloatingInformationPanel(
            child: switch (section) {
              _DesktopPanelSection.layers => _DesktopLayersPanel(
                showSoilPolygons: _showSoilPolygons,
                showReferenceBasemap: _showReferenceBasemap,
                onToggleSoilPolygons: () =>
                    _toggleLayerVisibility(_LayerVisibilityOption.soilPolygons),
                onToggleReferenceBasemap: () => _toggleLayerVisibility(
                  _LayerVisibilityOption.referenceBasemap,
                ),
                onDismiss: _closeDesktopPanel,
              ),
              _DesktopPanelSection.search => _DesktopSearchPanel(
                entries: _soilSeriesSearchIndex.values.toList(growable: false),
                selectedFeatureId: _searchSelectedFeature?.id,
                recentEntries: _desktopRecentSearches,
                onSelect: _selectDesktopSearchResult,
                onDismiss: _closeDesktopPanel,
              ),
              _DesktopPanelSection.measurements =>
                _DesktopCollectionPanel<SavedMeasurement>(
                  title: 'Mediciones',
                  subtitle:
                      '${_savedMeasurements.length} guardadas · '
                      '${_savedMeasurements.where((item) => item.type == SavedMeasurementType.area).length} áreas · '
                      '${_savedMeasurements.where((item) => item.type == SavedMeasurementType.distance).length} distancias',
                  icon: Icons.history,
                  items: _savedMeasurements,
                  searchFieldKey: const ValueKey(
                    'desktop-measurements-search-field',
                  ),
                  searchHint: 'Buscar medición...',
                  searchTerms: (measurement) => [measurement.name],
                  emptyMessage: 'No hay mediciones guardadas.',
                  itemTitle: (measurement) => measurement.name,
                  itemSubtitle: (measurement) =>
                      measurement.type == SavedMeasurementType.area
                      ? _MeasurementLayer._formatArea(
                          measurement.areaSquareMeters ?? 0,
                        )
                      : _MeasurementLayer._formatDistance(
                          measurement.distanceMeters ?? 0,
                        ),
                  onSelect: _focusSavedMeasurement,
                  itemEnabled: (measurement) => measurement.isVisible,
                  itemSelected: (measurement) =>
                      measurement.id == _highlightedSavedMeasurementId,
                  trailingBuilder: (measurement) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: measurement.isVisible ? 'Ocultar' : 'Mostrar',
                        onPressed: () => unawaited(
                          _toggleSavedMeasurementVisibility(measurement),
                        ),
                        icon: Icon(
                          measurement.isVisible
                              ? AppIcons.visibility
                              : AppIcons.visibilityOff,
                          size: 19,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Editar',
                        onPressed: measurement.isVisible
                            ? () => unawaited(
                                _requestSelectSavedMeasurement(measurement),
                              )
                            : null,
                        icon: const Icon(AppIcons.edit, size: 19),
                      ),
                    ],
                  ),
                  onDismiss: _closeDesktopPanel,
                ),
              _DesktopPanelSection.markers =>
                _DesktopCollectionPanel<PersonalMarker>(
                  title: 'Marcadores',
                  subtitle: '${_personalMarkers.length} guardados',
                  icon: Icons.bookmarks,
                  items: _personalMarkers,
                  searchFieldKey: const ValueKey(
                    'desktop-markers-search-field',
                  ),
                  searchHint: 'Buscar marcador...',
                  searchTerms: (marker) => [marker.name, marker.description],
                  emptyMessage: 'No hay marcadores personales.',
                  itemTitle: (marker) => marker.name,
                  itemSubtitle: (marker) => marker.category.label,
                  itemMetaLabel: (marker) => 'Categoría',
                  onSelect: _focusPersonalMarker,
                  itemSelected: (marker) =>
                      marker.id == _desktopSelectedMarker?.id,
                  headerAction: IconButton(
                    tooltip: 'Agregar marcador',
                    onPressed: _startDesktopMarkerPlacement,
                    icon: const Icon(AppIcons.addLocation),
                  ),
                  trailingBuilder: (marker) =>
                      PopupMenuButton<_DesktopMarkerAction>(
                        tooltip: 'Más acciones',
                        onSelected: (action) {
                          switch (action) {
                            case _DesktopMarkerAction.edit:
                              unawaited(_editPersonalMarker(marker));
                            case _DesktopMarkerAction.delete:
                              unawaited(_confirmDeletePersonalMarker(marker));
                          }
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem(
                            value: _DesktopMarkerAction.edit,
                            child: Text('Editar'),
                          ),
                          PopupMenuItem(
                            value: _DesktopMarkerAction.delete,
                            child: Text('Eliminar'),
                          ),
                        ],
                      ),
                  onDismiss: _closeDesktopPanel,
                ),
              _DesktopPanelSection.favorites =>
                _DesktopCollectionPanel<FavoriteSoilFeature>(
                  title: 'Favoritos',
                  subtitle: '${_favoriteFeatures.length} suelos guardados',
                  subtitleBuilder: () =>
                      '${_favoriteFeatures.length} suelos guardados',
                  icon: AppIcons.star,
                  items: _favoriteFeatures.values,
                  searchFieldKey: const ValueKey(
                    'desktop-favorites-search-field',
                  ),
                  searchHint: 'Buscar favorito...',
                  searchTerms: (favorite) => [favorite.dominantSoilSeries],
                  emptyMessage: 'No hay suelos favoritos.',
                  itemTitle: (favorite) => favorite.dominantSoilSeries,
                  itemSubtitle: (favorite) => favorite.unitName,
                  onSelect: _focusFavorite,
                  itemSelected: (favorite) =>
                      favorite.id == _searchSelectedFeature?.id,
                  leadingKey: (favorite) =>
                      ValueKey('desktop-remove-favorite-${favorite.id}'),
                  leadingTooltip: 'Quitar de favoritos',
                  onLeadingTap: _removeFavoriteFromDesktopPanel,
                  onDismiss: _closeDesktopPanel,
                ),
            },
          );
          return _DesktopPanelTransition(panelKey: section, child: panel);
        }
        if (feature == null &&
            selectedMeasurement == null &&
            _desktopSelectedMarker == null) {
          return const _DesktopPanelTransition(
            panelKey: 'empty',
            child: SizedBox.shrink(),
          );
        }

        return _DesktopPanelTransition(
          panelKey:
              feature?.id ??
              selectedMeasurement?.id ??
              _desktopSelectedMarker!.id,
          child: SuelosArFloatingInformationPanel(
            child: _DesktopMapInformationPanel(
              feature: feature,
              measurement: feature == null ? selectedMeasurement : null,
              marker: feature == null && selectedMeasurement == null
                  ? _desktopSelectedMarker
                  : null,
              onOpenFeatureDetails: feature == null
                  ? null
                  : () => unawaited(_showFeatureAttributes(feature)),
              featureIsFavorite:
                  feature != null && _favoriteFeatures.containsKey(feature.id),
              onToggleFeatureFavorite: feature == null
                  ? null
                  : () {
                      final series = GisSoilSeries.fromProperties(
                        feature.properties,
                      );
                      setState(() => _toggleFavorite(feature, series));
                    },
              onAnalyzeMeasurement:
                  selectedMeasurement?.type == SavedMeasurementType.area
                  ? () => _analyzeSavedMeasurement(selectedMeasurement!)
                  : null,
              onEditMeasurement: selectedMeasurement == null
                  ? null
                  : () => unawaited(
                      _requestSelectSavedMeasurement(selectedMeasurement),
                    ),
              onHideMeasurement: selectedMeasurement == null
                  ? null
                  : () => unawaited(_hideSavedMeasurement(selectedMeasurement)),
              onOpenMarkerDetails: _desktopSelectedMarker == null
                  ? null
                  : () => unawaited(
                      _showPersonalMarkerDetails(_desktopSelectedMarker!),
                    ),
              onEditMarker: _desktopSelectedMarker == null
                  ? null
                  : () =>
                        unawaited(_editPersonalMarker(_desktopSelectedMarker!)),
              onDeleteMarker: _desktopSelectedMarker == null
                  ? null
                  : () => unawaited(
                      _confirmDeletePersonalMarker(_desktopSelectedMarker!),
                    ),
              markerDate: _desktopSelectedMarker == null
                  ? null
                  : _formatPersonalMarkerDate(
                      _desktopSelectedMarker!.createdAt,
                    ),
              onExportMeasurementPdf: selectedMeasurement == null
                  ? null
                  : () => _exportSavedMeasurementPdf(selectedMeasurement),
              onExportMeasurementGeoJson: selectedMeasurement == null
                  ? null
                  : () => _exportSavedMeasurementGeoJson(selectedMeasurement),
              onExportMeasurementCsv: selectedMeasurement == null
                  ? null
                  : () => _exportSavedMeasurementCsv(selectedMeasurement),
              onDeleteMeasurement: selectedMeasurement == null
                  ? null
                  : () => _deleteSavedMeasurement(selectedMeasurement),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCompactMapHeader(
    BuildContext context,
    bool showsMeasurement, {
    required bool portraitMobile,
    required bool androidPhoneLandscape,
  }) {
    final collapseTitle =
        portraitMobile &&
        (showsMeasurement ||
            _isPersonalMarkerMode ||
            MediaQuery.sizeOf(context).width < 340);
    final cardPadding = portraitMobile
        ? const EdgeInsets.symmetric(horizontal: 6)
        : const EdgeInsets.symmetric(horizontal: 10);
    final includeActionSpacing =
        !(portraitMobile &&
            showsMeasurement &&
            MediaQuery.sizeOf(context).width < 360);
    return _SynchronizedMapHeaderTransition(
      titleVisible: !collapseTitle,
      undoVisible: showsMeasurement && _activeSavedMeasurementId == null,
      clearVisible: showsMeasurement,
      builder: (context, titleFactor, undoFactor, clearFactor) {
        final titleCard = _MapTopBarCard(
          padding: cardPadding,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FloatingAppBarBackButton(
                onPressed: () => Navigator.maybePop(context),
              ),
              _MapHeaderTransitionItem(
                key: const ValueKey('map-header-title-transition'),
                factor: titleFactor,
                child: Row(
                  key: const ValueKey('expanded-map-title'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(width: 12),
                    Text(
                      portraitMobile ? 'Mapa' : 'Mapa de suelos',
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            ],
          ),
        );
        final actionCard = _MapTopBarCard(
          padding: cardPadding,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _MapChromeIconButton(
                tooltip: 'Abrir marcadores personales',
                icon: const Icon(Icons.bookmarks),
                onPressed: _openPersonalMarkers,
                includeOuterSpacing: includeActionSpacing,
              ),
              _MapChromeIconButton(
                tooltip: 'Abrir mediciones',
                icon: const Icon(Icons.history),
                onPressed: _openMeasurements,
                includeOuterSpacing: includeActionSpacing,
              ),
              _MapHeaderTransitionItem(
                key: const ValueKey('map-header-undo-transition'),
                factor: undoFactor,
                child: _MapChromeIconButton(
                  key: const ValueKey('compact-map-header-undo-button'),
                  tooltip: 'Deshacer último punto',
                  icon: const Icon(AppIcons.undo),
                  onPressed: _undoMeasurementPoint,
                  includeOuterSpacing: includeActionSpacing,
                ),
              ),
              _MapHeaderTransitionItem(
                key: const ValueKey('map-header-clear-transition'),
                factor: clearFactor,
                child: _MapChromeIconButton(
                  key: const ValueKey('compact-map-header-clear-button'),
                  tooltip: 'Limpiar medición',
                  icon: const Icon(AppIcons.delete),
                  onPressed: _clearMeasurement,
                  includeOuterSpacing: includeActionSpacing,
                ),
              ),
              _buildCompactSearchAction(
                context,
                includeOuterSpacing: includeActionSpacing,
              ),
            ],
          ),
        );
        final positionedActionCard = androidPhoneLandscape
            ? Padding(
                padding: const EdgeInsets.only(
                  right: _androidLandscapeToolClearance,
                ),
                child: actionCard,
              )
            : actionCard;
        return SafeArea(
          minimum: EdgeInsets.fromLTRB(
            androidPhoneLandscape ? 8 : 12,
            8,
            12,
            0,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [titleCard, const Spacer(), positionedActionCard],
          ),
        );
      },
    );
  }

  Widget _buildCompactSearchAction(
    BuildContext context, {
    bool includeOuterSpacing = true,
  }) {
    return SearchAnchor(
      viewBuilder: _buildSearchView,
      viewOnOpen: _handleSearchViewOpen,
      viewOnClose: _handleSearchViewClose,
      viewHintText: 'Buscar localidad, unidad o serie...',
      viewBackgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      viewSurfaceTintColor: Colors.transparent,
      viewElevation: 8,
      viewShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
      ),
      viewBarPadding: const EdgeInsets.symmetric(horizontal: 16),
      headerHeight: 64,
      viewConstraints: BoxConstraints(
        minWidth: math.min(320, MediaQuery.sizeOf(context).width - 24),
        maxWidth: MediaQuery.sizeOf(context).width - 24,
        maxHeight: MediaQuery.sizeOf(context).height - 32,
      ),
      viewPadding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
      builder: (context, controller) => _MapChromeIconButton(
        tooltip: 'Buscar',
        icon: const Icon(AppIcons.search),
        onPressed: controller.openView,
        includeOuterSpacing: includeOuterSpacing,
      ),
      suggestionsBuilder: _buildSearchSuggestions,
    );
  }

  Widget _buildSearchView(Iterable<Widget> suggestions) {
    return _SearchViewLayoutObserver(
      onCoverageChanged: _handleSearchCoverageChanged,
      suggestions: suggestions,
    );
  }

  void _handleSearchViewOpen() {
    if (!mounted || _isSearchViewOpen) return;
    _isSearchViewOpen = true;
  }

  void _handleSearchViewClose() {
    if (!mounted || !_isSearchViewOpen) return;
    _isSearchViewOpen = false;
    _updateMapOcclusion(_searchOcclusionToken, 0);
  }

  void _handleSearchCoverageChanged(double coverage) {
    if (!mounted || !_isSearchViewOpen) return;
    _updateMapOcclusion(_searchOcclusionToken, coverage);
  }

  void _updateMapOcclusion(Object source, double coverage) {
    if (!mounted) return;
    if (coverage <= 0 || !coverage.isFinite) {
      _mapOcclusions.remove(source);
    } else {
      _mapOcclusions[source] = coverage.clamp(0, 1);
    }
    final shouldPause = _mapOcclusions.values.any(
      (value) => value >= _mapOcclusionThreshold,
    );
    if (shouldPause == _mapVisualsPaused) return;
    setState(() => _mapVisualsPaused = shouldPause);
  }

  Future<void> _initializeArchive() async {
    if (_disableGisTilePipelineForDiagnostic) return;
    try {
      final archiveInfo = await _repository.initialize();
      if (!mounted) {
        return;
      }

      setState(() {
        _archiveInfo = archiveInfo;
      });

      if (_isMapReady) {
        unawaited(_loadVisibleTiles(_mapController.camera, archiveInfo));
      }
    } catch (_) {
      if (!mounted) {
        return;
      }

      _updateOverlay(
        isLoading: false,
        error: 'No se pudo cargar la información geográfica.',
      );
    }
  }

  Widget _buildMap(GisArchiveInfo archiveInfo, {bool desktopShell = false}) {
    _renderMetrics.mapBuildCount++;
    final colorScheme = Theme.of(context).colorScheme;
    final measurementMode = _measurementMode;
    final renderedMeasurementMode = measurementMode ?? _retainedMeasurementMode;
    final compactLayout = MediaQuery.sizeOf(context).width < 600;
    final androidPhoneLandscape = isSuelosArAndroidPhoneLandscape(context);
    final topControlOffset = compactLayout ? 154.0 : 96.0;
    final selectedSavedMeasurement = _savedMeasurements
        .where(
          (measurement) =>
              measurement.id == _highlightedSavedMeasurementId &&
              measurement.isVisible,
        )
        .firstOrNull;
    final showsMeasurementEditor = switch (measurementMode) {
      _MeasurementMode.distance => _distanceMeasurementPoints.isNotEmpty,
      _MeasurementMode.area => _areaMeasurementPoints.length >= 3,
      null => false,
    };

    return Stack(
      fit: StackFit.expand,
      children: [
        FlutterMap(
          key: _mapKey,
          mapController: _mapController,
          options: MapOptions(
            initialCenter: _buenosAiresCenter,
            initialZoom: _initialZoom,
            minZoom: math.max(_minimumMapZoom, archiveInfo.minZoom.toDouble()),
            maxZoom: archiveInfo.maxZoom + 2,
            backgroundColor: colorScheme.surfaceContainerLowest,
            interactionOptions: InteractionOptions(
              flags: _draggedAreaVertexIndex == null
                  ? InteractiveFlag.all
                  : InteractiveFlag.all &
                        ~InteractiveFlag.drag &
                        ~InteractiveFlag.flingAnimation &
                        ~InteractiveFlag.pinchMove,
            ),
            onMapReady: () {
              _isMapReady = true;
              _updateMapViewportState(_mapController.camera);
              if (!_disableGisTilePipelineForDiagnostic) {
                unawaited(
                  _loadVisibleTiles(_mapController.camera, archiveInfo),
                );
              }
              if (!_disableGeolocatorForDiagnostic &&
                  _isFollowingLocation &&
                  _currentLocation != null) {
                _moveMapToLocation(_currentLocation!);
              }
            },
            onPositionChanged: (camera, hasGesture) {
              if (hasGesture) {
                _isFollowingLocation = false;
              }
              _updateMapViewportState(camera);
              if (!_disableGisTilePipelineForDiagnostic) {
                _scheduleTileLoad(camera, archiveInfo);
              }
            },
            onMapEvent: (event) {
              _updateMapViewportState(event.camera);
            },
            onTap: _disableGisTilePipelineForDiagnostic ? null : _handleMapTap,
          ),
          children: [
            if (!_mapVisualsPaused && _showReferenceBasemap)
              const Positioned.fill(child: OfflineReferenceMapLayer()),
            if (!_disableGisTilePipelineForDiagnostic &&
                !_mapVisualsPaused &&
                _showSoilPolygons)
              Positioned.fill(
                child: _GisVisibleTileLayers(
                  snapshotListenable: _visibleTileSnapshot,
                  renderMetrics: _renderMetrics,
                ),
              ),
            if (!_mapVisualsPaused && _showReferenceBasemap)
              const Positioned.fill(
                child: OfflineReferenceMapLayer(foreground: true),
              ),
            if (!_disableGisTilePipelineForDiagnostic && !_mapVisualsPaused)
              if (_currentLocation case final location?)
                AnimatedBuilder(
                  animation: SettingsService.instance,
                  builder: (context, _) => _CurrentLocationLayer(
                    location: location,
                    showAccuracyCircle:
                        SettingsService.instance.showGpsAccuracyCircle,
                  ),
                ),
            if (!_disableGisTilePipelineForDiagnostic &&
                !_mapVisualsPaused &&
                _savedMeasurements.isNotEmpty)
              _SavedMeasurementsLayer(
                measurements: _savedMeasurements
                    .where((measurement) => measurement.isVisible)
                    .toList(growable: false),
                highlightedMeasurementId: _highlightedSavedMeasurementId,
                showLabels: measurementMode == null,
                onHideMeasurement: _hideSavedMeasurement,
                onSelectMeasurement: _previewSavedMeasurement,
              ),
            if (!_disableGisTilePipelineForDiagnostic &&
                !_mapVisualsPaused &&
                _activeSavedMeasurementId != null)
              Positioned.fill(
                child: _SavedMeasurementLabels(
                  measurements: _orderedSavedMeasurementsForLabels(
                    _savedMeasurements
                        .where((measurement) => measurement.isVisible)
                        .toList(growable: false),
                  ),
                  selectedMeasurementId: _highlightedSavedMeasurementId,
                  hoveredMeasurementId: null,
                  onHideMeasurement: _hideSavedMeasurement,
                  onSelectMeasurement: _previewSavedMeasurement,
                  onHoverMeasurement: (_) {},
                ),
              ),
            if (!_disableGisTilePipelineForDiagnostic &&
                !_mapVisualsPaused &&
                _personalMarkers.isNotEmpty)
              MarkerLayer(
                markers: _personalMarkers
                    .map((marker) {
                      final point = _safeLatLng(
                        marker.latitude,
                        marker.longitude,
                      );
                      if (point == null) return null;
                      return Marker(
                        key: ValueKey('personal-marker-${marker.id}'),
                        point: point,
                        width: 44,
                        height: 44,
                        alignment: Alignment.bottomCenter,
                        child: GestureDetector(
                          key: ValueKey('marker-hit-target-${marker.id}'),
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _handlePersonalMarkerTap(marker),
                          child: Center(
                            child: Material(
                              color: colorScheme.surface,
                              elevation: 2,
                              shadowColor: colorScheme.shadow.withValues(
                                alpha: 0.18,
                              ),
                              shape: const CircleBorder(),
                              clipBehavior: Clip.antiAlias,
                              child: SizedBox.square(
                                dimension: 36,
                                child: Icon(
                                  personalMarkerCategoryIcon(marker.category),
                                  size: 22,
                                  color: const Color.fromARGB(255, 209, 19, 19),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    })
                    .whereType<Marker>()
                    .toList(growable: false),
              ),
            if (!_disableGisTilePipelineForDiagnostic &&
                !_mapVisualsPaused &&
                renderedMeasurementMode != null &&
                _hasMeasurementPoints)
              _MeasurementLayer(
                mode: renderedMeasurementMode,
                isEditing: measurementMode != null,
                distancePoints: _distanceMeasurementPoints,
                areaPoints: _areaMeasurementPoints,
                selectedColor: _measurementColor,
                draggedAreaVertexIndex: _draggedAreaVertexIndex,
                onStartAreaVertexDrag: _startAreaVertexDrag,
                onMoveAreaVertex: _moveAreaVertex,
                onEndAreaVertexDrag: _endAreaVertexDrag,
                onDeleteAreaVertex: _deleteAreaVertex,
                onColorChanged: _setMeasurementColor,
                onSave: _saveCurrentMeasurement,
                isSavedMeasurement: _activeSavedMeasurementId != null,
                onHideSavedMeasurement: _hideCurrentSavedMeasurement,
                onDeleteSavedMeasurement: _deleteCurrentSavedMeasurement,
                hasUnsavedChanges: _measurementHasUnsavedChanges,
                canSave: _isCurrentMeasurementComplete,
                onUndo: _undoMeasurementPoint,
                onClear: _clearMeasurement,
                onExit: _exitMeasurement,
                onAnalyze: _showParcelAnalysis,
                onExport: _exportCurrentMeasurementPdf,
              ),
          ],
        ),
        if (!_mapVisualsPaused)
          Positioned.fill(
            child: ValueListenableBuilder<_MapOverlayState>(
              valueListenable: _overlayState,
              builder: (context, overlayState, child) {
                return Stack(
                  children: [
                    if (overlayState.isLoading)
                      const Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: LinearProgressIndicator(minHeight: 3),
                      ),
                    if (overlayState.error case final error?)
                      Positioned(
                        left: 16,
                        right: 16,
                        bottom: 16,
                        child: Material(
                          color: colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(8),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              error,
                              style: TextStyle(
                                color: colorScheme.onErrorContainer,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        if (!_mapVisualsPaused)
          _buildRightControlRail(
            topInset: topControlOffset,
            showLayers: !desktopShell,
            alignLeft: androidPhoneLandscape,
            desktopStyle: desktopShell,
          ),
        if (!_mapVisualsPaused)
          _MapToolHintOverlay(type: _activeToolHint, top: topControlOffset),
        if (!_mapVisualsPaused && !showsMeasurementEditor && !desktopShell)
          _buildBottomRightControls(),
        if (!_mapVisualsPaused && !showsMeasurementEditor && desktopShell)
          _buildDesktopLocationButton(),
        if (!_mapVisualsPaused &&
            selectedSavedMeasurement != null &&
            !showsMeasurementEditor &&
            !desktopShell)
          _SavedMeasurementActionBar(
            onAnalyze:
                selectedSavedMeasurement.type == SavedMeasurementType.area
                ? () => _analyzeSavedMeasurement(selectedSavedMeasurement)
                : null,
            onExport: () =>
                _exportSavedMeasurementPdf(selectedSavedMeasurement),
            onExportGeoJson: () =>
                _exportSavedMeasurementGeoJson(selectedSavedMeasurement),
            onExportCsv: () =>
                _exportSavedMeasurementCsv(selectedSavedMeasurement),
            onDelete: () => _deleteSavedMeasurement(selectedSavedMeasurement),
            onEdit: () => unawaited(
              _requestSelectSavedMeasurement(selectedSavedMeasurement),
            ),
          ),
        if (!_mapVisualsPaused && !desktopShell)
          _SelectionPreviewOverlay(
            featureListenable: _selectionPreview,
            bottomOffset: compactLayout ? 132 : 72,
            rightInset: compactLayout ? 76 : 16,
            onDismiss: () => _selectionPreview.value = null,
          ),
        if (!_mapVisualsPaused)
          _MapViewportOverlay(
            viewStateListenable: _mapViewportState,
            showScale:
                renderedMeasurementMode == null || !_hasMeasurementPoints,
          ),
      ],
    );
  }

  Widget _buildRightControlRail({
    required double topInset,
    bool showLayers = true,
    bool alignLeft = false,
    bool desktopStyle = false,
  }) {
    return Positioned.fill(
      child: SafeArea(
        minimum: EdgeInsets.fromLTRB(
          alignLeft ? 16 : 0,
          topInset,
          alignLeft ? 0 : 16,
          16,
        ),
        child: Align(
          alignment: alignLeft ? Alignment.topLeft : Alignment.topRight,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _MapCompassControl(
                viewStateListenable: _mapViewportState,
                onResetNorth: _animateMapToNorth,
                desktopStyle: desktopStyle,
                mapController: desktopStyle ? _mapController : null,
              ),
              if (showLayers)
                _MapChromeSurface(
                  includeOuterSpacing: false,
                  child: _LayersMenuButton(
                    showSoilPolygons: _showSoilPolygons,
                    showReferenceBasemap: _showReferenceBasemap,
                    onToggle: _toggleLayerVisibility,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomRightControls() {
    return Positioned.fill(
      child: SafeArea(
        minimum: const EdgeInsets.fromLTRB(0, 16, 16, 16),
        child: Align(
          alignment: Alignment.bottomRight,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ExpandableToolsFab(
                embedded: true,
                onMeasureDistance: () =>
                    _selectMeasurementOption(_MeasurementMenuOption.distance),
                onMeasureArea: () =>
                    _selectMeasurementOption(_MeasurementMenuOption.area),
                onMarkers: _togglePersonalMarkerMode,
                onFavorites: _openFavorites,
                onExitMeasurement: _measurementMode == null
                    ? null
                    : () => unawaited(_finishMeasurement()),
              ),
              const SizedBox(height: 10),
              _MapChromeIconButton(
                includeOuterSpacing: false,
                tooltip: 'Mi ubicación',
                onPressed: _isLocating || _disableGeolocatorForDiagnostic
                    ? null
                    : _centerMapOnCurrentLocationFromUser,
                icon: _isLocating
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(AppIcons.myLocation),
              ),
              AnimatedBuilder(
                animation: SettingsService.instance,
                builder: (context, _) {
                  if (!SettingsService.instance.showZoomLevel) {
                    return const SizedBox.shrink();
                  }
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 10),
                      ValueListenableBuilder<_MapViewportState>(
                        valueListenable: _mapViewportState,
                        builder: (context, viewState, child) =>
                            _ZoomLevelIndicator(zoom: viewState.zoom),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Desktop-only equivalent of the "Mi ubicación" entry inside
  /// [_buildBottomRightControls] — same GPS logic
  /// (`_centerMapOnCurrentLocationFromUser`/`_isLocating`/
  /// `_disableGeolocatorForDiagnostic`), same icon, just presented as its
  /// own floating control (bottom-right, deliberately apart from the
  /// compass in [_buildRightControlRail]) instead of a row inside
  /// `_DesktopMapToolsPanel`'s side menu.
  Widget _buildDesktopLocationButton() {
    return Positioned.fill(
      child: SafeArea(
        minimum: const EdgeInsets.fromLTRB(0, 0, 24, 24),
        child: Align(
          alignment: Alignment.bottomRight,
          child: _MapChromeIconButton(
            includeOuterSpacing: false,
            useDesktopSurfaceStyle: true,
            tooltip: 'Mi ubicación',
            onPressed: _isLocating || _disableGeolocatorForDiagnostic
                ? null
                : _centerMapOnCurrentLocationFromUser,
            icon: _isLocating
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(AppIcons.myLocation),
          ),
        ),
      ),
    );
  }

  List<SavedMeasurement> _orderedSavedMeasurementsForLabels(
    List<SavedMeasurement> measurements,
  ) {
    return [
      ...measurements.where(
        (measurement) => measurement.id != _highlightedSavedMeasurementId,
      ),
      ...measurements.where(
        (measurement) => measurement.id == _highlightedSavedMeasurementId,
      ),
    ];
  }

  void _toggleLayerVisibility(_LayerVisibilityOption option) {
    late final String preferenceKey;
    late final bool isVisible;
    setState(() {
      switch (option) {
        case _LayerVisibilityOption.soilPolygons:
          _showSoilPolygons = !_showSoilPolygons;
          preferenceKey = _showSoilPolygonsPreferenceKey;
          isVisible = _showSoilPolygons;
        case _LayerVisibilityOption.referenceBasemap:
          _showReferenceBasemap = !_showReferenceBasemap;
          preferenceKey = _showReferenceBasemapPreferenceKey;
          isVisible = _showReferenceBasemap;
      }
    });
    _desktopLayersOverlay?.markNeedsBuild();
    unawaited(_persistMapDisplayPreference(preferenceKey, isVisible));
  }

  Future<void> _loadMapDisplayPreferences() async {
    final preferences = await SharedPreferences.getInstance();
    final showSoilPolygons =
        preferences.getBool(_showSoilPolygonsPreferenceKey) ?? true;
    final showReferenceBasemap =
        preferences.getBool(_showReferenceBasemapPreferenceKey) ?? true;
    if (!mounted) return;
    setState(() {
      _showSoilPolygons = showSoilPolygons;
      _showReferenceBasemap = showReferenceBasemap;
    });
  }

  Future<void> _persistMapDisplayPreference(String key, bool value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(key, value);
  }

  void _togglePersonalMarkerMode() {
    if (_isPersonalMarkerMode) {
      setState(() => _setInteractionMode(_InteractionMode.none));
      return;
    }
    unawaited(_activatePersonalMarkerMode());
  }

  Future<void> _activatePersonalMarkerMode() async {
    final measurementMode = _measurementMode;
    if (measurementMode != null && _measurementHasUnsavedChanges) {
      final decision = await _showMeasurementDecisionDialog(
        '¿Querés guardar los cambios antes de agregar un marcador?',
      );
      if (!mounted ||
          decision == null ||
          decision == _MeasurementExitDecision.cancel) {
        return;
      }
      if (decision == _MeasurementExitDecision.save) {
        await _persistMeasurement(measurementMode);
        if (!mounted) return;
      }
    }
    setState(() {
      _invalidateParcelAnalysis();
      _distanceMeasurementPoints.clear();
      _areaMeasurementPoints.clear();
      _retainedMeasurementMode = null;
      _activeSavedMeasurementId = null;
      _highlightedSavedMeasurementId = null;
      _savedMeasurementGeometrySignature = null;
      _savedMeasurementColorId = null;
      _setInteractionMode(_InteractionMode.addMarker);
      _activeToolHint = _MapToolHintType.marker;
      if (_usesDesktopMapShell) {
        _closeDesktopPanel();
      }
    });
  }

  _DesktopActiveMode? get _desktopActiveMode {
    if (_isPersonalMarkerMode) return _DesktopActiveMode.marker;
    return switch (_measurementMode) {
      _MeasurementMode.distance => _DesktopActiveMode.distance,
      _MeasurementMode.area => _DesktopActiveMode.area,
      null => null,
    };
  }

  void _cancelDesktopTemporaryMode() {
    if (_desktopActiveMode == null) return;
    setState(() {
      _invalidateParcelAnalysis();
      _setInteractionMode(_InteractionMode.none);
      _retainedMeasurementMode = null;
      _activeSavedMeasurementId = null;
      _savedMeasurementGeometrySignature = null;
      _savedMeasurementColorId = null;
      _distanceMeasurementPoints.clear();
      _areaMeasurementPoints.clear();
      _draggedAreaVertexIndex = null;
      _suppressNextMapTap = false;
      _activeToolHint = null;
    });
  }

  void _selectDesktopPanelSection(_DesktopPanelSection section) {
    if (_desktopActiveMode != null) {
      _cancelDesktopTemporaryMode();
    }
    final currentSection = _desktopPanelSectionState.value;
    if (currentSection == section) {
      _closeDesktopPanel();
      return;
    }
    _removeDesktopLayersOverlay();
    _desktopPanelSectionState.value = section;
    if (section == _DesktopPanelSection.layers) {
      _showDesktopLayersOverlay();
    }
  }

  void _closeDesktopPanel() {
    _removeDesktopLayersOverlay();
    _desktopPanelSectionState.value = null;
  }

  void _showDesktopLayersOverlay() {
    final overlay = Overlay.of(context);
    final entry = OverlayEntry(
      builder: (overlayContext) {
        final layout = SuelosArResponsiveLayout.fromContext(overlayContext);
        return SizedBox.expand(
          child: SafeArea(
            child: Padding(
              padding: layout.pagePadding.add(const EdgeInsets.only(top: 76)),
              child: Align(
                alignment: Alignment.centerRight,
                child: SuelosArFloatingInformationPanel(
                  child: _DesktopLayersPanel(
                    showSoilPolygons: _showSoilPolygons,
                    showReferenceBasemap: _showReferenceBasemap,
                    onToggleSoilPolygons: () => _toggleLayerVisibility(
                      _LayerVisibilityOption.soilPolygons,
                    ),
                    onToggleReferenceBasemap: () => _toggleLayerVisibility(
                      _LayerVisibilityOption.referenceBasemap,
                    ),
                    onDismiss: _closeDesktopPanel,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    _desktopLayersOverlay = entry;
    overlay.insert(entry);
  }

  void _removeDesktopLayersOverlay() {
    final entry = _desktopLayersOverlay;
    if (entry == null) return;
    _desktopLayersOverlay = null;
    entry.remove();
    entry.dispose();
  }

  void _selectDesktopSearchResult(_SoilSeriesSearchEntry entry) {
    setState(() {
      _desktopRecentSearches.removeWhere(
        (recent) =>
            recent.type == entry.type && recent.feature.id == entry.feature.id,
      );
      _desktopRecentSearches.insert(0, entry);
      if (_desktopRecentSearches.length > 5) {
        _desktopRecentSearches.removeRange(5, _desktopRecentSearches.length);
      }
    });
    if (entry.type == _MapSearchEntryType.soilSeries) {
      unawaited(_showSeriesUnitChoices(entry));
      return;
    }
    setState(() => _selectSearchSuggestion(entry));
  }

  void _startDesktopMarkerPlacement() {
    _closeDesktopPanel();
    if (!_isPersonalMarkerMode) {
      _togglePersonalMarkerMode();
    }
  }

  bool get _hasMeasurementPoints =>
      _distanceMeasurementPoints.isNotEmpty ||
      _areaMeasurementPoints.isNotEmpty;

  void _selectMeasurementOption(_MeasurementMenuOption option) {
    if (option == _MeasurementMenuOption.exit) {
      unawaited(_finishMeasurement());
      return;
    }
    final targetMode = option == _MeasurementMenuOption.area
        ? _MeasurementMode.area
        : _MeasurementMode.distance;
    if (_measurementMode != null &&
        _measurementMode != targetMode &&
        _measurementHasUnsavedChanges) {
      unawaited(_confirmModeChange(option));
      return;
    }
    _activateMeasurementMode(option);
  }

  void _activateMeasurementMode(_MeasurementMenuOption option) {
    if (option != _MeasurementMenuOption.exit) {
      _selectionPreview.value = null;
    }
    final resumesSavedMeasurement =
        _measurementMode == null &&
        ((option == _MeasurementMenuOption.distance &&
                _retainedMeasurementMode == _MeasurementMode.distance &&
                _distanceMeasurementPoints.isNotEmpty) ||
            (option == _MeasurementMenuOption.area &&
                _retainedMeasurementMode == _MeasurementMode.area &&
                _areaMeasurementPoints.isNotEmpty));
    setState(() {
      if (_usesDesktopMapShell && option != _MeasurementMenuOption.exit) {
        _closeDesktopPanel();
      }
      switch (option) {
        case _MeasurementMenuOption.distance:
          _invalidateParcelAnalysis();
          _setInteractionMode(_InteractionMode.measureDistance);
          _retainedMeasurementMode = _MeasurementMode.distance;
          _areaMeasurementPoints.clear();
          if (!resumesSavedMeasurement) {
            _activeSavedMeasurementId = null;
            _savedMeasurementGeometrySignature = null;
            _savedMeasurementColorId = null;
            _measurementColor =
                SettingsService.instance.defaultMeasurementColor;
          }
          _activeToolHint = resumesSavedMeasurement
              ? null
              : _MapToolHintType.measureDistance;
        case _MeasurementMenuOption.area:
          _invalidateParcelAnalysis();
          _setInteractionMode(_InteractionMode.measureArea);
          _retainedMeasurementMode = _MeasurementMode.area;
          _distanceMeasurementPoints.clear();
          if (!resumesSavedMeasurement) {
            _activeSavedMeasurementId = null;
            _savedMeasurementGeometrySignature = null;
            _savedMeasurementColorId = null;
            _measurementColor =
                SettingsService.instance.defaultMeasurementColor;
          }
          _activeToolHint = resumesSavedMeasurement
              ? null
              : _MapToolHintType.measureArea;
        case _MeasurementMenuOption.exit:
          _setInteractionMode(_InteractionMode.none);
      }
    });
  }

  void _undoMeasurementPoint() {
    setState(() {
      if (_measurementMode == _MeasurementMode.area) {
        if (_areaMeasurementPoints.isNotEmpty) {
          _invalidateParcelAnalysis();
          _areaMeasurementPoints.removeLast();
        }
      } else if (_distanceMeasurementPoints.isNotEmpty) {
        _distanceMeasurementPoints.removeLast();
      }
    });
  }

  void _clearMeasurement() {
    setState(() {
      _invalidateParcelAnalysis();
      _distanceMeasurementPoints.clear();
      _areaMeasurementPoints.clear();
      _retainedMeasurementMode = _measurementMode;
      _draggedAreaVertexIndex = null;
      _suppressNextMapTap = false;
    });
  }

  void _exitMeasurement() {
    unawaited(_finishMeasurement());
  }

  Future<void> _finishMeasurement() async {
    if (_measurementMode == null) {
      return;
    }
    final mode = _measurementMode!;
    final wasSavedMeasurement = _activeSavedMeasurementId != null;
    if (_measurementHasUnsavedChanges) {
      final decision = await _showMeasurementDecisionDialog(
        '¿Querés guardar esta medición antes de salir?',
      );
      if (!mounted) return;
      if (decision == null || decision == _MeasurementExitDecision.cancel) {
        return;
      }
      if (decision == _MeasurementExitDecision.save) {
        await _persistMeasurement(mode);
        if (!mounted) return;
      }
    }
    setState(() {
      _setInteractionMode(_InteractionMode.none);
      _draggedAreaVertexIndex = null;
      _suppressNextMapTap = false;
      _activeToolHint = null;
      if (wasSavedMeasurement) {
        _distanceMeasurementPoints.clear();
        _areaMeasurementPoints.clear();
        _activeSavedMeasurementId = null;
        _savedMeasurementGeometrySignature = null;
        _savedMeasurementColorId = null;
      } else {
        _distanceMeasurementPoints.clear();
        _areaMeasurementPoints.clear();
        _retainedMeasurementMode = null;
      }
    });
  }

  Future<void> _confirmModeChange(_MeasurementMenuOption option) async {
    final mode = _measurementMode;
    if (mode == null) {
      _activateMeasurementMode(option);
      return;
    }
    final decision = await _showMeasurementDecisionDialog(
      '¿Querés guardar los cambios antes de cambiar de medición?',
    );
    if (!mounted ||
        decision == null ||
        decision == _MeasurementExitDecision.cancel) {
      return;
    }
    if (decision == _MeasurementExitDecision.save) {
      await _persistMeasurement(mode);
      if (!mounted) return;
    }
    _activateMeasurementMode(option);
  }

  Future<_MeasurementExitDecision?> _showMeasurementDecisionDialog(
    String title,
  ) async {
    if (_isMeasurementDialogVisible) return null;
    _isMeasurementDialogVisible = true;
    try {
      return await showDialog<_MeasurementExitDecision>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, _MeasurementExitDecision.cancel),
              child: const Text('Cancelar'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(
                dialogContext,
                _MeasurementExitDecision.discard,
              ),
              child: const Text('Descartar'),
            ),
            FilledButton(
              onPressed: _isCurrentMeasurementComplete
                  ? () => Navigator.pop(
                      dialogContext,
                      _MeasurementExitDecision.save,
                    )
                  : null,
              child: const Text('Guardar'),
            ),
          ],
        ),
      );
    } finally {
      _isMeasurementDialogVisible = false;
    }
  }

  Future<void> _persistMeasurement(_MeasurementMode mode) async {
    final preferences = await SharedPreferences.getInstance();
    final encoded =
        preferences.getStringList(SavedMeasurement.storageKey) ??
        const <String>[];
    final existing = <SavedMeasurement>[];
    for (final value in encoded) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map<String, dynamic>) {
          existing.add(SavedMeasurement.fromJson(decoded));
        }
      } on FormatException {
        // Preserve valid measurements if a local record is malformed.
      } on TypeError {
        // Preserve records written with the current schema.
      }
    }

    final type = mode == _MeasurementMode.distance
        ? SavedMeasurementType.distance
        : SavedMeasurementType.area;
    final existingIndex = _activeSavedMeasurementId == null
        ? -1
        : existing.indexWhere(
            (measurement) => measurement.id == _activeSavedMeasurementId,
          );
    final previous = existingIndex == -1 ? null : existing[existingIndex];
    final namePrefix = type == SavedMeasurementType.distance
        ? 'Distancia'
        : 'Área';
    var highestNumber = 0;
    final automaticNamePattern = RegExp(
      '^${RegExp.escape(namePrefix)} ([0-9]+)\$',
    );
    for (final existingMeasurement in existing) {
      if (existingMeasurement.type != type) continue;
      final match = automaticNamePattern.firstMatch(existingMeasurement.name);
      final number = match == null ? null : int.tryParse(match.group(1)!);
      if (number != null && number > highestNumber) highestNumber = number;
    }
    final nextNumber = highestNumber + 1;
    final points = mode == _MeasurementMode.distance
        ? _distanceMeasurementPoints
        : _areaMeasurementPoints;
    final now = DateTime.now();
    final measurement = SavedMeasurement(
      id: previous?.id ?? 'measurement-${now.microsecondsSinceEpoch}',
      type: type,
      name: previous?.name ?? '$namePrefix $nextNumber',
      geometry: List<LatLng>.unmodifiable(points),
      createdAt: previous?.createdAt ?? now,
      distanceMeters: mode == _MeasurementMode.distance
          ? _MeasurementLayer._calculatePathDistance(points)
          : null,
      areaSquareMeters: mode == _MeasurementMode.area
          ? _MeasurementLayer._calculateArea(points)
          : null,
      perimeterMeters: mode == _MeasurementMode.area
          ? _MeasurementLayer._calculatePerimeter(points)
          : null,
      isVisible: previous?.isVisible ?? true,
      colorId: _measurementColor.id,
      uuid: previous?.uuid ?? UuidV4.generate(),
      updatedAt: now.toUtc(),
      deletedAt: previous?.deletedAt,
      syncState: SyncState.pendingUpload,
    );
    if (existingIndex == -1) {
      existing.add(measurement);
    } else {
      existing[existingIndex] = measurement;
    }
    await SyncAwareLocalRepository.instance.saveMeasurements(existing);
    if (existingIndex == -1) {
      unawaited(
        mode == _MeasurementMode.area
            ? AnalyticsService.instance.logMeasureArea()
            : AnalyticsService.instance.logMeasureDistance(),
      );
    }
    if (!mounted) return;
    setState(() {
      final renderedIndex = _savedMeasurements.indexWhere(
        (item) => item.id == measurement.id,
      );
      if (renderedIndex == -1) {
        _savedMeasurements.add(measurement);
      } else {
        _savedMeasurements[renderedIndex] = measurement;
      }
      _activeSavedMeasurementId = measurement.id;
      _savedMeasurementGeometrySignature = _currentMeasurementSignature;
      _savedMeasurementColorId = _measurementColor.id;
    });
  }

  bool get _isCurrentMeasurementComplete => switch (_measurementMode) {
    _MeasurementMode.distance => _distanceMeasurementPoints.length >= 2,
    _MeasurementMode.area => _areaMeasurementPoints.length >= 3,
    null => false,
  };

  String get _currentMeasurementSignature {
    final points = _measurementMode == _MeasurementMode.area
        ? _areaMeasurementPoints
        : _distanceMeasurementPoints;
    return points
        .map((point) => '${point.latitude},${point.longitude}')
        .join(';');
  }

  bool get _measurementHasUnsavedChanges =>
      _currentMeasurementSignature !=
          (_savedMeasurementGeometrySignature ?? '') ||
      (_activeSavedMeasurementId != null &&
          _measurementColor.id != _savedMeasurementColorId);

  Future<void> _saveCurrentMeasurement() async {
    final mode = _measurementMode;
    if (mode == null || !_isCurrentMeasurementComplete) return;
    await _persistMeasurement(mode);
    if (!mounted) return;
    unawaited(
      AppNotification.show(
        context,
        message: 'Medición guardada.',
        type: AppNotificationType.success,
        bottomOffset: 180,
      ),
    );
  }

  Future<void> _exportCurrentMeasurementPdf() async {
    final mode = _measurementMode;
    if (mode == null || !_isCurrentMeasurementComplete) return;

    final type = mode == _MeasurementMode.area
        ? SavedMeasurementType.area
        : SavedMeasurementType.distance;
    final points = mode == _MeasurementMode.area
        ? _areaMeasurementPoints
        : _distanceMeasurementPoints;
    final exportData = const MeasurementExportService().fromCurrentMeasurement(
      type: type,
      geometry: points,
      createdAt: DateTime.now(),
      title: mode == _MeasurementMode.area
          ? 'Medición de área'
          : 'Medición de distancia',
      distanceMeters: mode == _MeasurementMode.distance
          ? _MeasurementLayer._calculatePathDistance(points)
          : null,
      areaSquareMeters: mode == _MeasurementMode.area
          ? _MeasurementLayer._calculateArea(points)
          : null,
      perimeterMeters: mode == _MeasurementMode.area
          ? _MeasurementLayer._calculatePerimeter(points)
          : null,
    );

    await _shareMeasurementExportData(exportData);
  }

  Future<void> _exportSavedMeasurementPdf(SavedMeasurement measurement) async {
    final exportData = _exportDataForSavedMeasurement(measurement);
    await _shareMeasurementExportFile(
      createFile: () => MeasurementPdfExporter().export(exportData),
      mimeType: 'application/pdf',
      text: 'Informe de mediciÃ³n de SuelosAR',
    );
  }

  Future<void> _exportSavedMeasurementGeoJson(
    SavedMeasurement measurement,
  ) async {
    final exportData = _exportDataForSavedMeasurement(measurement);
    await _shareMeasurementExportFile(
      createFile: () => const MeasurementGeoJsonExporter().export(exportData),
      mimeType: 'application/geo+json',
      text: 'MediciÃ³n de SuelosAR en GeoJSON',
    );
  }

  Future<void> _exportSavedMeasurementCsv(SavedMeasurement measurement) async {
    final exportData = _exportDataForSavedMeasurement(measurement);
    await _shareMeasurementExportFile(
      createFile: () => const MeasurementCsvExporter().export(exportData),
      mimeType: 'text/csv',
      text: 'MediciÃ³n de SuelosAR en CSV',
    );
  }

  MeasurementExportData _exportDataForSavedMeasurement(
    SavedMeasurement measurement,
  ) {
    final isArea = measurement.type == SavedMeasurementType.area;
    return const MeasurementExportService().fromCurrentMeasurement(
      type: measurement.type,
      geometry: measurement.geometry,
      createdAt: measurement.createdAt,
      id: measurement.id,
      title: measurement.name.isEmpty ? null : measurement.name,
      color: measurement.colorId,
      distanceMeters: !isArea
          ? measurement.distanceMeters ??
                _MeasurementLayer._calculatePathDistance(measurement.geometry)
          : null,
      areaSquareMeters: isArea
          ? measurement.areaSquareMeters ??
                _MeasurementLayer._calculateArea(measurement.geometry)
          : null,
      perimeterMeters: isArea
          ? measurement.perimeterMeters ??
                _MeasurementLayer._calculatePerimeter(measurement.geometry)
          : null,
    );
  }

  Future<void> _shareMeasurementExportData(
    MeasurementExportData exportData,
  ) async {
    await _shareMeasurementExportFile(
      createFile: () => MeasurementPdfExporter().export(exportData),
      mimeType: 'application/pdf',
      text: 'Informe de mediciÃ³n de SuelosAR',
    );
  }

  Future<void> _shareMeasurementExportFile({
    required Future<File> Function() createFile,
    required String mimeType,
    required String text,
  }) async {
    try {
      final file = await createFile();
      if (!mounted) return;
      await const MeasurementExportShareService().share(
        file: file,
        mimeType: mimeType,
        text: text,
      );
    } catch (_) {
      if (!mounted) return;
      unawaited(
        AppNotification.show(
          context,
          message: 'No se pudo exportar la medición.',
          type: AppNotificationType.error,
          bottomOffset: 120,
        ),
      );
    }
  }

  Future<void> _hideCurrentSavedMeasurement() async {
    final measurement = _savedMeasurements
        .where((item) => item.id == _activeSavedMeasurementId)
        .firstOrNull;
    if (measurement == null) return;
    if (_measurementHasUnsavedChanges) {
      final decision = await _showMeasurementDecisionDialog(
        '¿Querés guardar los cambios antes de ocultar la medición?',
      );
      if (!mounted ||
          decision == null ||
          decision == _MeasurementExitDecision.cancel) {
        return;
      }
      if (decision == _MeasurementExitDecision.save) {
        final mode = _measurementMode;
        if (mode == null) return;
        await _persistMeasurement(mode);
        if (!mounted) return;
      }
    }
    final currentMeasurement = _savedMeasurements
        .where((item) => item.id == measurement.id)
        .firstOrNull;
    if (currentMeasurement == null) return;
    await _hideSavedMeasurement(currentMeasurement);
    if (!mounted) return;
    setState(() {
      _setInteractionMode(_InteractionMode.none);
      _activeSavedMeasurementId = null;
      _savedMeasurementGeometrySignature = null;
      _savedMeasurementColorId = null;
    });
  }

  Future<void> _deleteCurrentSavedMeasurement() async {
    final id = _activeSavedMeasurementId;
    if (id == null) return;
    await _deleteSavedMeasurementById(id, clearEditingState: true);
  }

  Future<void> _deleteSavedMeasurement(SavedMeasurement measurement) async {
    await _deleteSavedMeasurementById(measurement.id, clearEditingState: false);
  }

  Future<void> _deleteSavedMeasurementById(
    String id, {
    required bool clearEditingState,
  }) async {
    final confirmed = await _confirmMeasurementDeletion();
    if (!mounted || !confirmed) return;
    setState(() {
      _savedMeasurements.removeWhere((measurement) => measurement.id == id);
      if (clearEditingState || _activeSavedMeasurementId == id) {
        _setInteractionMode(_InteractionMode.none);
        _activeSavedMeasurementId = null;
        _savedMeasurementGeometrySignature = null;
        _savedMeasurementColorId = null;
        _distanceMeasurementPoints.clear();
        _areaMeasurementPoints.clear();
      }
      _highlightedSavedMeasurementId = null;
    });
    await SyncAwareLocalRepository.instance.saveMeasurements(
      _savedMeasurements,
    );
  }

  Future<bool> _confirmMeasurementDeletion() async {
    if (_isMeasurementDialogVisible) return false;
    _isMeasurementDialogVisible = true;
    try {
      return await confirmDestructiveAction(
        context,
        title: '¿Eliminar medición?',
        message: 'Esta acción elimina la medición permanentemente.',
      );
    } finally {
      _isMeasurementDialogVisible = false;
    }
  }

  Future<void> _loadSavedMeasurements() async {
    final preferences = await SharedPreferences.getInstance();
    final encoded =
        preferences.getStringList(SavedMeasurement.storageKey) ??
        const <String>[];
    final measurements = <SavedMeasurement>[];
    for (final value in encoded) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map<String, dynamic>) {
          measurements.add(SavedMeasurement.fromJson(decoded));
        }
      } on FormatException {
        // Ignore malformed local records without blocking the map.
      } on TypeError {
        // Ignore records that do not match the persisted schema.
      }
    }
    if (!mounted) return;
    setState(() {
      _savedMeasurements
        ..clear()
        ..addAll(measurements);
    });
  }

  void _startAreaVertexDrag(int index, Offset globalPosition) {
    setState(() {
      _draggedAreaVertexIndex = index;
      _suppressNextMapTap = true;
    });
  }

  void _moveAreaVertex(int index, Offset globalPosition) {
    _suppressNextMapTap = false;
    final camera = _mapController.camera;
    if (!_isFiniteCamera(camera) || !_isFiniteOffset(globalPosition)) {
      return;
    }
    final mapContext = _mapKey.currentContext;
    if (mapContext == null) {
      return;
    }
    final renderBox = mapContext.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      return;
    }
    final localPosition = renderBox.globalToLocal(globalPosition);
    if (!_isFiniteOffset(localPosition)) return;
    final point = camera.screenOffsetToLatLng(localPosition);
    if (!_isFiniteLatLng(point)) {
      return;
    }
    final points = _measurementMode == _MeasurementMode.distance
        ? _distanceMeasurementPoints
        : _areaMeasurementPoints;
    if (index >= points.length) return;
    final candidate = List<LatLng>.of(points);
    candidate[index] = point;
    if (_measurementMode == _MeasurementMode.area &&
        _isSelfIntersecting(candidate)) {
      _showInvalidMeasurementMessage();
      return;
    }
    setState(() {
      if (_measurementMode == _MeasurementMode.area) {
        _invalidateParcelAnalysis();
      }
      points[index] = point;
    });
  }

  void _endAreaVertexDrag() {
    if (_draggedAreaVertexIndex == null) {
      return;
    }
    setState(() {
      _draggedAreaVertexIndex = null;
    });
  }

  void _deleteAreaVertex(int index) {
    final isArea = _measurementMode == _MeasurementMode.area;
    final points = isArea ? _areaMeasurementPoints : _distanceMeasurementPoints;
    final minimumPointCount = isArea ? 3 : 1;
    if (points.length <= minimumPointCount || index >= points.length) {
      return;
    }
    setState(() {
      if (isArea) _invalidateParcelAnalysis();
      points.removeAt(index);
    });
  }

  void _invalidateParcelAnalysis() {
    _parcelRevision++;
    _parcelRevisionState.value = _parcelRevision;
    _latestParcelAnalysis = null;
  }

  Future<void> _loadMeasurementColor() async {
    final color = SettingsService.instance.defaultMeasurementColor;
    if (!mounted) {
      return;
    }
    setState(() {
      _measurementColor = color;
    });
  }

  Future<void> _setMeasurementColor(MeasurementColorOption color) async {
    if (_measurementColor == color) {
      return;
    }
    setState(() {
      _measurementColor = color;
    });
    await SettingsService.instance.setDefaultMeasurementColor(color);
  }

  void _showInvalidMeasurementMessage() {
    if (_isInvalidMeasurementWarningVisible) return;
    _isInvalidMeasurementWarningVisible = true;
    AppNotification.show(
      context,
      message: 'El polígono no puede cruzarse.',
      type: AppNotificationType.warning,
      bottomOffset: 180,
    ).whenComplete(() {
      _isInvalidMeasurementWarningVisible = false;
    });
  }

  Future<T?> _showMapBottomSheet<T>({
    required WidgetBuilder builder,
    bool isScrollControlled = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return showModalBottomSheet<T>(
      context: context,
      builder: builder,
      isScrollControlled: isScrollControlled,
      useSafeArea: true,
      showDragHandle: true,
      elevation: 8,
      backgroundColor: colorScheme.surfaceContainerLow,
      barrierColor: colorScheme.scrim.withValues(alpha: 0.32),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      clipBehavior: Clip.antiAlias,
      constraints: BoxConstraints.tightFor(
        width: math.min(MediaQuery.sizeOf(context).width, 760),
      ),
      sheetAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 200),
        reverseDuration: Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      ),
    );
  }

  Future<void> _showParcelAnalysis(
    ParcelAnalysis analysis, {
    List<LatLng>? parcelPoints,
  }) {
    final analyzedPoints = List<LatLng>.unmodifiable(
      parcelPoints ?? _areaMeasurementPoints,
    );
    final revision = _parcelRevision;
    final analysisFuture =
        _calculateParcelAnalysis(analysis, analyzedPoints, revision).then((
          result,
        ) {
          if (revision != _parcelRevision) {
            throw const _ParcelAnalysisInvalidated();
          }
          _latestParcelAnalysis = result;
          return result;
        });
    return _showMapBottomSheet<void>(
      isScrollControlled: true,
      builder: (bottomSheetContext) {
        final textTheme = Theme.of(bottomSheetContext).textTheme;
        final colorScheme = Theme.of(bottomSheetContext).colorScheme;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Análisis del lote',
                  style: textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 24),
                _ParcelAnalysisMetric(
                  label: 'Superficie',
                  value: _MeasurementLayer._formatArea(
                    analysis.totalAreaSquareMeters,
                  ),
                ),
                const SizedBox(height: 12),
                _ParcelAnalysisMetric(
                  label: 'Perímetro',
                  value: _MeasurementLayer._formatDistance(
                    analysis.perimeterMeters,
                  ),
                ),
                const SizedBox(height: 28),
                ValueListenableBuilder<int>(
                  valueListenable: _parcelRevisionState,
                  builder: (context, currentRevision, child) {
                    if (currentRevision != revision) {
                      return Text(
                        'El lote cambió. Volvé a solicitar el análisis.',
                        key: const ValueKey('parcel-analysis-invalidated'),
                        style: textTheme.bodyLarge?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      );
                    }
                    return FutureBuilder<ParcelAnalysis>(
                      future: analysisFuture,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState != ConnectionState.done) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              LinearProgressIndicator(
                                color: colorScheme.primary,
                                backgroundColor:
                                    colorScheme.surfaceContainerHighest,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'Analizando composición del lote...',
                                key: const ValueKey('parcel-analysis-loading'),
                                style: textTheme.bodyLarge?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          );
                        }
                        if (snapshot.hasError) {
                          return Text(
                            snapshot.error is _ParcelAnalysisInvalidated
                                ? 'El lote cambió. Volvé a solicitar el análisis.'
                                : 'No se pudo completar el análisis.',
                            key: ValueKey(
                              snapshot.error is _ParcelAnalysisInvalidated
                                  ? 'parcel-analysis-invalidated'
                                  : 'parcel-analysis-error',
                            ),
                            style: textTheme.bodyLarge?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          );
                        }
                        return _ParcelCompositionContent(
                          analysis: snapshot.requireData,
                        );
                      },
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<ParcelAnalysis> _calculateParcelAnalysis(
    ParcelAnalysis base,
    List<LatLng> parcelPoints,
    int revision,
  ) async {
    if (_disableGisTilePipelineForDiagnostic) {
      return base;
    }
    if (parcelPoints.length < 3) {
      return ParcelAnalysis(
        totalAreaSquareMeters: base.totalAreaSquareMeters,
        perimeterMeters: base.perimeterMeters,
      );
    }

    final zoom = _archiveInfo.maxZoom;
    final parcelBounds = _GisBounds.fromPoints(parcelPoints);
    final tilesAtZoom = 1 << zoom;
    final minX = _longitudeToTileX(
      parcelBounds.west,
      zoom,
    ).clamp(0, tilesAtZoom - 1);
    final maxX = _longitudeToTileX(
      parcelBounds.east,
      zoom,
    ).clamp(0, tilesAtZoom - 1);
    final minY = _latitudeToTileY(
      parcelBounds.north,
      zoom,
    ).clamp(0, tilesAtZoom - 1);
    final maxY = _latitudeToTileY(
      parcelBounds.south,
      zoom,
    ).clamp(0, tilesAtZoom - 1);
    final requiredCoordinates = <GisTileCoordinates>[];
    final missingCoordinates = <GisTileCoordinates>[];
    for (var x = minX; x <= maxX; x++) {
      for (var y = minY; y <= maxY; y++) {
        final coordinates = GisTileCoordinates(zoom: zoom, x: x, y: y);
        requiredCoordinates.add(coordinates);
        if (!_renderedTileCache.containsKey(coordinates)) {
          missingCoordinates.add(coordinates);
        }
      }
    }
    for (final coordinates in requiredCoordinates) {
      _parcelAnalysisTilePins.update(
        coordinates,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }

    try {
      if (missingCoordinates.isNotEmpty) {
        final layers = await Future.wait(
          missingCoordinates.map(_repository.loadTile),
        );
        if (!mounted || revision != _parcelRevision) {
          throw const _ParcelAnalysisInvalidated();
        }
        for (var index = 0; index < missingCoordinates.length; index++) {
          final coordinates = missingCoordinates[index];
          if (!_renderedTileCache.containsKey(coordinates)) {
            _cacheRenderedTile(coordinates, layers[index]);
          }
        }
      }
      if (!mounted || revision != _parcelRevision) {
        throw const _ParcelAnalysisInvalidated();
      }

      final parcelTriangles = _triangulateRing(parcelPoints);
      final processedPolygons = Set<_RenderedGisPolygon>.identity();
      final builders = <String, _ParcelIntersectionBuilder>{};

      for (final coordinates in requiredCoordinates) {
        if (revision != _parcelRevision) {
          throw const _ParcelAnalysisInvalidated();
        }
        final tile = _getRenderedTile(coordinates);
        if (tile == null) continue;
        final parcelTrianglesInTile = _clipTrianglesToTile(
          parcelTriangles,
          coordinates,
        );
        if (parcelTrianglesInTile.isEmpty) continue;
        for (final polygon in tile.polygons) {
          if (!processedPolygons.add(polygon) ||
              polygon.bounds.east < parcelBounds.west ||
              polygon.bounds.west > parcelBounds.east ||
              polygon.bounds.north < parcelBounds.south ||
              polygon.bounds.south > parcelBounds.north) {
            continue;
          }
          final intersection = polygon.intersectParcel(parcelTrianglesInTile);
          if (intersection.areaSquareMeters <= 0.01) continue;

          final feature = polygon.feature;
          final series = GisSoilSeries.fromProperties(feature.properties);
          final builder = builders.putIfAbsent(
            feature.id,
            () => _ParcelIntersectionBuilder(
              featureId: feature.id,
              unitSymbol: feature.properties['SIMBC']?.toString().trim() ?? '',
              dominantSoilSeries: series.isEmpty ? '' : series.first.name,
              capabilityClass:
                  feature.properties['CAP_USO']?.toString().trim() ?? '',
            ),
          );
          builder.add(intersection);
        }
      }

      final intersections = List<ParcelSoilIntersection>.unmodifiable(
        builders.values.map((builder) => builder.build()),
      );
      final composition =
          intersections
              .map(
                (intersection) => ParcelSoilComposition(
                  featureId: intersection.featureId,
                  unitSymbol: intersection.unitSymbol,
                  dominantSoilSeries: intersection.dominantSoilSeries,
                  capabilityClass: intersection.capabilityClass,
                  areaSquareMeters: intersection.areaSquareMeters,
                  percentage: base.totalAreaSquareMeters <= 0
                      ? 0
                      : intersection.areaSquareMeters /
                            base.totalAreaSquareMeters *
                            100,
                ),
              )
              .toList(growable: false)
            ..sort((first, second) {
              final areaComparison = second.areaSquareMeters.compareTo(
                first.areaSquareMeters,
              );
              if (areaComparison != 0) return areaComparison;
              return first.unitSymbol.compareTo(second.unitSymbol);
            });

      return ParcelAnalysis(
        totalAreaSquareMeters: base.totalAreaSquareMeters,
        perimeterMeters: base.perimeterMeters,
        intersections: intersections,
        soilComposition: List<ParcelSoilComposition>.unmodifiable(composition),
        dominantSoilUnit: _dominantCompositionValue(
          composition,
          (item) => item.unitSymbol,
        ),
        dominantSoilSeries: _dominantCompositionValue(
          composition,
          (item) => item.dominantSoilSeries,
        ),
        dominantCapabilityClass: _dominantCompositionValue(
          composition,
          (item) => item.capabilityClass,
        ),
      );
    } finally {
      for (final coordinates in requiredCoordinates) {
        final count = _parcelAnalysisTilePins[coordinates];
        if (count == null || count <= 1) {
          _parcelAnalysisTilePins.remove(coordinates);
        } else {
          _parcelAnalysisTilePins[coordinates] = count - 1;
        }
      }
      _enforceRenderedTileCacheLimit();
    }
  }

  String? _dominantCompositionValue(
    List<ParcelSoilComposition> composition,
    String Function(ParcelSoilComposition item) selector,
  ) {
    final areas = <String, double>{};
    for (final item in composition) {
      final value = selector(item).trim();
      if (value.isEmpty) continue;
      areas.update(
        value,
        (area) => area + item.areaSquareMeters,
        ifAbsent: () => item.areaSquareMeters,
      );
    }
    if (areas.isEmpty) return null;
    return areas.entries.reduce((first, second) {
      if (second.value > first.value) return second;
      if (second.value == first.value && second.key.compareTo(first.key) < 0) {
        return second;
      }
      return first;
    }).key;
  }

  Future<void> _centerMapOnCurrentLocation({VoidCallback? onLocated}) async {
    if (_disableGeolocatorForDiagnostic) {
      debugPrint('GIS diagnostic: Geolocator disabled.');
      return;
    }
    _isFollowingLocation = SettingsService.instance.followLocationAutomatically;
    setState(() {
      _isLocating = true;
    });

    try {
      final location = await _locationService.getCurrentLocation();
      if (!mounted) {
        return;
      }

      setState(() {
        _currentLocation = location;
      });
      _startLocationUpdates();
      _moveMapToLocation(location);
      _storeCurrentLocationFeatureIfVisible(location.point);
      onLocated?.call();
    } on GisLocationException catch (error) {
      if (!mounted) {
        return;
      }

      unawaited(
        AppNotification.show(
          context,
          message: error.message,
          type: AppNotificationType.warning,
          bottomOffset: 72,
        ),
      );
    } catch (_) {
      if (!mounted) {
        return;
      }

      unawaited(
        AppNotification.show(
          context,
          message: 'No se pudo obtener la ubicación.',
          type: AppNotificationType.error,
          bottomOffset: 72,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLocating = false;
        });
      }
    }
  }

  Future<void> _centerMapOnCurrentLocationFromUser() async {
    await _centerMapOnCurrentLocation(
      onLocated: () {
        if (_gpsEnabledLogged) return;
        _gpsEnabledLogged = true;
        unawaited(AnalyticsService.instance.logGpsEnabled());
      },
    );
  }

  void _startLocationUpdates() {
    if (_disableGeolocatorForDiagnostic) return;
    if (_locationSubscription != null ||
        _locationService is! GisLocationUpdates) {
      return;
    }

    final updates = _locationService as GisLocationUpdates;
    _locationSubscription = updates.watchLocation().listen(
      (location) {
        if (!mounted) return;
        setState(() {
          _currentLocation = location;
        });
        if (_isFollowingLocation) {
          _moveMapToLocation(location);
        }
      },
      onError: (_) {
        if (!mounted) return;
        setState(() {
          _currentLocation = null;
        });
      },
      onDone: () {
        _locationSubscription = null;
        if (!mounted) return;
        setState(() {
          _currentLocation = null;
        });
      },
    );
  }

  void _moveMapToLocation(GisLocation location) {
    if (!_isMapReady) return;
    final zoom = _mapController.camera.zoom;
    if (!_isFiniteLatLng(location.point) || !_isFiniteNumber(zoom)) return;
    _mapController.move(location.point, zoom);
  }

  GisFeature? _storeCurrentLocationFeatureIfVisible(LatLng point) {
    if (!_showSoilPolygons) {
      return null;
    }

    final feature = _findFeatureAt(point);
    if (feature == null) {
      return null;
    }

    _currentLocationFeature = feature;
    return feature;
  }

  void _updateMapViewportState(MapCamera camera) {
    if (!_isFiniteCamera(camera)) {
      return;
    }
    final nextState = _MapViewportState(
      center: camera.center,
      zoom: camera.zoom,
      rotation: camera.rotation,
    );
    if (_mapViewportState.value == nextState) {
      return;
    }

    _mapViewportState.value = nextState;
  }

  void _animateMapToNorth() {
    final startRotation = _mapController.camera.rotation;
    if (startRotation.abs() < 0.01) return;

    _northRotationAnimation?.dispose();
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _northRotationAnimation = controller;
    final animation = Tween<double>(
      begin: startRotation,
      end: 0,
    ).animate(CurvedAnimation(parent: controller, curve: Curves.easeOutCubic));
    controller.addListener(() {
      if (mounted) _mapController.rotate(animation.value);
    });
    controller.addStatusListener((status) {
      if (status == AnimationStatus.completed &&
          identical(_northRotationAnimation, controller)) {
        controller.dispose();
        _northRotationAnimation = null;
      }
    });
    controller.forward();
  }

  void _scheduleTileLoad(MapCamera camera, GisArchiveInfo archiveInfo) {
    if (_disableGisTilePipelineForDiagnostic) return;
    if (!_isFiniteCamera(camera)) {
      return;
    }
    _tileLoadDebounce?.cancel();
    _tileLoadDebounce = Timer(
      const Duration(milliseconds: 150),
      () => _loadVisibleTiles(camera, archiveInfo),
    );
  }

  Future<void> _loadVisibleTiles(
    MapCamera camera,
    GisArchiveInfo archiveInfo,
  ) async {
    if (_disableGisTilePipelineForDiagnostic) return;
    if (!_isFiniteCamera(camera)) {
      return;
    }
    final visibleCoordinates = _tileCoordinatesForViewport(
      camera,
      archiveInfo,
      padding: 0,
    );
    final prefetchCoordinates = _tileCoordinatesForViewport(
      camera,
      archiveInfo,
      padding: 1,
    );
    final visibleSet = visibleCoordinates.toSet();
    final prefetchSet = prefetchCoordinates.toSet();
    if (setEquals(visibleSet, _visibleTileCoordinates) &&
        setEquals(prefetchSet, _prefetchedTileCoordinates)) {
      return;
    }

    final requestId = ++_tileRequestId;
    _visibleTileCoordinates = visibleSet;
    _prefetchedTileCoordinates = prefetchSet;
    _visibleTileZoom = visibleCoordinates.firstOrNull?.zoom;
    final uncachedCoordinates = <GisTileCoordinates>[];

    for (final coordinate in prefetchCoordinates) {
      final cached = _getRenderedTile(coordinate);
      if (cached != null) {
        cached.updateSelection(_selectedFeatureId);
      } else {
        uncachedCoordinates.add(coordinate);
      }
    }

    _publishVisibleTiles(visibleCoordinates, camera.visibleBounds);
    _updateOverlay(isLoading: uncachedCoordinates.isNotEmpty);

    if (uncachedCoordinates.isEmpty) {
      _enforceRenderedTileCacheLimit();
      return;
    }

    try {
      final layers = await Future.wait(
        uncachedCoordinates.map(_repository.loadTile),
      );
      if (!mounted || requestId != _tileRequestId) {
        return;
      }

      for (var index = 0; index < uncachedCoordinates.length; index++) {
        _cacheRenderedTile(uncachedCoordinates[index], layers[index]);
      }
      _enforceRenderedTileCacheLimit();

      _publishVisibleTiles(visibleCoordinates, camera.visibleBounds);
      _updateOverlay(isLoading: false);
    } catch (_) {
      if (!mounted || requestId != _tileRequestId) {
        return;
      }

      _updateOverlay(
        isLoading: false,
        error: 'No se pudieron cargar los polígonos visibles.',
      );
    }
  }

  void _publishVisibleTiles(
    List<GisTileCoordinates> coordinates,
    LatLngBounds viewport,
  ) {
    final tiles = _tilesForCoordinates(coordinates, _renderedTileCache);
    _visibleTiles = tiles;
    if (_renderMetrics.enabled) {
      var polygonCount = 0;
      var vertexCount = 0;
      for (final tile in tiles.values) {
        for (final polygon in tile.polygons) {
          if (polygon.bounds.intersects(viewport)) {
            polygonCount++;
            vertexCount += polygon.vertexCount;
          }
        }
      }
      _renderMetrics.recordVisibleGeometry(
        polygonCount: polygonCount,
        vertexCount: vertexCount,
      );
    }
    final widgets = <Widget>[
      for (final coordinate in coordinates)
        if (tiles[coordinate] case final tile?) tile.layerWidget,
    ];
    final snapshot = _VisibleTileSnapshot(widgets: widgets);
    if (!_visibleTileSnapshot.value.hasSameWidgets(snapshot)) {
      _visibleTileSnapshot.value = snapshot;
    }
  }

  void _updateOverlay({required bool isLoading, String? error}) {
    final nextState = _MapOverlayState(isLoading: isLoading, error: error);
    if (_overlayState.value != nextState) {
      _overlayState.value = nextState;
    }
  }

  Map<GisTileCoordinates, _RenderedGisTile> _tilesForCoordinates(
    List<GisTileCoordinates> coordinates,
    Map<GisTileCoordinates, _RenderedGisTile> source,
  ) {
    final tiles = <GisTileCoordinates, _RenderedGisTile>{};
    for (final coordinate in coordinates) {
      final tile = identical(source, _renderedTileCache)
          ? _getRenderedTile(coordinate)
          : source[coordinate];
      if (tile != null) {
        tiles[coordinate] = tile;
      }
    }
    return tiles;
  }

  void _cacheRenderedTile(GisTileCoordinates coordinates, GisLayer layer) {
    final stopwatch = Stopwatch()..start();
    final polygons = _buildRenderedPolygons(layer);
    stopwatch.stop();
    if (_renderMetrics.enabled) {
      _renderMetrics.polygonGenerationCount++;
      _renderMetrics.totalPolygonGenerationDuration += stopwatch.elapsed;
    }
    final tile = _RenderedGisTile(
      coordinates: coordinates,
      polygons: polygons,
      renderMetrics: _renderMetrics,
    );
    tile.updateSelection(_selectedFeatureId);
    final replacedTile = _renderedTileCache.remove(coordinates);
    replacedTile?.dispose();
    _renderedTileCache[coordinates] = tile;
    _indexSoilSeries(polygons);
  }

  _RenderedGisTile? _getRenderedTile(GisTileCoordinates coordinates) {
    final tile = _renderedTileCache.remove(coordinates);
    if (tile != null) {
      _renderedTileCache[coordinates] = tile;
    }
    return tile;
  }

  void _enforceRenderedTileCacheLimit() {
    if (_renderedTileCache.length <= _maxRenderedTileCacheEntries) return;

    final candidates = _renderedTileCache.keys.toList(growable: false);
    for (final coordinates in candidates) {
      if (_renderedTileCache.length <= _maxRenderedTileCacheEntries) break;
      if (_visibleTileCoordinates.contains(coordinates) ||
          _prefetchedTileCoordinates.contains(coordinates) ||
          _parcelAnalysisTilePins.containsKey(coordinates)) {
        continue;
      }
      final tile = _renderedTileCache.remove(coordinates);
      if (tile == null) continue;
      tile.dispose();
    }
  }

  Iterable<Widget> _buildSearchSuggestions(
    BuildContext context,
    SearchController controller,
  ) {
    final query = _normalizeSearchText(controller.text);
    final entries = _soilSeriesSearchIndex.values
        .where((entry) => query.isEmpty || entry.normalizedName.contains(query))
        .toList();

    if (entries.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                AppIcons.search,
                size: 28,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                'No hay coincidencias',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(
                'Probá con otra localidad, unidad o serie.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ];
    }

    final suggestions = <Widget>[];
    for (final type in _MapSearchEntryType.values) {
      final sectionEntries =
          entries.where((entry) => entry.type == type).toList()
            ..sort((first, second) {
              final rankComparison = _searchMatchRank(
                first.normalizedName,
                query,
              ).compareTo(_searchMatchRank(second.normalizedName, query));
              if (rankComparison != 0) {
                return rankComparison;
              }
              return first.name.compareTo(second.name);
            });
      if (sectionEntries.isEmpty) {
        continue;
      }

      suggestions.add(_SearchSectionHeader(type: type));
      suggestions.addAll(
        sectionEntries.take(12).map((entry) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                minTileHeight: 62,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                hoverColor: Theme.of(
                  context,
                ).colorScheme.primaryContainer.withValues(alpha: 0.32),
                splashColor: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.10),
                leading: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: SizedBox.square(
                    dimension: 38,
                    child: Icon(entry.type.icon, size: 19),
                  ),
                ),
                title: Text(
                  entry.name,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  entry.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                onTap: () {
                  if (query.isNotEmpty) {
                    logSubmittedSearch(query);
                  }
                  controller.closeView(entry.name);
                  if (entry.type == _MapSearchEntryType.soilSeries) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        unawaited(_showSeriesUnitChoices(entry));
                      }
                    });
                  } else {
                    _selectSearchSuggestion(entry);
                  }
                },
              ),
            ),
          );
        }),
      );
    }
    return suggestions;
  }

  void _selectSearchSuggestion(_SoilSeriesSearchEntry entry) {
    _searchSelectedFeature = entry.feature;
    _animateMapToSearchResult(entry);
  }

  Future<void> _showSeriesUnitChoices(_SoilSeriesSearchEntry entry) {
    final units = entry.unitMatches.toList()
      ..sort((first, second) {
        final percentageComparison = second.numericPercentage.compareTo(
          first.numericPercentage,
        );
        if (percentageComparison != 0) {
          return percentageComparison;
        }
        return first.unitSymbol.compareTo(second.unitSymbol);
      });

    return _showMapBottomSheet<void>(
      builder: (bottomSheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Serie: ${entry.name}',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${units.length} unidades cartográficas',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 12),
                  itemCount: units.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, indent: 20, endIndent: 20),
                  itemBuilder: (context, index) {
                    final unit = units[index];
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 6,
                      ),
                      title: Text(
                        unit.unitSymbol.isEmpty
                            ? 'Sin símbolo'
                            : unit.unitSymbol,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(unit.unitName),
                      trailing: Chip(
                        label: Text(unit.displayPercentage),
                        visualDensity: VisualDensity.compact,
                      ),
                      onTap: () {
                        Navigator.of(bottomSheetContext).pop();
                        _selectSearchSuggestion(unit.searchEntry);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openFavorites() async {
    final featureId = await Navigator.of(context).push<String>(
      InstantPopMaterialPageRoute(builder: (_) => const GisFavoritesScreen()),
    );
    if (!mounted || featureId == null) {
      return;
    }

    _SoilSeriesSearchEntry? selectedEntry;
    for (final entry in _soilSeriesSearchIndex.values) {
      if (entry.feature.id == featureId) {
        selectedEntry = entry;
        break;
      }
    }

    if (selectedEntry == null) {
      unawaited(
        AppNotification.show(
          context,
          message: 'Este favorito ya no está disponible.',
          type: AppNotificationType.warning,
          bottomOffset: 72,
        ),
      );
      return;
    }

    _selectSearchSuggestion(selectedEntry);
  }

  void _focusFavorite(FavoriteSoilFeature favorite) {
    final selectedEntry = _soilSeriesSearchIndex.values
        .where((entry) => entry.feature.id == favorite.id)
        .firstOrNull;
    if (selectedEntry == null) {
      unawaited(
        AppNotification.show(
          context,
          message: 'Este favorito ya no está disponible.',
          type: AppNotificationType.warning,
          bottomOffset: 72,
        ),
      );
      return;
    }
    _closeDesktopPanel();
    _selectSearchSuggestion(selectedEntry);
  }

  Future<void> _openPersonalMarkers() async {
    final markerId = await Navigator.of(context).push<String>(
      InstantPopMaterialPageRoute(
        builder: (_) => const PersonalMarkersScreen(),
      ),
    );
    if (!mounted) return;

    await _loadPersonalMarkers();
    if (!mounted || markerId == null) return;
    PersonalMarker? selectedMarker;
    for (final marker in _personalMarkers) {
      if (marker.id == markerId) {
        selectedMarker = marker;
        break;
      }
    }
    if (selectedMarker == null) return;

    if (_usesDesktopMapShell) {
      _focusPersonalMarker(selectedMarker);
      return;
    }
    final markerPoint = _safeLatLng(
      selectedMarker.latitude,
      selectedMarker.longitude,
    );
    final zoom = _mapController.camera.zoom;
    if (markerPoint != null && _isFiniteNumber(zoom)) {
      _mapController.move(markerPoint, zoom);
    }
    await _showPersonalMarkerDetails(selectedMarker);
  }

  Future<void> _openMeasurements() async {
    final measurement = await Navigator.of(context).push<SavedMeasurement>(
      InstantPopMaterialPageRoute(builder: (_) => const MeasurementsScreen()),
    );
    if (!mounted) return;

    await _loadSavedMeasurements();
    if (!mounted || measurement == null || measurement.geometry.isEmpty) {
      return;
    }
    final selectedMeasurement = _savedMeasurements
        .where((item) => item.id == measurement.id)
        .firstOrNull;
    if (selectedMeasurement == null) return;

    _focusSavedMeasurement(selectedMeasurement);
  }

  void _focusSavedMeasurement(SavedMeasurement measurement) {
    if (measurement.geometry.isEmpty) return;
    final targetCamera = CameraFit.coordinates(
      coordinates: measurement.geometry,
      padding: const EdgeInsets.all(72),
      maxZoom: 16,
    ).fit(_mapController.camera);
    _animateMapToPosition(targetCamera.center, targetCamera.zoom);
    setState(() {
      _closeDesktopPanel();
      _highlightedSavedMeasurementId = measurement.id;
      _desktopSelectedMarker = null;
      _selectionPreview.value = null;
    });
  }

  void _focusPersonalMarker(PersonalMarker marker) {
    final markerPoint = _safeLatLng(marker.latitude, marker.longitude);
    final zoom = _mapController.camera.zoom;
    if (markerPoint != null && _isFiniteNumber(zoom)) {
      _mapController.move(markerPoint, zoom);
    }
    setState(() {
      _closeDesktopPanel();
      _desktopSelectedMarker = marker;
      _highlightedSavedMeasurementId = null;
      _selectionPreview.value = null;
    });
  }

  Future<void> _hideSavedMeasurement(SavedMeasurement measurement) async {
    if (!measurement.isVisible) return;
    await _toggleSavedMeasurementVisibility(measurement);
  }

  Future<void> _toggleSavedMeasurementVisibility(
    SavedMeasurement measurement,
  ) async {
    final index = _savedMeasurements.indexWhere(
      (item) => item.id == measurement.id,
    );
    if (index == -1) return;
    final isVisible = !measurement.isVisible;
    setState(() {
      _savedMeasurements[index] = measurement.withLocalVisibility(isVisible);
      if (!isVisible && _highlightedSavedMeasurementId == measurement.id) {
        _highlightedSavedMeasurementId = null;
      }
      if (!isVisible && _activeSavedMeasurementId == measurement.id) {
        _setInteractionMode(_InteractionMode.none);
        _activeSavedMeasurementId = null;
        _savedMeasurementGeometrySignature = null;
        _savedMeasurementColorId = null;
        _distanceMeasurementPoints.clear();
        _areaMeasurementPoints.clear();
      }
    });
    await SyncAwareLocalRepository.instance.saveMeasurements(
      _savedMeasurements,
    );
  }

  void _animateMapToPosition(LatLng targetCenter, double targetZoom) {
    final startCamera = _mapController.camera;
    final startCenter = startCamera.center;
    final startZoom = startCamera.zoom;
    if (!_isFiniteLatLng(startCenter) ||
        !_isFiniteLatLng(targetCenter) ||
        !_isFiniteNumber(startZoom) ||
        !_isFiniteNumber(targetZoom)) {
      return;
    }
    _searchCameraAnimation?.dispose();
    final animation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 550),
    );
    _searchCameraAnimation = animation;
    final curvedAnimation = CurvedAnimation(
      parent: animation,
      curve: Curves.easeInOutCubic,
    );
    animation.addListener(() {
      final value = curvedAnimation.value;
      final center = _lerpLatLng(startCenter, targetCenter, value);
      final zoom = _lerpDouble(startZoom, targetZoom, value);
      if (center == null || !_isFiniteNumber(zoom)) {
        return;
      }
      _mapController.move(center, zoom);
    });
    animation.addStatusListener((status) {
      if (status != AnimationStatus.completed &&
          status != AnimationStatus.dismissed) {
        return;
      }
      curvedAnimation.dispose();
      animation.dispose();
      if (identical(_searchCameraAnimation, animation)) {
        _searchCameraAnimation = null;
      }
    });
    unawaited(animation.forward());
  }

  void _indexSoilSeries(List<_RenderedGisPolygon> polygons) {
    for (final polygon in polygons) {
      final feature = polygon.feature;
      final searchFeature = _searchFeatureSnapshots.putIfAbsent(
        feature.id,
        () => GisFeature(
          id: feature.id,
          geometry: GisGeometry(
            type: feature.geometry.type,
            coordinates: const <Object>[],
          ),
          properties: Map<String, Object?>.unmodifiable(feature.properties),
          locality: feature.locality,
          soilMapId: feature.soilMapId,
        ),
      );
      final unitSymbol = feature.properties['SIMBC']?.toString().trim() ?? '';
      final unitName = feature.properties['Nombre_UC']?.toString().trim() ?? '';
      final normalizedUnitSymbol = _normalizeSearchText(unitSymbol);
      final unitKey = 'unit:$normalizedUnitSymbol';
      if (normalizedUnitSymbol.isNotEmpty &&
          !_soilSeriesSearchIndex.containsKey(unitKey)) {
        _soilSeriesSearchIndex[unitKey] = _SoilSeriesSearchEntry(
          name: unitSymbol,
          normalizedName: normalizedUnitSymbol,
          subtitle: unitName.isEmpty ? 'Unidad de suelo' : unitName,
          type: _MapSearchEntryType.unitSymbol,
          feature: searchFeature,
          center: polygon.bounds.center,
        );
      }

      final locality = feature.locality.trim();
      final normalizedLocality = _normalizeSearchText(locality);
      final localityKey = 'locality:$normalizedLocality';
      if (normalizedLocality.isNotEmpty &&
          !_soilSeriesSearchIndex.containsKey(localityKey)) {
        _soilSeriesSearchIndex[localityKey] = _SoilSeriesSearchEntry(
          name: locality,
          normalizedName: normalizedLocality,
          subtitle: 'Localidad',
          type: _MapSearchEntryType.locality,
          feature: searchFeature,
          center: polygon.bounds.center,
        );
      }

      final series = GisSoilSeries.fromProperties(feature.properties);
      for (final soilSeries in series) {
        final normalizedName = _normalizeSearchText(soilSeries.name);
        final seriesKey = 'series:$normalizedName';
        if (normalizedName.isEmpty) {
          continue;
        }

        final searchEntry = _soilSeriesSearchIndex.putIfAbsent(
          seriesKey,
          () => _SoilSeriesSearchEntry(
            name: soilSeries.name,
            normalizedName: normalizedName,
            subtitle: 'Serie de suelo',
            type: _MapSearchEntryType.soilSeries,
            feature: searchFeature,
            center: polygon.bounds.center,
          ),
        );
        if (searchEntry.unitMatches.any(
          (match) => match.searchEntry.feature.id == searchFeature.id,
        )) {
          continue;
        }
        searchEntry.unitMatches.add(
          _SoilSeriesUnitMatch(
            unitSymbol: unitSymbol,
            unitName: unitName.isEmpty ? 'Unidad sin nombre' : unitName,
            percentage: soilSeries.percentage,
            searchEntry: _SoilSeriesSearchEntry(
              name: unitSymbol,
              normalizedName: normalizedUnitSymbol,
              subtitle: unitName,
              type: _MapSearchEntryType.unitSymbol,
              feature: searchFeature,
              center: polygon.bounds.center,
            ),
          ),
        );
      }
    }
  }

  void _animateMapToSearchResult(_SoilSeriesSearchEntry entry) {
    final targetCenter = entry.center;
    final startCamera = _mapController.camera;
    final startCenter = startCamera.center;
    final startZoom = startCamera.zoom;
    final targetZoom = startZoom < 12 ? 12.0 : startZoom;
    if (!_isFiniteLatLng(startCenter) ||
        !_isFiniteLatLng(targetCenter) ||
        !_isFiniteNumber(startZoom) ||
        !_isFiniteNumber(targetZoom)) {
      return;
    }

    _searchCameraAnimation?.dispose();
    final animation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 550),
    );
    _searchCameraAnimation = animation;

    final curvedAnimation = CurvedAnimation(
      parent: animation,
      curve: Curves.easeInOutCubic,
    );

    animation.addListener(() {
      final value = curvedAnimation.value;
      final center = _lerpLatLng(startCenter, targetCenter, value);
      final zoom = _lerpDouble(startZoom, targetZoom, value);
      if (center == null || !_isFiniteNumber(zoom)) {
        return;
      }
      _mapController.move(center, zoom);
    });
    animation.addStatusListener((status) {
      if (status == AnimationStatus.completed ||
          status == AnimationStatus.dismissed) {
        if (status == AnimationStatus.completed && mounted) {
          _selectFeature(entry.feature);
          unawaited(_showFeatureAttributes(entry.feature));
        }
        curvedAnimation.dispose();
        animation.dispose();
        if (identical(_searchCameraAnimation, animation)) {
          _searchCameraAnimation = null;
        }
      }
    });

    unawaited(animation.forward());
  }

  List<GisTileCoordinates> _tileCoordinatesForViewport(
    MapCamera camera,
    GisArchiveInfo archiveInfo, {
    required int padding,
  }) {
    final zoom = camera.zoom.floor().clamp(
      archiveInfo.minZoom,
      archiveInfo.maxZoom,
    );
    final bounds = camera.visibleBounds;
    final tilesAtZoom = 1 << zoom;
    final minX = (_longitudeToTileX(bounds.west, zoom) - padding).clamp(
      0,
      tilesAtZoom - 1,
    );
    final maxX = (_longitudeToTileX(bounds.east, zoom) + padding).clamp(
      0,
      tilesAtZoom - 1,
    );
    final minY = (_latitudeToTileY(bounds.north, zoom) - padding).clamp(
      0,
      tilesAtZoom - 1,
    );
    final maxY = (_latitudeToTileY(bounds.south, zoom) + padding).clamp(
      0,
      tilesAtZoom - 1,
    );
    final coordinates = <GisTileCoordinates>[];

    for (var x = minX; x <= maxX; x++) {
      for (var y = minY; y <= maxY; y++) {
        coordinates.add(GisTileCoordinates(zoom: zoom, x: x, y: y));
      }
    }

    return coordinates;
  }

  int _longitudeToTileX(double longitude, int zoom) {
    final tilesAtZoom = 1 << zoom;
    return (((longitude + 180) / 360) * tilesAtZoom).floor();
  }

  int _latitudeToTileY(double latitude, int zoom) {
    final tilesAtZoom = 1 << zoom;
    final clampedLatitude = latitude.clamp(-85.05112878, 85.05112878);
    final radians = clampedLatitude * math.pi / 180;
    final mercator = math.log(math.tan(radians) + (1 / math.cos(radians)));
    return ((1 - mercator / math.pi) / 2 * tilesAtZoom).floor();
  }

  List<_RenderedGisPolygon> _buildRenderedPolygons(GisLayer layer) {
    final polygons = <_RenderedGisPolygon>[];

    for (final feature in layer.features) {
      final geometry = feature.geometry;

      if (geometry.type == 'Polygon') {
        final polygon = _buildRenderedPolygon(feature, geometry.coordinates);
        if (polygon != null) {
          polygons.add(polygon);
        }
      } else if (geometry.type == 'MultiPolygon') {
        final coordinates = geometry.coordinates;
        if (coordinates is! List) {
          continue;
        }

        for (final polygonCoordinates in coordinates) {
          final polygon = _buildRenderedPolygon(feature, polygonCoordinates);
          if (polygon != null) {
            polygons.add(polygon);
          }
        }
      }
    }

    return List<_RenderedGisPolygon>.unmodifiable(polygons);
  }

  _RenderedGisPolygon? _buildRenderedPolygon(
    GisFeature feature,
    Object? coordinates,
  ) {
    if (coordinates is! List || coordinates.isEmpty) {
      return null;
    }

    final outerRing = _readRing(coordinates.first);
    if (outerRing.length < 3) {
      return null;
    }

    final holes = coordinates
        .skip(1)
        .map(_readRing)
        .where((ring) => ring.length >= 3)
        .toList(growable: false);

    return _RenderedGisPolygon(
      feature: feature,
      outerRing: outerRing,
      holes: holes,
    );
  }

  List<LatLng> _readRing(Object? value) {
    if (value is! List) {
      return const <LatLng>[];
    }

    final points = <LatLng>[];
    for (final coordinate in value) {
      if (coordinate is! List || coordinate.length < 2) {
        continue;
      }

      final longitude = _readDouble(coordinate[0]);
      final latitude = _readDouble(coordinate[1]);
      if (longitude == null ||
          latitude == null ||
          !_isFiniteCoordinateValues(latitude, longitude)) {
        continue;
      }

      points.add(LatLng(latitude, longitude));
    }

    return points;
  }

  double? _readDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }

    return double.tryParse(value?.toString() ?? '');
  }

  void _handleMapTap(TapPosition tapPosition, LatLng point) {
    if (_suppressNextMapTap) {
      _suppressNextMapTap = false;
      return;
    }
    final savedMeasurement = _findSavedMeasurementAt(
      tapPosition.relative ?? tapPosition.global,
    );
    if (savedMeasurement != null) {
      if (savedMeasurement.id != _activeSavedMeasurementId) {
        unawaited(_requestSelectSavedMeasurement(savedMeasurement));
      }
      return;
    }
    if (_measurementMode != null) {
      _dismissActiveToolHint();
      if (_measurementMode == _MeasurementMode.area) {
        final candidate = List<LatLng>.of(_areaMeasurementPoints);
        final edgeIndex = _nearestMeasurementEdgeIndex(
          tapPosition.relative,
          _areaMeasurementPoints,
          closed: true,
        );
        if (edgeIndex == null) {
          candidate.add(point);
        } else {
          candidate.insert(edgeIndex + 1, point);
        }
        if (_isSelfIntersecting(candidate)) {
          _showInvalidMeasurementMessage();
          return;
        }
        setState(() {
          _invalidateParcelAnalysis();
          _areaMeasurementPoints
            ..clear()
            ..addAll(candidate);
        });
      } else {
        setState(() {
          final edgeIndex = _nearestMeasurementEdgeIndex(
            tapPosition.relative,
            _distanceMeasurementPoints,
            closed: false,
          );
          if (edgeIndex == null) {
            _distanceMeasurementPoints.add(point);
          } else {
            _distanceMeasurementPoints.insert(edgeIndex + 1, point);
          }
        });
      }
      return;
    }
    if (_isPersonalMarkerMode) {
      setState(() => _activeToolHint = _MapToolHintType.markerActive);
      unawaited(_createPersonalMarker(point));
      return;
    }

    if (!_showSoilPolygons) {
      if (_highlightedSavedMeasurementId != null) {
        setState(() => _highlightedSavedMeasurementId = null);
      }
      return;
    }

    final feature = _findFeatureAt(point);
    if (feature == null) {
      _selectionPreview.value = null;
      if (_highlightedSavedMeasurementId != null) {
        setState(() => _highlightedSavedMeasurementId = null);
      }
      if (_usesDesktopMapShell && _desktopSelectedMarker != null) {
        setState(() => _desktopSelectedMarker = null);
      }
      return;
    }
    if (_highlightedSavedMeasurementId != null) {
      setState(() => _highlightedSavedMeasurementId = null);
    }

    if (_selectedFeatureId == feature.id) {
      _selectionPreview.value = null;
      unawaited(_showFeatureAttributes(feature));
      return;
    }

    _selectFeature(feature);
    _selectionPreview.value = feature;
  }

  void _dismissActiveToolHint() {
    if (_activeToolHint == null) return;
    setState(() => _activeToolHint = null);
  }

  SavedMeasurement? _findSavedMeasurementAt(Offset tapOffset) {
    for (final measurement in _savedMeasurements.reversed) {
      if (!measurement.isVisible) continue;
      final points = measurement.geometry;
      if (points.length < 2) continue;
      final segmentCount = measurement.type == SavedMeasurementType.area
          ? points.length
          : points.length - 1;
      for (var index = 0; index < segmentCount; index++) {
        final start = _mapController.camera.latLngToScreenOffset(points[index]);
        final end = _mapController.camera.latLngToScreenOffset(
          points[(index + 1) % points.length],
        );
        if (_distanceToSegment(tapOffset, start, end) <= 10) {
          return measurement;
        }
      }
    }
    return null;
  }

  void _previewSavedMeasurement(SavedMeasurement measurement) {
    if (_activeSavedMeasurementId != null) return;
    setState(() {
      _closeDesktopPanel();
      _highlightedSavedMeasurementId = measurement.id;
      _selectionPreview.value = null;
      _desktopSelectedMarker = null;
    });
  }

  bool get _usesDesktopMapShell =>
      mounted && isSuelosArDesktopPlatform(context);

  void _handlePersonalMarkerTap(PersonalMarker marker) {
    if (_usesDesktopMapShell) {
      setState(() {
        _closeDesktopPanel();
        _desktopSelectedMarker = marker;
        _highlightedSavedMeasurementId = null;
        _selectionPreview.value = null;
      });
      return;
    }
    unawaited(_showPersonalMarkerDetails(marker));
  }

  void _analyzeSavedMeasurement(SavedMeasurement measurement) {
    if (measurement.type != SavedMeasurementType.area ||
        measurement.geometry.length < 3) {
      return;
    }
    _showParcelAnalysis(
      ParcelAnalysis(
        totalAreaSquareMeters:
            measurement.areaSquareMeters ??
            _MeasurementLayer._calculateArea(measurement.geometry),
        perimeterMeters:
            measurement.perimeterMeters ??
            _MeasurementLayer._calculatePerimeter(measurement.geometry),
      ),
      parcelPoints: measurement.geometry,
    );
  }

  Future<void> _requestSelectSavedMeasurement(
    SavedMeasurement measurement,
  ) async {
    if (_activeSavedMeasurementId == measurement.id) return;
    final mode = _measurementMode;
    if (mode != null && _measurementHasUnsavedChanges) {
      final decision = await _showMeasurementDecisionDialog(
        '¿Querés guardar los cambios antes de seleccionar otra medición?',
      );
      if (!mounted ||
          decision == null ||
          decision == _MeasurementExitDecision.cancel) {
        return;
      }
      if (decision == _MeasurementExitDecision.save) {
        await _persistMeasurement(mode);
        if (!mounted) return;
      }
    }
    _selectSavedMeasurement(measurement);
  }

  void _selectSavedMeasurement(SavedMeasurement measurement) {
    setState(() {
      _setInteractionMode(
        measurement.type == SavedMeasurementType.area
            ? _InteractionMode.measureArea
            : _InteractionMode.measureDistance,
      );
      _retainedMeasurementMode = _measurementMode;
      _distanceMeasurementPoints
        ..clear()
        ..addAll(
          measurement.type == SavedMeasurementType.distance
              ? measurement.geometry
              : const <LatLng>[],
        );
      _areaMeasurementPoints
        ..clear()
        ..addAll(
          measurement.type == SavedMeasurementType.area
              ? measurement.geometry
              : const <LatLng>[],
        );
      _measurementColor = MeasurementColorOption.fromStorageValue(
        measurement.colorId,
      );
      _activeSavedMeasurementId = measurement.id;
      _highlightedSavedMeasurementId = measurement.id;
      _savedMeasurementGeometrySignature = _currentMeasurementSignature;
      _savedMeasurementColorId = measurement.colorId;
      _selectionPreview.value = null;
    });
  }

  Future<void> _loadPersonalMarkers() async {
    final preferences = await SharedPreferences.getInstance();
    final encodedMarkers =
        preferences.getStringList(PersonalMarker.storageKey) ??
        const <String>[];
    final markers = <PersonalMarker>[];
    for (final encodedMarker in encodedMarkers) {
      try {
        final json = jsonDecode(encodedMarker);
        if (json is Map<String, dynamic>) {
          markers.add(PersonalMarker.fromJson(json));
        }
      } on FormatException {
        // Ignore malformed local entries without affecting the map.
      } on TypeError {
        // Ignore entries written with an incompatible schema.
      }
    }
    if (!mounted) return;
    setState(() {
      _personalMarkers
        ..clear()
        ..addAll(markers);
    });
  }

  Future<void> _createPersonalMarker(LatLng point) async {
    final values = await _showPersonalMarkerDialog(
      onCancel: _exitPersonalMarkerPlacement,
    );
    if (!mounted || values == null) return;

    final now = DateTime.now();
    final marker = PersonalMarker(
      id: now.microsecondsSinceEpoch.toString(),
      latitude: point.latitude,
      longitude: point.longitude,
      name: values.name,
      description: values.description,
      createdAt: now,
      category: values.category,
      uuid: UuidV4.generate(),
      updatedAt: now.toUtc(),
      syncState: SyncState.pendingUpload,
    );
    setState(() {
      _personalMarkers.add(marker);
    });
    await _persistPersonalMarkers();
    unawaited(AnalyticsService.instance.logMarkerCreated());
    if (!mounted) return;
    _exitPersonalMarkerPlacement();
  }

  Future<({String name, String description, PersonalMarkerCategory category})?>
  _showPersonalMarkerDialog({
    PersonalMarker? marker,
    VoidCallback? onCancel,
  }) async {
    final formKey = GlobalKey<FormState>();
    var name = marker?.name ?? '';
    var description = marker?.description ?? '';
    var category = marker?.category ?? PersonalMarkerCategory.other;
    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: Text(marker == null ? 'Nuevo marcador' : 'Editar marcador'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: const ValueKey('personal-marker-name'),
                autofocus: true,
                initialValue: name,
                decoration: const InputDecoration(labelText: 'Nombre'),
                onChanged: (value) => name = value,
                validator: (value) =>
                    value == null || value.trim().isEmpty ? 'Requerido' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('personal-marker-description'),
                initialValue: description,
                decoration: const InputDecoration(labelText: 'Descripcion'),
                minLines: 2,
                maxLines: 4,
                onChanged: (value) => description = value,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<PersonalMarkerCategory>(
                key: const ValueKey('personal-marker-category'),
                initialValue: category,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Categoria'),
                items: [
                  for (final option in PersonalMarkerCategory.values)
                    DropdownMenuItem(value: option, child: Text(option.label)),
                ],
                onChanged: (value) {
                  if (value != null) category = value;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              onCancel?.call();
              Navigator.pop(dialogContext, false);
            },
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(dialogContext, true);
              }
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (!mounted || shouldSave != true) {
      return null;
    }
    return (
      name: name.trim(),
      description: description.trim(),
      category: category,
    );
  }

  void _exitPersonalMarkerPlacement() {
    if (!mounted) return;
    setState(() {
      _setInteractionMode(_InteractionMode.none);
    });
  }

  Future<void> _persistPersonalMarkers() async {
    await SyncAwareLocalRepository.instance.saveMarkers(_personalMarkers);
  }

  Future<void> _showPersonalMarkerDetails(PersonalMarker marker) {
    return _showMapBottomSheet<void>(
      isScrollControlled: true,
      builder: (bottomSheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  marker.name,
                  style: Theme.of(bottomSheetContext).textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                if (marker.description.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(marker.description),
                ],
                const SizedBox(height: 16),
                Text(
                  'Categoria',
                  style: Theme.of(bottomSheetContext).textTheme.labelLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  marker.category.label,
                  key: const ValueKey('personal-marker-category-label'),
                ),
                const SizedBox(height: 16),
                Text(
                  'Coordenadas',
                  style: Theme.of(bottomSheetContext).textTheme.labelLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  '${marker.latitude.toStringAsFixed(6)}, '
                  '${marker.longitude.toStringAsFixed(6)}',
                  key: const ValueKey('personal-marker-coordinates'),
                  style: Theme.of(bottomSheetContext).textTheme.bodyMedium
                      ?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Creado',
                  style: Theme.of(bottomSheetContext).textTheme.labelLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  _formatPersonalMarkerDate(marker.createdAt),
                  key: const ValueKey('personal-marker-created-at'),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      key: const ValueKey('edit-personal-marker'),
                      icon: const Icon(AppIcons.edit),
                      label: const Text('Editar'),
                      onPressed: () {
                        Navigator.pop(bottomSheetContext);
                        unawaited(_editPersonalMarker(marker));
                      },
                    ),
                    const SizedBox(width: 8),
                    TextButton.icon(
                      key: const ValueKey('delete-personal-marker'),
                      icon: const Icon(AppIcons.delete),
                      label: const Text('Eliminar'),
                      onPressed: () {
                        Navigator.pop(bottomSheetContext);
                        unawaited(_confirmDeletePersonalMarker(marker));
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _editPersonalMarker(PersonalMarker marker) async {
    final values = await _showPersonalMarkerDialog(marker: marker);
    if (!mounted || values == null) return;
    final index = _personalMarkers.indexWhere((item) => item.id == marker.id);
    if (index == -1) return;
    final updatedMarker = marker.copyWith(
      name: values.name,
      description: values.description,
      category: values.category,
    );
    setState(() {
      _personalMarkers[index] = updatedMarker;
      if (_desktopSelectedMarker?.id == marker.id) {
        _desktopSelectedMarker = updatedMarker;
      }
    });
    await _persistPersonalMarkers();
  }

  Future<void> _confirmDeletePersonalMarker(PersonalMarker marker) async {
    final confirmed = await confirmDestructiveAction(
      context,
      title: '¿Eliminar marcador?',
      message: 'Se eliminará "${marker.name}" permanentemente.',
    );
    if (!mounted || !confirmed) return;
    setState(() {
      _personalMarkers.removeWhere((item) => item.id == marker.id);
      if (_desktopSelectedMarker?.id == marker.id) {
        _desktopSelectedMarker = null;
      }
    });
    await _persistPersonalMarkers();
  }

  String _formatPersonalMarkerDate(DateTime value) {
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${twoDigits(value.day)}/${twoDigits(value.month)}/${value.year} '
        '${twoDigits(value.hour)}:${twoDigits(value.minute)}';
  }

  int? _nearestMeasurementEdgeIndex(
    Offset? tapOffset,
    List<LatLng> points, {
    required bool closed,
  }) {
    if (tapOffset == null || points.length < 2) {
      return null;
    }
    var nearestDistance = 14.0;
    int? nearestIndex;
    final segmentCount = closed ? points.length : points.length - 1;
    for (var index = 0; index < segmentCount; index++) {
      final start = _mapController.camera.latLngToScreenOffset(points[index]);
      final end = _mapController.camera.latLngToScreenOffset(
        points[(index + 1) % points.length],
      );
      final distance = _distanceToSegment(tapOffset, start, end);
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearestIndex = index;
      }
    }
    return nearestIndex;
  }

  GisFeature? _findFeatureAt(LatLng point) {
    final zoom = _visibleTileZoom;
    if (zoom == null) {
      return null;
    }

    final coordinates = GisTileCoordinates(
      zoom: zoom,
      x: _longitudeToTileX(point.longitude, zoom),
      y: _latitudeToTileY(point.latitude, zoom),
    );
    return _visibleTiles[coordinates]?.hitTest(point);
  }

  void _selectFeature(GisFeature feature) {
    final previousFeatureId = _selectedFeatureId;
    _selectedFeatureId = feature.id;
    for (final tile in _visibleTiles.values) {
      if (tile.featureIds.contains(previousFeatureId) ||
          tile.featureIds.contains(feature.id)) {
        tile.updateSelection(feature.id);
      }
    }
  }

  Future<void> _showFeatureAttributes(GisFeature feature) {
    _selectionPreview.value = null;
    final series = GisSoilSeries.fromProperties(feature.properties);
    final matchesFuture = _findSeriesPdfs(series);

    return _showMapBottomSheet<void>(
      isScrollControlled: true,
      builder: (bottomSheetContext) {
        final title = _readAttribute(feature, 'Nombre_UC');
        final capability = _readAttribute(feature, 'CAP_USO');
        final type = _readAttribute(feature, 'TIPO');
        final seriesCount = series.length == 1
            ? '1 serie'
            : '${series.length} series';

        return SafeArea(
          child: FractionallySizedBox(
            heightFactor: 0.85,
            child: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                  child: Text(
                    title == 'Sin datos' ? 'Unidad cartográfica' : title,
                    style: Theme.of(bottomSheetContext).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    'Capacidad $capability • $seriesCount • $type',
                    style: Theme.of(bottomSheetContext).textTheme.bodySmall
                        ?.copyWith(
                          color: Theme.of(
                            bottomSheetContext,
                          ).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
                StatefulBuilder(
                  builder: (context, setBottomSheetState) {
                    final isFavorite = _favoriteFeatures.containsKey(
                      feature.id,
                    );

                    return Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: IconButton(
                          tooltip: isFavorite
                              ? 'Quitar de favoritos'
                              : 'Agregar a favoritos',
                          icon: Icon(
                            AppIcons.star,
                            color: isFavorite
                                ? Theme.of(context).colorScheme.primary
                                : null,
                          ),
                          onPressed: () {
                            setBottomSheetState(() {
                              _toggleFavorite(feature, series);
                            });
                          },
                        ),
                      ),
                    );
                  },
                ),
                _BottomSheetSection(
                  title: 'Información general',
                  children: [
                    _InfoRow(
                      label: 'Símbolo',
                      value: _readAttribute(feature, 'SIMBC'),
                    ),
                    _InfoRow(
                      label: 'Tipo',
                      value: _readAttribute(feature, 'TIPO'),
                    ),
                    _InfoRow(
                      label: 'Capacidad de uso',
                      value: _readAttribute(feature, 'CAP_USO'),
                    ),
                  ],
                ),
                _BottomSheetSection(
                  title: 'Paisaje',
                  children: [
                    _LandscapeDescription(
                      value: _readAttribute(feature, 'PAISAJE'),
                    ),
                  ],
                ),
                _BottomSheetSection(
                  title: 'Series de suelo',
                  children: [
                    if (series.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text('No hay series disponibles.'),
                      ),
                    if (series.isNotEmpty)
                      for (var index = 0; index < series.length; index++)
                        _SoilSeriesSummaryTile(
                          series: series[index],
                          isDominant: index == 0,
                        ),
                  ],
                ),
                _BottomSheetSection(
                  title: 'Memorias descriptivas',
                  children: [
                    if (series.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text('No hay series disponibles.'),
                      ),
                    if (series.isNotEmpty)
                      FutureBuilder<List<String?>>(
                        future: matchesFuture,
                        builder: (context, snapshot) {
                          if (snapshot.connectionState !=
                              ConnectionState.done) {
                            return const Padding(
                              padding: EdgeInsets.all(24),
                              child: Center(child: CircularProgressIndicator()),
                            );
                          }

                          final matches =
                              snapshot.data ??
                              List<String?>.filled(series.length, null);

                          return Column(
                            children: [
                              for (
                                var index = 0;
                                index < series.length;
                                index++
                              )
                                _buildSeriesTile(
                                  bottomSheetContext,
                                  series[index],
                                  matches[index],
                                ),
                            ],
                          );
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _loadFavorites() async {
    try {
      final storedFavorites = await _gisFavoritesService.load();
      if (!mounted) return;
      setState(() {
        _favoriteFeatures
          ..clear()
          ..addEntries(
            storedFavorites.map((favorite) => MapEntry(favorite.id, favorite)),
          );
      });
    } catch (_) {
      return;
    }
  }

  void _toggleFavorite(GisFeature feature, List<GisSoilSeries> series) {
    final removedFavorite = _favoriteFeatures.remove(feature.id);
    if (removedFavorite == null) {
      _favoriteFeatures[feature.id] = FavoriteSoilFeature(
        id: feature.id,
        unitName: _readAttribute(feature, 'Nombre_UC'),
        unitSymbol: _readAttribute(feature, 'SIMBC'),
        soilSeries: series.map((soilSeries) => soilSeries.name).toList(),
        pdfIdentifier: _readOptionalPdfIdentifier(feature),
      );
    }

    unawaited(_saveFavorites(logAdded: removedFavorite == null));
  }

  bool _removeFavoriteFromDesktopPanel(FavoriteSoilFeature favorite) {
    if (_favoriteFeatures.remove(favorite.id) == null) return false;
    unawaited(_saveFavorites());
    return true;
  }

  Future<void> _saveFavorites({bool logAdded = false}) async {
    await _gisFavoritesService.save(_favoriteFeatures.values);
    if (logAdded) {
      unawaited(AnalyticsService.instance.logFavoriteAdded());
    }
  }

  String? _readOptionalPdfIdentifier(GisFeature feature) {
    for (final key in const ['PDF', 'pdf', 'pdfIdentifier']) {
      final value = feature.properties[key]?.toString().trim();
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }

    return null;
  }

  String _readAttribute(GisFeature feature, String key) {
    final value = feature.properties[key]?.toString().trim() ?? '';
    return value.isEmpty ? 'Sin datos' : value;
  }

  Future<List<String?>> _findSeriesPdfs(List<GisSoilSeries> series) {
    return Future.wait(
      series.map(
        (soilSeries) => _pdfSeriesRepository.findPdfForSeries(soilSeries.name),
      ),
    );
  }

  Widget _buildSeriesTile(
    BuildContext bottomSheetContext,
    GisSoilSeries series,
    String? assetPath,
  ) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(AppIcons.pdf),
      title: Text(series.displayLabel),
      trailing: assetPath == null
          ? const SizedBox(
              width: 120,
              child: Text('Memoria no disponible', textAlign: TextAlign.end),
            )
          : FilledButton.tonal(
              onPressed: () {
                _openSeriesPdf(bottomSheetContext, series, assetPath);
              },
              child: const Text('Abrir PDF'),
            ),
    );
  }

  Future<void> _openSeriesPdf(
    BuildContext bottomSheetContext,
    GisSoilSeries series,
    String assetPath,
  ) async {
    if (bottomSheetContext.mounted) {
      await Navigator.of(bottomSheetContext).maybePop();
    }
    if (!mounted) {
      return;
    }

    await openLocalPdfViewer(
      context,
      title: series.name,
      assetPath: assetPath,
      unavailableMessage: 'Serie no disponible.',
    );
  }
}

class _VisibleTileSnapshot {
  const _VisibleTileSnapshot({this.widgets = const <Widget>[]});

  final List<Widget> widgets;

  bool hasSameWidgets(_VisibleTileSnapshot other) {
    if (identical(this, other)) {
      return true;
    }
    if (widgets.length != other.widgets.length) {
      return false;
    }
    for (var index = 0; index < widgets.length; index++) {
      if (!identical(widgets[index], other.widgets[index])) {
        return false;
      }
    }
    return true;
  }
}

class _MapOverlayState {
  const _MapOverlayState({required this.isLoading, this.error});

  final bool isLoading;
  final String? error;

  @override
  bool operator ==(Object other) {
    return other is _MapOverlayState &&
        other.isLoading == isLoading &&
        other.error == error;
  }

  @override
  int get hashCode => Object.hash(isLoading, error);
}

enum _LayerVisibilityOption { soilPolygons, referenceBasemap }

class _BottomSheetSection extends StatelessWidget {
  const _BottomSheetSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            elevation: 0,
            color: Theme.of(context).colorScheme.surfaceContainer,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

class _LandscapeDescription extends StatelessWidget {
  const _LandscapeDescription({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Descripción',
            style: textTheme.labelLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(value, style: textTheme.bodyLarge),
        ],
      ),
    );
  }
}

class _SoilSeriesSummaryTile extends StatelessWidget {
  const _SoilSeriesSummaryTile({
    required this.series,
    required this.isDominant,
  });

  final GisSoilSeries series;
  final bool isDominant;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final percentage = series.percentage.isEmpty
        ? 'Sin porcentaje'
        : series.percentage.endsWith('%')
        ? series.percentage
        : '${series.percentage}%';

    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        series.name,
        style: isDominant
            ? textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)
            : textTheme.titleSmall,
      ),
      subtitle: Text(percentage),
      trailing: isDominant
          ? Chip(
              label: const Text('Principal'),
              backgroundColor: colorScheme.primaryContainer,
              labelStyle: TextStyle(color: colorScheme.onPrimaryContainer),
            )
          : null,
    );
  }
}

class _ParcelAnalysisMetric extends StatelessWidget {
  const _ParcelAnalysisMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(label, style: Theme.of(context).textTheme.bodyLarge),
            ),
            Text(
              value,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

class _ParcelCompositionContent extends StatelessWidget {
  const _ParcelCompositionContent({required this.analysis});

  final ParcelAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Composición del lote',
          key: const ValueKey('parcel-analysis-ready'),
          style: textTheme.titleLarge,
        ),
        const SizedBox(height: 14),
        if (analysis.soilComposition.isEmpty)
          Text(
            'No se encontraron unidades de suelo para este lote.',
            style: textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final tableWidth = math.max(640.0, constraints.maxWidth);
              return _HorizontalScrollAffordance(
                child: SizedBox(
                  width: tableWidth,
                  child: Table(
                    columnWidths: const {
                      0: FixedColumnWidth(90),
                      1: FlexColumnWidth(2),
                      2: FixedColumnWidth(110),
                      3: FixedColumnWidth(100),
                      4: FixedColumnWidth(80),
                    },
                    defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                    children: [
                      _buildHeaderRow(context),
                      for (final item in analysis.soilComposition)
                        _buildCompositionRow(context, item),
                    ],
                  ),
                ),
              );
            },
          ),
        if (analysis.soilComposition.isNotEmpty) ...[
          const SizedBox(height: 24),
          _ParcelDominantValue(
            label: 'Serie dominante',
            value: analysis.dominantSoilSeries ?? 'Sin datos',
          ),
          const SizedBox(height: 10),
          _ParcelDominantValue(
            label: 'Capacidad de uso dominante',
            value: analysis.dominantCapabilityClass ?? 'Sin datos',
          ),
        ],
      ],
    );
  }

  TableRow _buildHeaderRow(BuildContext context) {
    final style = Theme.of(
      context,
    ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700);
    return TableRow(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
      ),
      children: [
        _ParcelTableCell('Unidad', style: style),
        _ParcelTableCell('Serie dominante', style: style),
        _ParcelTableCell('Capacidad', style: style),
        _ParcelTableCell('Área (ha)', style: style, numeric: true),
        _ParcelTableCell('%', style: style, numeric: true),
      ],
    );
  }

  TableRow _buildCompositionRow(
    BuildContext context,
    ParcelSoilComposition item,
  ) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return TableRow(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 0.5,
          ),
        ),
      ),
      children: [
        _ParcelTableCell(
          item.unitSymbol.isEmpty ? 'Sin datos' : item.unitSymbol,
          style: style?.copyWith(fontWeight: FontWeight.w700),
        ),
        _ParcelTableCell(
          item.dominantSoilSeries.isEmpty
              ? 'Sin datos'
              : item.dominantSoilSeries,
          style: style,
        ),
        _ParcelTableCell(
          item.capabilityClass.isEmpty ? 'Sin datos' : item.capabilityClass,
          style: style,
        ),
        _ParcelTableCell(
          item.areaHectares.toStringAsFixed(2),
          style: style,
          numeric: true,
        ),
        _ParcelTableCell(
          item.percentage.toStringAsFixed(1),
          style: style,
          numeric: true,
        ),
      ],
    );
  }
}

class _SearchViewLayoutObserver extends StatelessWidget {
  const _SearchViewLayoutObserver({
    required this.onCoverageChanged,
    required this.suggestions,
  });

  static const double _headerAndDividerHeight = 65;
  final ValueChanged<double> onCoverageChanged;
  final Iterable<Widget> suggestions;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = MediaQuery.sizeOf(context);
        final keyboardHeight = MediaQuery.viewInsetsOf(context).bottom;
        final contentSize = constraints.biggest;
        final overlayHeight = math.min(
          viewport.height,
          contentSize.height + _headerAndDividerHeight + keyboardHeight,
        );
        final viewportArea = viewport.width * viewport.height;
        final overlayArea = contentSize.width * overlayHeight;
        final coverage = viewportArea > 0 && overlayArea.isFinite
            ? (overlayArea / viewportArea).clamp(0.0, 1.0)
            : 0.0;
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => onCoverageChanged(coverage),
        );

        return MediaQuery.removePadding(
          context: context,
          removeTop: true,
          child: ListView(
            padding: EdgeInsets.only(bottom: keyboardHeight),
            children: suggestions.toList(growable: false),
          ),
        );
      },
    );
  }
}

class _HorizontalScrollAffordance extends StatefulWidget {
  const _HorizontalScrollAffordance({required this.child});

  final Widget child;

  @override
  State<_HorizontalScrollAffordance> createState() =>
      _HorizontalScrollAffordanceState();
}

class _HorizontalScrollAffordanceState
    extends State<_HorizontalScrollAffordance> {
  final ScrollController _controller = ScrollController();
  bool _showEndHint = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_updateEndHint);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateEndHint());
  }

  @override
  void didUpdateWidget(_HorizontalScrollAffordance oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateEndHint());
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_updateEndHint)
      ..dispose();
    super.dispose();
  }

  void _updateEndHint() {
    if (!mounted || !_controller.hasClients) return;
    final shouldShow = _controller.position.extentAfter > 1;
    if (_showEndHint != shouldShow) {
      setState(() => _showEndHint = shouldShow);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        SingleChildScrollView(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          child: widget.child,
        ),
        Positioned(
          top: 0,
          right: 0,
          bottom: 0,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _showEndHint ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              child: Container(
                width: 42,
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 4),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      colorScheme.surfaceContainerLow.withValues(alpha: 0),
                      colorScheme.surfaceContainerLow.withValues(alpha: 0.94),
                    ],
                  ),
                ),
                child: Icon(
                  AppIcons.chevronRight,
                  size: 16,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ParcelTableCell extends StatelessWidget {
  const _ParcelTableCell(
    this.value, {
    required this.style,
    this.numeric = false,
  });

  final String value;
  final TextStyle? style;
  final bool numeric;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      child: Text(
        value,
        style: style,
        textAlign: numeric ? TextAlign.end : TextAlign.start,
      ),
    );
  }
}

class _ParcelDominantValue extends StatelessWidget {
  const _ParcelDominantValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: 16),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

class _DesktopMapToolsPanel extends StatefulWidget {
  const _DesktopMapToolsPanel({
    required this.collapsed,
    required this.selectedSection,
    required this.onCollapsedChanged,
    required this.onSelectSection,
    required this.activeMode,
    required this.onMeasureDistance,
    required this.onMeasureArea,
    required this.onAddMarker,
  });

  final bool collapsed;
  final _DesktopPanelSection? selectedSection;
  final ValueChanged<bool> onCollapsedChanged;
  final ValueChanged<_DesktopPanelSection> onSelectSection;
  final _DesktopActiveMode? activeMode;
  final VoidCallback onMeasureDistance;
  final VoidCallback onMeasureArea;
  final VoidCallback onAddMarker;

  @override
  State<_DesktopMapToolsPanel> createState() => _DesktopMapToolsPanelState();
}

class _DesktopMapToolsPanelState extends State<_DesktopMapToolsPanel>
    with TickerProviderStateMixin {
  bool get collapsed => widget.collapsed;
  _DesktopPanelSection? get selectedSection => widget.selectedSection;
  ValueChanged<bool> get onCollapsedChanged => widget.onCollapsedChanged;
  ValueChanged<_DesktopPanelSection> get onSelectSection =>
      widget.onSelectSection;
  _DesktopActiveMode? get activeMode => widget.activeMode;
  VoidCallback get onMeasureDistance => widget.onMeasureDistance;
  VoidCallback get onMeasureArea => widget.onMeasureArea;
  VoidCallback get onAddMarker => widget.onAddMarker;

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.duration(
      context,
      const Duration(milliseconds: 200),
    );
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeOutCubic,
      layoutBuilder: (currentChild, previousChildren) =>
          currentChild ?? const SizedBox.shrink(),
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: KeyedSubtree(
        key: ValueKey(collapsed),
        child: collapsed ? _buildCollapsedPanel() : _buildExpandedPanel(),
      ),
    );
  }

  Widget _buildExpandedPanel() {
    final iconColor = Theme.of(context).colorScheme.primary;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.72,
      ),
      child: Scrollbar(
        child: SingleChildScrollView(
          primary: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(AppIcons.layers, color: iconColor),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Navegación GIS',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Contraer herramientas',
                    onPressed: () => onCollapsedChanged(true),
                    icon: const Icon(AppIcons.chevronRight),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _DesktopMapPanelAction(
                icon: AppIcons.layers,
                label: 'Capas',
                selected: selectedSection == _DesktopPanelSection.layers,
                onTap: () => onSelectSection(_DesktopPanelSection.layers),
              ),
              _DesktopMapPanelAction(
                icon: AppIcons.search,
                label: 'Buscar',
                selected: selectedSection == _DesktopPanelSection.search,
                onTap: () => onSelectSection(_DesktopPanelSection.search),
              ),
              const _DesktopNavigationDivider(),
              _DesktopMapPanelAction(
                icon: Icons.history,
                label: 'Mediciones',
                selected: selectedSection == _DesktopPanelSection.measurements,
                onTap: () => onSelectSection(_DesktopPanelSection.measurements),
              ),
              _DesktopMapPanelAction(
                icon: Icons.bookmarks,
                label: 'Marcadores',
                selected: selectedSection == _DesktopPanelSection.markers,
                onTap: () => onSelectSection(_DesktopPanelSection.markers),
              ),
              _DesktopMapPanelAction(
                icon: AppIcons.star,
                label: 'Favoritos',
                selected: selectedSection == _DesktopPanelSection.favorites,
                onTap: () => onSelectSection(_DesktopPanelSection.favorites),
                isFavoritesAction: true,
              ),
              const _DesktopNavigationDivider(),
              _DesktopMapPanelAction(
                id: 'measure-distance',
                icon: AppIcons.ruler,
                label: 'Medir distancia',
                selected: activeMode == _DesktopActiveMode.distance,
                onTap: onMeasureDistance,
              ),
              _DesktopMapPanelAction(
                id: 'measure-area',
                icon: AppIcons.analytics,
                label: 'Medir área',
                selected: activeMode == _DesktopActiveMode.area,
                onTap: onMeasureArea,
              ),
              _DesktopMapPanelAction(
                id: 'add-marker',
                icon: AppIcons.addLocation,
                label: 'Agregar marcador',
                selected: activeMode == _DesktopActiveMode.marker,
                onTap: onAddMarker,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCollapsedPanel() {
    return SizedBox(
      width: 44,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.72,
        ),
        child: SingleChildScrollView(
          child: Column(
            key: const ValueKey('desktop-map-navigation-rail'),
            mainAxisSize: MainAxisSize.min,
            children: [
              _DesktopMapRailButton(
                id: 'expand',
                tooltip: 'Expandir herramientas',
                icon: AppIcons.layers,
                onPressed: () => onCollapsedChanged(false),
              ),
              const _DesktopNavigationDivider(compact: true),
              _DesktopMapRailButton(
                id: 'layers',
                tooltip: 'Capas',
                icon: AppIcons.layers,
                selected: selectedSection == _DesktopPanelSection.layers,
                onPressed: () => onSelectSection(_DesktopPanelSection.layers),
              ),
              _DesktopMapRailButton(
                id: 'search',
                tooltip: 'Buscar',
                icon: AppIcons.search,
                selected: selectedSection == _DesktopPanelSection.search,
                onPressed: () => onSelectSection(_DesktopPanelSection.search),
              ),
              const _DesktopNavigationDivider(compact: true),
              _DesktopMapRailButton(
                id: 'measurements',
                tooltip: 'Mediciones',
                icon: Icons.history,
                selected: selectedSection == _DesktopPanelSection.measurements,
                onPressed: () =>
                    onSelectSection(_DesktopPanelSection.measurements),
              ),
              _DesktopMapRailButton(
                id: 'markers',
                tooltip: 'Marcadores',
                icon: Icons.bookmarks,
                selected: selectedSection == _DesktopPanelSection.markers,
                onPressed: () => onSelectSection(_DesktopPanelSection.markers),
              ),
              _DesktopMapRailButton(
                id: 'favorites',
                tooltip: 'Favoritos',
                icon: AppIcons.star,
                selected: selectedSection == _DesktopPanelSection.favorites,
                onPressed: () =>
                    onSelectSection(_DesktopPanelSection.favorites),
                isFavoritesAction: true,
              ),
              const _DesktopNavigationDivider(compact: true),
              _DesktopMapRailButton(
                id: 'measure-distance',
                tooltip: 'Medir distancia',
                icon: AppIcons.ruler,
                selected: activeMode == _DesktopActiveMode.distance,
                onPressed: onMeasureDistance,
              ),
              _DesktopMapRailButton(
                id: 'measure-area',
                tooltip: 'Medir área',
                icon: AppIcons.analytics,
                selected: activeMode == _DesktopActiveMode.area,
                onPressed: onMeasureArea,
              ),
              _DesktopMapRailButton(
                id: 'add-marker',
                tooltip: 'Agregar marcador',
                icon: AppIcons.addLocation,
                selected: activeMode == _DesktopActiveMode.marker,
                onPressed: onAddMarker,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopNavigationDivider extends StatelessWidget {
  const _DesktopNavigationDivider({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 8 : 10),
      child: Divider(
        height: 1,
        color: Theme.of(
          context,
        ).colorScheme.outlineVariant.withValues(alpha: 0.75),
      ),
    );
  }
}

class _DesktopCloseButton extends StatefulWidget {
  const _DesktopCloseButton({required this.tooltip, required this.onPressed});

  final String tooltip;
  final VoidCallback onPressed;

  @override
  State<_DesktopCloseButton> createState() => _DesktopCloseButtonState();
}

class _DesktopCloseButtonState extends State<_DesktopCloseButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final emphasized = _hovered || _focused;
    final duration = AppMotion.duration(
      context,
      const Duration(milliseconds: 190),
    );
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 350),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: duration,
          curve: Curves.easeOutCubic,
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: emphasized
                ? colorScheme.primaryContainer
                : colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: widget.onPressed,
              onFocusChange: (focused) => setState(() => _focused = focused),
              splashColor: colorScheme.primary.withValues(alpha: 0.12),
              child: Icon(
                AppIcons.close,
                size: 20,
                color: emphasized
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The Favoritos entry's icon in the GIS toolbar (both
/// [_DesktopMapPanelAction] and [_DesktopMapRailButton]) — reuses the exact
/// visual language already established for Favorites everywhere else
/// (Cartas de Suelo, the Favoritos screen): a filled star in
/// [ColorScheme.primary] sitting in a soft circular
/// [ColorScheme.primaryContainer] badge when active, an outline star with
/// no badge otherwise, and the same pop-in scale transition. Here "active"
/// means this toolbar's Favoritos section is the one currently selected,
/// not that a polygon is favorited — same visual grammar, different
/// trigger. Every sibling tool (Capas, Buscar, Mediciones, Marcadores, Mi
/// ubicación, medir distancia/área, agregar marcador) keeps rendering its
/// own plain icon, untouched.
class _FavoriteToolbarIcon extends StatelessWidget {
  const _FavoriteToolbarIcon({
    required this.active,
    required this.color,
    required this.size,
  });

  final bool active;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AnimatedSwitcher(
      duration: AppMotion.duration(
        context,
        const Duration(milliseconds: 220),
        reduced: const Duration(milliseconds: 60),
      ),
      switchInCurve: Curves.easeOutBack,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) =>
          ScaleTransition(scale: animation, child: child),
      child: Container(
        key: ValueKey(active),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active
              ? colorScheme.primaryContainer.withValues(alpha: 0.55)
              : Colors.transparent,
        ),
        child: Icon(
          AppIcons.star,
          size: size,
          color: color,
          fill: active ? 1 : 0,
        ),
      ),
    );
  }
}

class _DesktopMapPanelAction extends StatefulWidget {
  const _DesktopMapPanelAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.id,
    this.selected = false,
    this.isFavoritesAction = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final String? id;
  final bool selected;

  /// True only for the Favoritos entry — swaps its icon for
  /// [_FavoriteToolbarIcon] so it reads as part of the same Favorites
  /// system as Cartas de Suelo/the Favoritos screen (filled star + soft
  /// circular badge when selected) instead of this row's generic icon
  /// treatment. Every other action keeps rendering [icon] plainly,
  /// unchanged.
  final bool isFavoritesAction;

  @override
  State<_DesktopMapPanelAction> createState() => _DesktopMapPanelActionState();
}

class _DesktopMapPanelActionState extends State<_DesktopMapPanelAction> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final enabled = widget.onTap != null;
    final emphasized = widget.selected || _hovered || _focused;
    final foreground = widget.selected
        ? colorScheme.onSecondaryContainer
        : colorScheme.primary;
    final duration = AppMotion.duration(
      context,
      const Duration(milliseconds: 190),
    );
    return Tooltip(
      message: widget.label,
      waitDuration: const Duration(milliseconds: 350),
      exitDuration: const Duration(milliseconds: 100),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: enabled ? (_) => setState(() => _hovered = true) : null,
        onExit: enabled ? (_) => setState(() => _hovered = false) : null,
        child: Semantics(
          button: true,
          enabled: enabled,
          selected: widget.selected,
          child: AnimatedScale(
            duration: duration,
            curve: Curves.easeOutCubic,
            scale: _hovered && enabled ? 1.01 : 1,
            child: AnimatedContainer(
              key: widget.id == null
                  ? null
                  : ValueKey('desktop-map-action-${widget.id}'),
              duration: duration,
              curve: Curves.easeOutCubic,
              decoration: BoxDecoration(
                color: widget.selected
                    ? colorScheme.secondaryContainer
                    : emphasized
                    ? colorScheme.primaryContainer.withValues(alpha: 0.52)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: widget.selected
                      ? colorScheme.primary.withValues(alpha: 0.38)
                      : Colors.transparent,
                ),
              ),
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(14),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: widget.onTap,
                  canRequestFocus: enabled,
                  onFocusChange: (focused) =>
                      setState(() => _focused = focused),
                  splashColor: colorScheme.primary.withValues(alpha: 0.12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 11,
                    ),
                    child: Row(
                      children: [
                        if (widget.isFavoritesAction)
                          _FavoriteToolbarIcon(
                            active: widget.selected,
                            color: enabled
                                ? foreground
                                : colorScheme.onSurface.withValues(alpha: 0.38),
                            size: 20,
                          )
                        else
                          Icon(
                            widget.icon,
                            size: 20,
                            color: enabled
                                ? foreground
                                : colorScheme.onSurface.withValues(alpha: 0.38),
                          ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            widget.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyLarge
                                ?.copyWith(
                                  color: widget.selected
                                      ? colorScheme.onSecondaryContainer
                                      : null,
                                  fontWeight: widget.selected
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopMapRailButton extends StatefulWidget {
  const _DesktopMapRailButton({
    required this.id,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.selected = false,
    this.isFavoritesAction = false,
  });

  final String id;
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool selected;

  /// True only for the Favoritos entry — see
  /// [_DesktopMapPanelAction.isFavoritesAction].
  final bool isFavoritesAction;

  @override
  State<_DesktopMapRailButton> createState() => _DesktopMapRailButtonState();
}

class _DesktopMapRailButtonState extends State<_DesktopMapRailButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final enabled = widget.onPressed != null;
    final emphasized = widget.selected || _hovered || _focused;
    final duration = AppMotion.duration(
      context,
      const Duration(milliseconds: 190),
    );
    final foreground = widget.selected
        ? colorScheme.onSecondaryContainer
        : colorScheme.primary;

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 350),
      exitDuration: const Duration(milliseconds: 100),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: enabled ? (_) => setState(() => _hovered = true) : null,
        onExit: enabled ? (_) => setState(() => _hovered = false) : null,
        child: Semantics(
          button: true,
          enabled: enabled,
          selected: widget.selected,
          label: widget.tooltip,
          child: AnimatedScale(
            duration: duration,
            curve: Curves.easeOutCubic,
            scale: _hovered && enabled ? 1.03 : 1,
            child: AnimatedContainer(
              key: ValueKey('desktop-map-rail-${widget.id}'),
              duration: duration,
              curve: Curves.easeOutCubic,
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: widget.selected
                    ? colorScheme.secondaryContainer
                    : (emphasized
                          ? colorScheme.primaryContainer.withValues(alpha: 0.58)
                          : Colors.transparent),
                borderRadius: BorderRadius.circular(14),
                border: widget.selected
                    ? Border.all(
                        color: colorScheme.primary.withValues(alpha: 0.34),
                      )
                    : null,
                boxShadow: widget.selected
                    ? [
                        BoxShadow(
                          color: colorScheme.shadow.withValues(alpha: 0.12),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : const [],
              ),
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(14),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  canRequestFocus: enabled,
                  onFocusChange: (focused) =>
                      setState(() => _focused = focused),
                  onTap: widget.onPressed,
                  child: widget.isFavoritesAction
                      ? _FavoriteToolbarIcon(
                          active: widget.selected,
                          color: enabled
                              ? foreground
                              : colorScheme.onSurface.withValues(alpha: 0.38),
                          size: 20,
                        )
                      : Icon(
                          widget.icon,
                          size: 20,
                          color: enabled
                              ? foreground
                              : colorScheme.onSurface.withValues(alpha: 0.38),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopPanelTransition extends StatelessWidget {
  const _DesktopPanelTransition({required this.panelKey, required this.child});

  final Object panelKey;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: AppMotion.duration(context, const Duration(milliseconds: 200)),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.055, 0),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: KeyedSubtree(key: ValueKey(panelKey), child: child),
    );
  }
}

class _DesktopHeaderMapStatus extends StatelessWidget {
  const _DesktopHeaderMapStatus({required this.zoom});

  final double zoom;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.42),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _DesktopHeaderStatusItem(
              icon: Icons.zoom_in_outlined,
              label: 'Zoom ${zoom.round()}',
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopFullscreenButton extends StatelessWidget {
  const _DesktopFullscreenButton({required this.service});

  final DesktopWindowService service;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DesktopFullscreenStateBuilder(
      service: service,
      builder: (context, fullScreen) {
        return IconButton(
          tooltip: fullScreen
              ? 'Salir de pantalla completa'
              : 'Pantalla completa',
          onPressed: service.isTransitioning
              ? null
              : () => unawaited(service.toggleFullScreen()),
          icon: Icon(
            fullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
            size: 21,
          ),
          style: IconButton.styleFrom(
            foregroundColor: colorScheme.primary,
            backgroundColor: colorScheme.surfaceContainerLow,
            disabledBackgroundColor: colorScheme.surfaceContainerLow,
            side: BorderSide(
              color: colorScheme.outlineVariant.withValues(alpha: 0.42),
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        );
      },
    );
  }
}

class _DesktopHeaderStatusItem extends StatelessWidget {
  const _DesktopHeaderStatusItem({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: colorScheme.primary),
        const SizedBox(width: 6),
        Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _DesktopActiveModePanel extends StatelessWidget {
  const _DesktopActiveModePanel({
    required this.mode,
    required this.vertexCount,
    required this.liveValue,
    required this.onDismiss,
  });

  final _DesktopActiveMode mode;
  final int? vertexCount;
  final String? liveValue;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (title, instruction, icon) = switch (mode) {
      _DesktopActiveMode.distance => (
        'Medir distancia',
        'Hacé clic en el mapa para continuar midiendo.',
        AppIcons.ruler,
      ),
      _DesktopActiveMode.area => (
        'Medir área',
        'Hacé clic en el mapa para continuar dibujando.',
        AppIcons.analytics,
      ),
      _DesktopActiveMode.marker => (
        'Agregar marcador',
        'Hacé clic en el mapa para colocar un marcador.',
        AppIcons.addLocation,
      ),
    };

    return _DesktopContextPanel(
      title: title,
      icon: icon,
      onDismiss: onDismiss,
      showCloseButton: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colorScheme.primaryContainer.withValues(alpha: 0.24),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: colorScheme.primary.withValues(alpha: 0.18),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Modo activo',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                instruction,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  height: 1.35,
                ),
              ),
              if (vertexCount case final count?) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 16,
                  runSpacing: 6,
                  children: [
                    _DesktopModeMetric(
                      icon: AppIcons.location,
                      label: '$count ${count == 1 ? 'vértice' : 'vértices'}',
                    ),
                    if (liveValue != null)
                      _DesktopModeMetric(
                        icon: mode == _DesktopActiveMode.area
                            ? AppIcons.analytics
                            : AppIcons.ruler,
                        label: liveValue!,
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Text(
                'Esc para cancelar',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopModeMetric extends StatelessWidget {
  const _DesktopModeMetric({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: colorScheme.primary),
        const SizedBox(width: 6),
        Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: colorScheme.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _DesktopSearchPanel extends StatefulWidget {
  const _DesktopSearchPanel({
    required this.entries,
    required this.selectedFeatureId,
    required this.recentEntries,
    required this.onSelect,
    required this.onDismiss,
  });

  final List<_SoilSeriesSearchEntry> entries;
  final String? selectedFeatureId;
  final List<_SoilSeriesSearchEntry> recentEntries;
  final ValueChanged<_SoilSeriesSearchEntry> onSelect;
  final VoidCallback onDismiss;

  @override
  State<_DesktopSearchPanel> createState() => _DesktopSearchPanelState();
}

class _DesktopSearchPanelState extends State<_DesktopSearchPanel> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _normalizeSearchText(_controller.text);
    final filtered = query.isEmpty
        ? const <_SoilSeriesSearchEntry>[]
        : widget.entries
              .where((entry) => entry.normalizedName.contains(query))
              .toList(growable: false);
    final groupedEntries = <Widget>[];
    for (final type in _MapSearchEntryType.values) {
      final entries = filtered.where((entry) => entry.type == type).toList()
        ..sort((first, second) {
          final rankComparison = _searchMatchRank(
            first.normalizedName,
            query,
          ).compareTo(_searchMatchRank(second.normalizedName, query));
          return rankComparison != 0
              ? rankComparison
              : first.name.compareTo(second.name);
        });
      if (entries.isEmpty) continue;
      groupedEntries.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
          child: Text(
            type.sectionTitle,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
      groupedEntries.addAll(
        entries.take(12).map((entry) {
          final selected = widget.selectedFeatureId == entry.feature.id;
          return _DesktopSearchResultRow(
            entry: entry,
            selected: selected,
            onTap: () {
              logSubmittedSearch(_controller.text);
              widget.onSelect(entry);
            },
          );
        }),
      );
    }

    return _DesktopContextPanel(
      title: 'Buscar',
      subtitle: query.isEmpty
          ? 'Localidades, unidades y series de suelo'
          : '${filtered.length} resultados',
      icon: AppIcons.search,
      onDismiss: widget.onDismiss,
      child: SizedBox(
        height: math.min(560, MediaQuery.sizeOf(context).height * 0.64),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DesktopPanelSearchField(
              fieldKey: const ValueKey('desktop-map-search-field'),
              controller: _controller,
              focusNode: _focusNode,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              hintText: 'Localidad, unidad o serie...',
            ),
            const SizedBox(height: 12),
            Expanded(
              child: query.isEmpty
                  ? _DesktopSearchEmptyState(
                      recentEntries: widget.recentEntries,
                      onSelect: widget.onSelect,
                    )
                  : groupedEntries.isEmpty
                  ? const _DesktopPanelNoSearchResults()
                  : ListView(
                      padding: EdgeInsets.zero,
                      children: groupedEntries,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopPanelSearchField extends StatelessWidget {
  const _DesktopPanelSearchField({
    required this.fieldKey,
    required this.controller,
    required this.onChanged,
    required this.hintText,
    this.focusNode,
    this.autofocus = false,
    this.onSubmitted,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final ValueChanged<String> onChanged;
  final String hintText;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: fieldKey,
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      textInputAction: TextInputAction.search,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        hintText: hintText,
        prefixIcon: const Icon(AppIcons.search, size: 20),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Limpiar búsqueda',
                onPressed: () {
                  controller.clear();
                  focusNode?.requestFocus();
                  onChanged('');
                },
                icon: const Icon(AppIcons.close, size: 18),
              ),
        filled: true,
        fillColor: Theme.of(context).colorScheme.surfaceContainerLow,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _DesktopPanelNoSearchResults extends StatelessWidget {
  const _DesktopPanelNoSearchResults();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'No hay coincidencias.',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _DesktopSearchEmptyState extends StatelessWidget {
  const _DesktopSearchEmptyState({
    required this.recentEntries,
    required this.onSelect,
  });

  final List<_SoilSeriesSearchEntry> recentEntries;
  final ValueChanged<_SoilSeriesSearchEntry> onSelect;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.only(top: 8),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(AppIcons.search, size: 20, color: colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Escribí una localidad, unidad cartográfica o serie de suelo.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 24),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text(
            'Búsquedas recientes',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (recentEntries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
            child: Text(
              'Todavía no hay búsquedas recientes.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          ...recentEntries.map(
            (entry) => _DesktopSearchResultRow(
              entry: entry,
              selected: false,
              onTap: () => onSelect(entry),
            ),
          ),
      ],
    );
  }
}

class _DesktopSearchResultRow extends StatelessWidget {
  const _DesktopSearchResultRow({
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final _SoilSeriesSearchEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected ? colorScheme.secondaryContainer : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: selected
              ? BorderSide(color: colorScheme.primary.withValues(alpha: 0.36))
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          hoverColor: colorScheme.primaryContainer.withValues(alpha: 0.48),
          splashColor: colorScheme.primary.withValues(alpha: 0.12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                Icon(entry.type.icon, size: 19, color: colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        entry.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopLayersPanel extends StatelessWidget {
  const _DesktopLayersPanel({
    required this.showSoilPolygons,
    required this.showReferenceBasemap,
    required this.onToggleSoilPolygons,
    required this.onToggleReferenceBasemap,
    required this.onDismiss,
  });

  final bool showSoilPolygons;
  final bool showReferenceBasemap;
  final VoidCallback onToggleSoilPolygons;
  final VoidCallback onToggleReferenceBasemap;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return _DesktopContextPanel(
      title: 'Capas',
      subtitle: '2 capas disponibles',
      icon: AppIcons.layers,
      onDismiss: onDismiss,
      child: Column(
        children: [
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: showSoilPolygons,
            onChanged: (_) => onToggleSoilPolygons(),
            title: const Text('Suelos'),
            subtitle: const Text('Unidades cartográficas'),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: showReferenceBasemap,
            onChanged: (_) => onToggleReferenceBasemap(),
            title: const Text('Referencia'),
            subtitle: const Text('Localidades y caminos'),
          ),
        ],
      ),
    );
  }
}

class _DesktopCollectionPanel<T> extends StatefulWidget {
  const _DesktopCollectionPanel({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.items,
    required this.searchFieldKey,
    required this.searchHint,
    required this.searchTerms,
    required this.emptyMessage,
    required this.itemTitle,
    required this.itemSubtitle,
    required this.onSelect,
    required this.onDismiss,
    this.itemEnabled,
    this.itemSelected,
    this.itemMetaLabel,
    this.subtitleBuilder,
    this.trailingBuilder,
    this.leadingKey,
    this.leadingTooltip,
    this.onLeadingTap,
    this.headerAction,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Iterable<T> items;
  final Key searchFieldKey;
  final String searchHint;
  final Iterable<String> Function(T item) searchTerms;
  final String emptyMessage;
  final String Function(T item) itemTitle;
  final String Function(T item) itemSubtitle;
  final ValueChanged<T> onSelect;
  final VoidCallback onDismiss;
  final bool Function(T item)? itemEnabled;
  final bool Function(T item)? itemSelected;
  final String Function(T item)? itemMetaLabel;
  final String Function()? subtitleBuilder;
  final Widget Function(T item)? trailingBuilder;
  final Key Function(T item)? leadingKey;
  final String? leadingTooltip;
  final bool Function(T item)? onLeadingTap;
  final Widget? headerAction;

  @override
  State<_DesktopCollectionPanel<T>> createState() =>
      _DesktopCollectionPanelState<T>();
}

class _DesktopCollectionPanelState<T>
    extends State<_DesktopCollectionPanel<T>> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _normalizeSearchText(_controller.text);
    final items = widget.items.toList(growable: false);
    final filteredItems = query.isEmpty
        ? items
        : items
              .where(
                (item) => widget
                    .searchTerms(item)
                    .map(_normalizeSearchText)
                    .any((term) => term.contains(query)),
              )
              .toList(growable: false);

    return _DesktopContextPanel(
      title: widget.title,
      subtitle: query.isEmpty
          ? widget.subtitleBuilder?.call() ?? widget.subtitle
          : '${filteredItems.length} resultados',
      icon: widget.icon,
      onDismiss: widget.onDismiss,
      headerAction: widget.headerAction,
      child: SizedBox(
        height: math.min(560, MediaQuery.sizeOf(context).height * 0.64),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DesktopPanelSearchField(
              fieldKey: widget.searchFieldKey,
              controller: _controller,
              focusNode: _focusNode,
              onChanged: (_) => setState(() {}),
              onSubmitted: logSubmittedSearch,
              hintText: widget.searchHint,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: query.isNotEmpty && filteredItems.isEmpty
                  ? const _DesktopPanelNoSearchResults()
                  : items.isEmpty
                  ? _DesktopCollectionEmptyState(
                      icon: widget.icon,
                      message: widget.emptyMessage,
                    )
                  : ListView.separated(
                      padding: EdgeInsets.zero,
                      physics: const ClampingScrollPhysics(),
                      itemCount: filteredItems.length,
                      separatorBuilder: (context, index) =>
                          const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final item = filteredItems[index];
                        final enabled = widget.itemEnabled?.call(item) ?? true;
                        final selected =
                            widget.itemSelected?.call(item) ?? false;
                        final colorScheme = Theme.of(context).colorScheme;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Material(
                            color: selected
                                ? colorScheme.secondaryContainer
                                : Colors.transparent,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                              side: selected
                                  ? BorderSide(
                                      color: colorScheme.primary.withValues(
                                        alpha: 0.36,
                                      ),
                                    )
                                  : BorderSide.none,
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: ListTile(
                              selected: selected,
                              selectedColor: colorScheme.onSecondaryContainer,
                              hoverColor: colorScheme.primaryContainer
                                  .withValues(alpha: 0.48),
                              splashColor: colorScheme.primary.withValues(
                                alpha: 0.12,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              minVerticalPadding: 10,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              leading: widget.onLeadingTap == null
                                  ? Icon(widget.icon, size: 20)
                                  : Tooltip(
                                      message: widget.leadingTooltip ?? '',
                                      child: InkResponse(
                                        key: widget.leadingKey?.call(item),
                                        onTap: () {
                                          if (widget.onLeadingTap!(item)) {
                                            setState(() {});
                                          }
                                        },
                                        child: Icon(widget.icon, size: 20),
                                      ),
                                    ),
                              title: Text(
                                widget.itemTitle(item),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w600),
                              ),
                              subtitle: widget.itemMetaLabel == null
                                  ? Text(
                                      widget.itemSubtitle(item),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: selected
                                                ? colorScheme
                                                      .onSecondaryContainer
                                                      .withValues(alpha: 0.78)
                                                : colorScheme.onSurfaceVariant,
                                          ),
                                    )
                                  : Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            widget.itemMetaLabel!(item),
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelSmall
                                                ?.copyWith(
                                                  color: colorScheme
                                                      .onSurfaceVariant,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                          ),
                                          const SizedBox(height: 1),
                                          Text(
                                            widget.itemSubtitle(item),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(
                                                  color: selected
                                                      ? colorScheme
                                                            .onSecondaryContainer
                                                            .withValues(
                                                              alpha: 0.78,
                                                            )
                                                      : colorScheme
                                                            .onSurfaceVariant,
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                              enabled: enabled,
                              trailing:
                                  widget.trailingBuilder?.call(item) ??
                                  const Icon(AppIcons.chevronRight, size: 18),
                              onTap: enabled
                                  ? () => widget.onSelect(item)
                                  : null,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopCollectionEmptyState extends StatelessWidget {
  const _DesktopCollectionEmptyState({
    required this.icon,
    required this.message,
  });

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 28, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopContextPanel extends StatelessWidget {
  const _DesktopContextPanel({
    required this.title,
    required this.icon,
    required this.onDismiss,
    required this.child,
    this.subtitle,
    this.headerAction,
    this.showCloseButton = false,
  });

  final String title;
  final IconData icon;
  final String? subtitle;
  final VoidCallback onDismiss;
  final Widget child;
  final Widget? headerAction;
  final bool showCloseButton;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.68,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    if (subtitle case final subtitle?) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              ?headerAction,
              if (showCloseButton)
                _DesktopCloseButton(
                  tooltip: 'Cerrar panel',
                  onPressed: onDismiss,
                ),
            ],
          ),
          SizedBox(height: subtitle == null ? 10 : 16),
          Flexible(child: child),
        ],
      ),
    );
  }
}

class _DesktopMapInformationPanel extends StatelessWidget {
  const _DesktopMapInformationPanel({
    required this.feature,
    required this.measurement,
    required this.marker,
    required this.onOpenFeatureDetails,
    required this.featureIsFavorite,
    required this.onToggleFeatureFavorite,
    required this.onAnalyzeMeasurement,
    required this.onEditMeasurement,
    required this.onHideMeasurement,
    required this.onOpenMarkerDetails,
    required this.onEditMarker,
    required this.onDeleteMarker,
    required this.markerDate,
    required this.onExportMeasurementPdf,
    required this.onExportMeasurementGeoJson,
    required this.onExportMeasurementCsv,
    required this.onDeleteMeasurement,
  });

  final GisFeature? feature;
  final SavedMeasurement? measurement;
  final PersonalMarker? marker;
  final VoidCallback? onOpenFeatureDetails;
  final bool featureIsFavorite;
  final VoidCallback? onToggleFeatureFavorite;
  final VoidCallback? onAnalyzeMeasurement;
  final VoidCallback? onEditMeasurement;
  final VoidCallback? onHideMeasurement;
  final VoidCallback? onOpenMarkerDetails;
  final VoidCallback? onEditMarker;
  final VoidCallback? onDeleteMarker;
  final String? markerDate;
  final VoidCallback? onExportMeasurementPdf;
  final VoidCallback? onExportMeasurementGeoJson;
  final VoidCallback? onExportMeasurementCsv;
  final VoidCallback? onDeleteMeasurement;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unitSymbol = feature?.properties['SIMBC']?.toString().trim();
    final title = switch ((feature, measurement, marker)) {
      (final GisFeature value, _, _) =>
        GisSoilSeries.fromProperties(value.properties).firstOrNull?.name ??
            _featureValue(value, 'Nombre_UC'),
      (_, final SavedMeasurement value, _) => value.name,
      (_, _, final PersonalMarker value) => value.name,
      _ => '',
    };
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.62,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            if (feature case final selectedFeature?) ...[
              _DesktopMapInformationValue(
                label: 'Unidad cartográfica',
                value: _featureValue(selectedFeature, 'Nombre_UC'),
              ),
              _DesktopMapInformationValue(
                label: 'Capacidad de uso',
                value: _featureValue(selectedFeature, 'CAP_USO'),
              ),
              if (unitSymbol != null && unitSymbol.isNotEmpty)
                _DesktopMapInformationValue(
                  label: 'Símbolo',
                  value: unitSymbol,
                ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: onOpenFeatureDetails,
                    icon: const Icon(AppIcons.library, size: 18),
                    label: const Text('Ver información'),
                  ),
                  IconButton.filledTonal(
                    tooltip: featureIsFavorite
                        ? 'Quitar de favoritos'
                        : 'Agregar a favoritos',
                    onPressed: onToggleFeatureFavorite,
                    icon: Icon(featureIsFavorite ? Icons.star : AppIcons.star),
                  ),
                ],
              ),
            ],
            if (measurement case final selectedMeasurement?) ...[
              _DesktopMapInformationValue(
                label: 'Tipo',
                value: selectedMeasurement.type == SavedMeasurementType.area
                    ? 'Área'
                    : 'Distancia',
              ),
              _DesktopMapInformationValue(
                label: selectedMeasurement.type == SavedMeasurementType.area
                    ? 'Área'
                    : 'Distancia',
                value: selectedMeasurement.type == SavedMeasurementType.area
                    ? _MeasurementLayer._formatArea(
                        selectedMeasurement.areaSquareMeters ?? 0,
                      )
                    : _MeasurementLayer._formatDistance(
                        selectedMeasurement.distanceMeters ?? 0,
                      ),
              ),
              if (selectedMeasurement.type == SavedMeasurementType.area)
                _DesktopMapInformationValue(
                  label: 'Perímetro',
                  value: _MeasurementLayer._formatDistance(
                    selectedMeasurement.perimeterMeters ?? 0,
                  ),
                ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (onAnalyzeMeasurement != null)
                    FilledButton.tonalIcon(
                      onPressed: onAnalyzeMeasurement,
                      icon: const Icon(AppIcons.analytics, size: 18),
                      label: const Text('Analizar lote'),
                    ),
                  OutlinedButton.icon(
                    onPressed: onEditMeasurement,
                    icon: const Icon(AppIcons.edit, size: 18),
                    label: const Text('Editar'),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Ocultar',
                    onPressed: onHideMeasurement,
                    icon: const Icon(AppIcons.visibilityOff),
                  ),
                  if (onExportMeasurementPdf != null &&
                      onExportMeasurementGeoJson != null &&
                      onExportMeasurementCsv != null &&
                      onDeleteMeasurement != null)
                    SavedMeasurementOverflowMenu(
                      onExportPdf: onExportMeasurementPdf!,
                      onExportGeoJson: onExportMeasurementGeoJson!,
                      onExportCsv: onExportMeasurementCsv!,
                      onDelete: onDeleteMeasurement!,
                    ),
                ],
              ),
            ],
            if (marker case final selectedMarker?) ...[
              _DesktopMapInformationValue(
                label: 'Tipo',
                value: selectedMarker.category.label,
              ),
              _DesktopMapInformationValue(
                label: 'Coordenadas',
                value:
                    '${selectedMarker.latitude.toStringAsFixed(6)}, ${selectedMarker.longitude.toStringAsFixed(6)}',
              ),
              if (markerDate != null)
                _DesktopMapInformationValue(
                  label: 'Creado',
                  value: markerDate!,
                ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: onOpenMarkerDetails,
                    icon: const Icon(AppIcons.map, size: 18),
                    label: const Text('Ver detalles'),
                  ),
                  OutlinedButton.icon(
                    onPressed: onEditMarker,
                    icon: const Icon(AppIcons.edit, size: 18),
                    label: const Text('Editar'),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Eliminar',
                    onPressed: onDeleteMarker,
                    icon: const Icon(AppIcons.delete),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _featureValue(GisFeature feature, String key) {
    final value = feature.properties[key]?.toString().trim();
    return value == null || value.isEmpty ? 'Sin datos' : value;
  }
}

class _DesktopMapInformationValue extends StatelessWidget {
  const _DesktopMapInformationValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(value, style: Theme.of(context).textTheme.bodyLarge),
        ],
      ),
    );
  }
}

enum _InteractionMode { none, measureDistance, measureArea, addMarker }

enum _MeasurementMode { distance, area }

enum _DesktopPanelSection { layers, search, measurements, markers, favorites }

enum _DesktopActiveMode { distance, area, marker }

enum _DesktopMarkerAction { edit, delete }

enum _MeasurementMenuOption { distance, area, exit }

enum _MeasurementExitDecision { save, discard, cancel }

enum _MapToolHintType { measureDistance, measureArea, marker, markerActive }

enum _VertexMenuOption { delete, cancel }

class _MapToolHintOverlay extends StatelessWidget {
  const _MapToolHintOverlay({required this.type, required this.top});

  final _MapToolHintType? type;
  final double top;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: top,
      left: 16,
      right: 16,
      child: IgnorePointer(
        child: Center(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) =>
                FadeTransition(opacity: animation, child: child),
            child: type == null
                ? const SizedBox.shrink(key: ValueKey('tool-hint-empty'))
                : _MapToolHintCard(key: ValueKey(type), type: type!),
          ),
        ),
      ),
    );
  }
}

class _MapToolHintCard extends StatelessWidget {
  const _MapToolHintCard({required this.type, super.key});

  final _MapToolHintType type;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final (icon, text) = switch (type) {
      _MapToolHintType.measureDistance || _MapToolHintType.measureArea => (
        AppIcons.ruler,
        'Toque el mapa para medir.',
      ),
      _MapToolHintType.marker => (
        AppIcons.addLocation,
        'Toque el mapa para marcar.',
      ),
      _MapToolHintType.markerActive => (
        AppIcons.addLocation,
        'Modo de marcador activo.',
      ),
    };

    return Material(
      color: Colors.white,
      elevation: 3,
      shadowColor: colorScheme.shadow.withValues(alpha: 0.16),
      surfaceTintColor: Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 38, maxHeight: 40),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 17, color: colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CurrentLocationLayer extends StatelessWidget {
  const _CurrentLocationLayer({
    required this.location,
    required this.showAccuracyCircle,
  });

  static const Color _locationBlue = Color(0xFF1976D2);

  final GisLocation location;
  final bool showAccuracyCircle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final accuracy = location.accuracyMeters;
    final hasAccuracyCircle =
        showAccuracyCircle &&
        accuracy != null &&
        accuracy.isFinite &&
        accuracy > 0;

    return IgnorePointer(
      child: Stack(
        children: [
          if (hasAccuracyCircle)
            CircleLayer(
              circles: [
                CircleMarker(
                  point: location.point,
                  radius: accuracy,
                  useRadiusInMeter: true,
                  color: _locationBlue.withValues(alpha: 0.12),
                  borderColor: _locationBlue.withValues(alpha: 0.42),
                  borderStrokeWidth: 1,
                ),
              ],
            ),
          MarkerLayer(
            markers: [
              Marker(
                point: location.point,
                width: 28,
                height: 28,
                child: Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: _locationBlue,
                      shape: BoxShape.circle,
                      border: Border.all(color: colorScheme.surface, width: 3),
                      boxShadow: [
                        BoxShadow(
                          color: colorScheme.shadow.withValues(alpha: 0.28),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: const SizedBox.square(dimension: 16),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SavedMeasurementsLayer extends StatefulWidget {
  const _SavedMeasurementsLayer({
    required this.measurements,
    required this.highlightedMeasurementId,
    required this.showLabels,
    required this.onHideMeasurement,
    required this.onSelectMeasurement,
  });

  final List<SavedMeasurement> measurements;
  final String? highlightedMeasurementId;
  final bool showLabels;
  final ValueChanged<SavedMeasurement> onHideMeasurement;
  final ValueChanged<SavedMeasurement> onSelectMeasurement;

  @override
  State<_SavedMeasurementsLayer> createState() =>
      _SavedMeasurementsLayerState();
}

class _SavedMeasurementsLayerState extends State<_SavedMeasurementsLayer> {
  String? _hoveredMeasurementId;

  bool get _supportsHover =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final orderedMeasurements = [
      ...widget.measurements.where(
        (measurement) => measurement.id != widget.highlightedMeasurementId,
      ),
      ...widget.measurements.where(
        (measurement) => measurement.id == widget.highlightedMeasurementId,
      ),
    ];
    final areas = orderedMeasurements.where(
      (measurement) =>
          measurement.type == SavedMeasurementType.area &&
          measurement.geometry.length >= 3,
    );
    final distances = orderedMeasurements.where(
      (measurement) =>
          measurement.type == SavedMeasurementType.distance &&
          measurement.geometry.length >= 2,
    );

    final geometryLayer = Stack(
      children: [
        if (areas.isNotEmpty)
          IgnorePointer(
            child: PolygonLayer(
              polygons: [
                for (final measurement in areas)
                  Polygon(
                    points: measurement.geometry,
                    color:
                        MeasurementColorOption.fromStorageValue(
                          measurement.colorId,
                        ).color.withValues(
                          alpha:
                              measurement.id == widget.highlightedMeasurementId
                              ? 0.42
                              : measurement.id == _hoveredMeasurementId
                              ? 0.34
                              : 0.25,
                        ),
                    borderColor: MeasurementColorOption.fromStorageValue(
                      measurement.colorId,
                    ).color,
                    borderStrokeWidth:
                        measurement.id == widget.highlightedMeasurementId
                        ? 6
                        : measurement.id == _hoveredMeasurementId
                        ? 4.5
                        : 3,
                  ),
              ],
            ),
          ),
        if (distances.isNotEmpty)
          IgnorePointer(
            child: PolylineLayer(
              polylines: [
                for (final measurement in distances)
                  Polyline(
                    points: measurement.geometry,
                    strokeWidth:
                        measurement.id == widget.highlightedMeasurementId
                        ? 8
                        : measurement.id == _hoveredMeasurementId
                        ? 5.5
                        : 4,
                    color: MeasurementColorOption.fromStorageValue(
                      measurement.colorId,
                    ).color,
                    borderStrokeWidth: 1.5,
                    borderColor: colorScheme.surface,
                  ),
              ],
            ),
          ),
      ],
    );
    final interactiveGeometryLayer = !_supportsHover
        ? geometryLayer
        : MouseRegion(
            cursor: _hoveredMeasurementId == null
                ? MouseCursor.defer
                : SystemMouseCursors.click,
            onHover: (event) =>
                _updateHoveredMeasurement(context, event.localPosition),
            onExit: (_) {
              if (_hoveredMeasurementId != null) {
                setState(() => _hoveredMeasurementId = null);
              }
            },
            child: geometryLayer,
          );
    return Stack(
      children: [
        interactiveGeometryLayer,
        if (widget.showLabels)
          Positioned.fill(
            child: _SavedMeasurementLabels(
              measurements: orderedMeasurements,
              selectedMeasurementId: widget.highlightedMeasurementId,
              hoveredMeasurementId: _hoveredMeasurementId,
              onHideMeasurement: widget.onHideMeasurement,
              onSelectMeasurement: widget.onSelectMeasurement,
              onHoverMeasurement: (measurementId) {
                if (_hoveredMeasurementId != measurementId) {
                  setState(() => _hoveredMeasurementId = measurementId);
                }
              },
            ),
          ),
      ],
    );
  }

  void _updateHoveredMeasurement(BuildContext context, Offset position) {
    final camera = MapCamera.of(context);
    String? hoveredId;
    for (final measurement in widget.measurements.reversed) {
      final points = measurement.geometry;
      if (points.length < 2) continue;
      final segmentCount = measurement.type == SavedMeasurementType.area
          ? points.length
          : points.length - 1;
      for (var index = 0; index < segmentCount; index++) {
        final start = camera.latLngToScreenOffset(points[index]);
        final end = camera.latLngToScreenOffset(
          points[(index + 1) % points.length],
        );
        if (_distanceToSegment(position, start, end) <= 10) {
          hoveredId = measurement.id;
          break;
        }
      }
      if (hoveredId != null) break;
    }
    if (hoveredId != _hoveredMeasurementId) {
      setState(() => _hoveredMeasurementId = hoveredId);
    }
  }

  static LatLng? _labelPoint(SavedMeasurement measurement) {
    final points = measurement.geometry;
    if (measurement.type == SavedMeasurementType.distance) {
      if (points.length < 2) return null;
      final index = points.length ~/ 2;
      final start = points[index - 1];
      final end = points[index];
      return _safeLatLng(
        (start.latitude + end.latitude) / 2,
        (start.longitude + end.longitude) / 2,
      );
    }
    if (points.length < 3) return null;
    return _safeLatLng(
      points.fold<double>(0, (sum, point) => sum + point.latitude) /
          points.length,
      points.fold<double>(0, (sum, point) => sum + point.longitude) /
          points.length,
    );
  }

  static String _label(SavedMeasurement measurement) {
    if (measurement.type == SavedMeasurementType.distance) {
      return '${measurement.name}\n'
          '${_MeasurementLayer._formatDistance(measurement.distanceMeters ?? 0)}';
    }
    return '${measurement.name}: '
        '${_MeasurementLayer._formatArea(measurement.areaSquareMeters ?? 0)}\n'
        'Perímetro: '
        '${_MeasurementLayer._formatDistance(measurement.perimeterMeters ?? 0)}';
  }
}

class _SavedMeasurementLabels extends StatelessWidget {
  const _SavedMeasurementLabels({
    required this.measurements,
    required this.selectedMeasurementId,
    required this.hoveredMeasurementId,
    required this.onHideMeasurement,
    required this.onSelectMeasurement,
    required this.onHoverMeasurement,
  });

  final List<SavedMeasurement> measurements;
  final String? selectedMeasurementId;
  final String? hoveredMeasurementId;
  final ValueChanged<SavedMeasurement> onHideMeasurement;
  final ValueChanged<SavedMeasurement> onSelectMeasurement;
  final ValueChanged<String?> onHoverMeasurement;

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    if (!_isFiniteCamera(camera)) {
      return const SizedBox.shrink();
    }
    final labelOpacity = ((camera.zoom - 7.5) / 3).clamp(0.0, 1.0);
    if (labelOpacity == 0) {
      return const SizedBox.shrink();
    }
    final selected = measurements.where(
      (measurement) => measurement.id == selectedMeasurementId,
    );
    final others = measurements.where(
      (measurement) => measurement.id != selectedMeasurementId,
    );
    final priorityOrder = [...selected, ...others];

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        final compactLayout = viewport.width < 600;
        final safeInsets = EdgeInsets.fromLTRB(
          8,
          compactLayout ? 164 : 80,
          8,
          compactLayout ? 140 : 80,
        );
        final occupied = <Rect>[];
        final placements = <_SavedMeasurementLabelPlacement>[];
        for (final measurement in priorityOrder) {
          final labelPoint = _SavedMeasurementsLayerState._labelPoint(
            measurement,
          );
          if (labelPoint == null) continue;
          final anchor = camera.latLngToScreenOffset(labelPoint);
          if (!_isFiniteOffset(anchor)) continue;
          final geometryBounds = _screenBounds(
            measurement.geometry
                .map(camera.latLngToScreenOffset)
                .where(_isFiniteOffset)
                .toList(growable: false),
          );
          if (!geometryBounds.overlaps(Offset.zero & viewport)) {
            continue;
          }
          final edgeOpacity = _edgeOpacity(anchor, viewport);
          if (edgeOpacity == 0) continue;
          final isSelected = measurement.id == selectedMeasurementId;
          final size = Size(
            isSelected ? 220 : 176,
            measurement.type == SavedMeasurementType.area
                ? (isSelected ? 68 : 58)
                : (isSelected ? 58 : 44),
          );
          final rect = _findAvailableRect(
            anchor: anchor,
            size: size,
            viewport: viewport,
            occupied: occupied,
            safeInsets: safeInsets,
          );
          if (rect == null) continue;
          occupied.add(rect.inflate(4));
          placements.add(
            _SavedMeasurementLabelPlacement(
              measurement: measurement,
              anchor: anchor,
              rect: rect,
              isSelected: isSelected,
              opacity: edgeOpacity,
            ),
          );
        }

        return IgnorePointer(
          ignoring: labelOpacity < 0.15,
          child: Opacity(
            opacity: labelOpacity,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _MeasurementLabelLeaderPainter(placements),
                    ),
                  ),
                ),
                for (final placement in placements)
                  Positioned.fromRect(
                    rect: placement.rect,
                    child: Opacity(
                      opacity: placement.opacity,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        onEnter: (_) =>
                            onHoverMeasurement(placement.measurement.id),
                        onHover: (_) =>
                            onHoverMeasurement(placement.measurement.id),
                        onExit: (_) => onHoverMeasurement(null),
                        child: GestureDetector(
                          key: ValueKey(
                            'select-saved-measurement-${placement.measurement.id}',
                          ),
                          behavior: HitTestBehavior.opaque,
                          onTap: () =>
                              onSelectMeasurement(placement.measurement),
                          child: Container(
                            key: ValueKey(
                              'saved-measurement-${placement.measurement.id}',
                            ),
                            decoration:
                                _mapHudDecoration(
                                  Theme.of(context).colorScheme,
                                ).copyWith(
                                  border: placement.isSelected
                                      ? Border.all(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                          width: 2,
                                        )
                                      : placement.measurement.id ==
                                            hoveredMeasurementId
                                      ? Border.all(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary
                                              .withValues(alpha: 0.55),
                                          width: 1.5,
                                        )
                                      : null,
                                ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Expanded(
                                  child: Text(
                                    _SavedMeasurementsLayerState._label(
                                      placement.measurement,
                                    ),
                                    textAlign: TextAlign.center,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelMedium
                                        ?.copyWith(
                                          fontWeight: FontWeight.w700,
                                          fontFeatures: const [
                                            FontFeature.tabularFigures(),
                                          ],
                                        ),
                                  ),
                                ),
                                SizedBox.square(
                                  dimension: 32,
                                  child: IconButton(
                                    key: ValueKey(
                                      'hide-saved-measurement-'
                                      '${placement.measurement.id}',
                                    ),
                                    tooltip: placement.measurement.isVisible
                                        ? 'Ocultar medición'
                                        : 'Mostrar medición',
                                    visualDensity: VisualDensity.compact,
                                    padding: EdgeInsets.zero,
                                    icon: Icon(
                                      placement.measurement.isVisible
                                          ? AppIcons.visibility
                                          : AppIcons.visibilityOff,
                                      size: 18,
                                    ),
                                    onPressed: () => onHideMeasurement(
                                      placement.measurement,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Rect _screenBounds(List<Offset> points) {
    var left = points.first.dx;
    var right = left;
    var top = points.first.dy;
    var bottom = top;
    for (final point in points.skip(1)) {
      left = math.min(left, point.dx);
      right = math.max(right, point.dx);
      top = math.min(top, point.dy);
      bottom = math.max(bottom, point.dy);
    }
    return Rect.fromLTRB(left, top, right, bottom).inflate(1);
  }

  double _edgeOpacity(Offset anchor, Size viewport) {
    const fadeDistance = 72.0;
    final distance = math.min(
      math.min(anchor.dx, viewport.width - anchor.dx),
      math.min(anchor.dy, viewport.height - anchor.dy),
    );
    return (distance / fadeDistance).clamp(0.0, 1.0);
  }

  Rect? _findAvailableRect({
    required Offset anchor,
    required Size size,
    required Size viewport,
    required List<Rect> occupied,
    required EdgeInsets safeInsets,
  }) {
    const gap = 12.0;
    final offsets = <Offset>[
      Offset(-size.width / 2, -size.height - gap),
      Offset(gap, -size.height / 2),
      Offset(-size.width - gap, -size.height / 2),
      Offset(-size.width / 2, gap),
      Offset(gap, -size.height - gap),
      Offset(-size.width - gap, -size.height - gap),
      Offset(gap, gap),
      Offset(-size.width - gap, gap),
    ];
    for (final offset in offsets) {
      final candidate = Rect.fromLTWH(
        anchor.dx + offset.dx,
        anchor.dy + offset.dy,
        size.width,
        size.height,
      );
      final availableBounds = Rect.fromLTRB(
        safeInsets.left,
        safeInsets.top,
        viewport.width - safeInsets.right,
        viewport.height - safeInsets.bottom,
      );
      if (availableBounds.contains(candidate.topLeft) &&
          availableBounds.contains(candidate.bottomRight) &&
          occupied.every((rect) => !rect.overlaps(candidate))) {
        return candidate;
      }
    }
    return null;
  }
}

class _SavedMeasurementLabelPlacement {
  const _SavedMeasurementLabelPlacement({
    required this.measurement,
    required this.anchor,
    required this.rect,
    required this.isSelected,
    required this.opacity,
  });

  final SavedMeasurement measurement;
  final Offset anchor;
  final Rect rect;
  final bool isSelected;
  final double opacity;
}

class _MeasurementLabelLeaderPainter extends CustomPainter {
  const _MeasurementLabelLeaderPainter(this.placements);

  final List<_SavedMeasurementLabelPlacement> placements;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..strokeWidth = 1;
    for (final placement in placements) {
      paint.color = const Color(
        0xFF425466,
      ).withValues(alpha: 0.55 * placement.opacity);
      canvas.drawLine(placement.anchor, placement.rect.center, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _MeasurementLabelLeaderPainter oldDelegate) {
    if (oldDelegate.placements.length != placements.length) return true;
    for (var index = 0; index < placements.length; index++) {
      final previous = oldDelegate.placements[index];
      final current = placements[index];
      if (previous.measurement.id != current.measurement.id ||
          previous.anchor != current.anchor ||
          previous.rect != current.rect ||
          previous.isSelected != current.isSelected) {
        return true;
      }
    }
    return false;
  }
}

class _MeasurementLayer extends StatelessWidget {
  const _MeasurementLayer({
    required this.mode,
    required this.isEditing,
    required this.distancePoints,
    required this.areaPoints,
    required this.selectedColor,
    required this.draggedAreaVertexIndex,
    required this.onStartAreaVertexDrag,
    required this.onMoveAreaVertex,
    required this.onEndAreaVertexDrag,
    required this.onDeleteAreaVertex,
    required this.onColorChanged,
    required this.onSave,
    required this.isSavedMeasurement,
    required this.onHideSavedMeasurement,
    required this.onDeleteSavedMeasurement,
    required this.hasUnsavedChanges,
    required this.canSave,
    required this.onUndo,
    required this.onClear,
    required this.onExit,
    required this.onAnalyze,
    required this.onExport,
  });

  static const Distance _distance = Distance(roundResult: false);
  static const double _wgs84AuthalicRadius = 6371007.1809;

  final _MeasurementMode mode;
  final bool isEditing;
  final List<LatLng> distancePoints;
  final List<LatLng> areaPoints;
  final MeasurementColorOption selectedColor;
  final int? draggedAreaVertexIndex;
  final void Function(int index, Offset globalPosition) onStartAreaVertexDrag;
  final void Function(int index, Offset globalPosition) onMoveAreaVertex;
  final VoidCallback onEndAreaVertexDrag;
  final ValueChanged<int> onDeleteAreaVertex;
  final ValueChanged<MeasurementColorOption> onColorChanged;
  final VoidCallback onSave;
  final bool isSavedMeasurement;
  final VoidCallback onHideSavedMeasurement;
  final VoidCallback onDeleteSavedMeasurement;
  final bool hasUnsavedChanges;
  final bool canSave;
  final VoidCallback onUndo;
  final VoidCallback onClear;
  final VoidCallback onExit;
  final ValueChanged<ParcelAnalysis> onAnalyze;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    return mode == _MeasurementMode.distance
        ? _buildDistance(context)
        : _buildArea(context);
  }

  Widget _buildDistance(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final measurementColor = selectedColor.color;
    final measurementOnColor = selectedColor.onColor;
    final panelBottom = 16.0 + MediaQuery.paddingOf(context).bottom;
    final markers = <Marker>[
      for (var index = 0; index < distancePoints.length; index++)
        _buildEditableVertexMarker(
          context,
          distancePoints[index],
          index,
          '${index + 1}',
          colorScheme,
          measurementColor: measurementColor,
          measurementOnColor: measurementOnColor,
          isDragged: draggedAreaVertexIndex == index,
          keyPrefix: 'distance',
        ),
    ];
    final resultMarkers = <Marker>[];

    if (distancePoints.length >= 2) {
      final lastPoint = distancePoints.last;
      final previousPoint = distancePoints[distancePoints.length - 2];
      final distanceMeters = _calculatePathDistance(distancePoints);
      final labelPoint = _safeLatLng(
        (previousPoint.latitude + lastPoint.latitude) / 2,
        (previousPoint.longitude + lastPoint.longitude) / 2,
      );
      if (labelPoint != null) {
        resultMarkers.add(
          Marker(
            point: labelPoint,
            width: 112,
            height: 36,
            child: IgnorePointer(
              child: Container(
                decoration: _mapHudDecoration(colorScheme),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                child: Center(
                  child: Text(
                    _formatDistance(distanceMeters),
                    key: const ValueKey('measurement-distance'),
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }
    }

    return Stack(
      children: [
        if (distancePoints.length >= 2)
          IgnorePointer(
            child: PolylineLayer(
              polylines: [
                Polyline(
                  points: distancePoints,
                  strokeWidth: 4,
                  color: measurementColor,
                  borderStrokeWidth: 1.5,
                  borderColor: colorScheme.surface,
                ),
              ],
            ),
          ),
        if (isEditing) MarkerLayer(markers: markers),
        if (resultMarkers.isNotEmpty) MarkerLayer(markers: resultMarkers),
        if (isEditing)
          Positioned(
            left: 16,
            right: 16,
            bottom: panelBottom,
            child: Center(
              child: _MeasurementPanel(
                selectedColor: selectedColor,
                onColorChanged: onColorChanged,
                actions: [
                  _MeasurementSaveButton(
                    highlighted: hasUnsavedChanges,
                    onPressed: canSave ? onSave : null,
                  ),
                  if (distancePoints.length >= 2)
                    _MeasurementExportButton(onPressed: onExport),
                  if (isSavedMeasurement) ...[
                    IconButton(
                      tooltip: 'Ocultar',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(AppIcons.visibilityOff, size: 18),
                      onPressed: onHideSavedMeasurement,
                    ),
                    IconButton(
                      tooltip: 'Eliminar medición',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(AppIcons.delete, size: 18),
                      onPressed: onDeleteSavedMeasurement,
                    ),
                  ] else ...[
                    IconButton(
                      tooltip: 'Deshacer',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(AppIcons.undo, size: 18),
                      onPressed: onUndo,
                    ),
                    IconButton(
                      tooltip: 'Limpiar',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(AppIcons.delete, size: 18),
                      onPressed: onClear,
                    ),
                  ],
                  IconButton(
                    tooltip: 'Salir',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(AppIcons.close, size: 18),
                    onPressed: onExit,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildArea(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final measurementColor = selectedColor.color;
    final measurementOnColor = selectedColor.onColor;
    final hasPolygon = areaPoints.length >= 3;
    final linePoints = <LatLng>[
      ...areaPoints,
      if (hasPolygon) areaPoints.first,
    ];
    final markers = <Marker>[
      for (var index = 0; index < areaPoints.length; index++)
        _buildEditableVertexMarker(
          context,
          areaPoints[index],
          index,
          '${index + 1}',
          colorScheme,
          measurementColor: measurementColor,
          measurementOnColor: measurementOnColor,
          isDragged: draggedAreaVertexIndex == index,
          keyPrefix: 'area',
        ),
    ];

    final panelBottom = 16.0 + MediaQuery.paddingOf(context).bottom;
    final measurementPanel = hasPolygon
        ? Positioned(
            left: 16,
            right: 16,
            bottom: panelBottom,
            child: Center(
              child: _MeasurementPanel(
                selectedColor: selectedColor,
                onColorChanged: onColorChanged,
                showColorSelector: isEditing,
                actions: isEditing
                    ? [
                        _MeasurementSaveButton(
                          highlighted: hasUnsavedChanges,
                          onPressed: canSave ? onSave : null,
                        ),
                        if (isSavedMeasurement) ...[
                          IconButton(
                            tooltip: 'Ocultar',
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(AppIcons.visibilityOff, size: 18),
                            onPressed: onHideSavedMeasurement,
                          ),
                          IconButton(
                            tooltip: 'Eliminar medición',
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(AppIcons.delete, size: 18),
                            onPressed: onDeleteSavedMeasurement,
                          ),
                        ] else ...[
                          IconButton(
                            tooltip: 'Deshacer',
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(AppIcons.undo, size: 18),
                            onPressed: onUndo,
                          ),
                          IconButton(
                            tooltip: 'Limpiar',
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(AppIcons.delete, size: 18),
                            onPressed: onClear,
                          ),
                        ],
                        IconButton(
                          tooltip: 'Salir',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(AppIcons.close, size: 18),
                          onPressed: onExit,
                        ),
                      ]
                    : const [],
                children: [
                  Text(
                    'Área: ${_formatArea(_calculateArea(areaPoints))}',
                    key: const ValueKey('measurement-area'),
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Perímetro: ${_formatDistance(_calculatePerimeter(areaPoints))}',
                    key: const ValueKey('measurement-perimeter'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      FilledButton.tonalIcon(
                        key: const ValueKey('analyze-parcel'),
                        icon: const Icon(AppIcons.analytics, size: 18),
                        label: const Text('Analizar lote'),
                        onPressed: () {
                          onAnalyze(
                            ParcelAnalysis(
                              totalAreaSquareMeters: _calculateArea(areaPoints),
                              perimeterMeters: _calculatePerimeter(areaPoints),
                            ),
                          );
                        },
                      ),
                      _MeasurementExportButton(onPressed: onExport),
                    ],
                  ),
                ],
              ),
            ),
          )
        : const SizedBox.shrink();

    return Stack(
      children: [
        if (hasPolygon)
          IgnorePointer(
            child: PolygonLayer(
              polygons: [
                Polygon(
                  points: areaPoints,
                  color: measurementColor.withValues(alpha: 0.25),
                  borderColor: measurementColor,
                  borderStrokeWidth: 3,
                ),
              ],
            ),
          ),
        if (linePoints.length >= 2)
          IgnorePointer(
            child: PolylineLayer(
              polylines: [
                Polyline(
                  points: linePoints,
                  strokeWidth: 3,
                  color: measurementColor,
                ),
              ],
            ),
          ),
        if (isEditing) MarkerLayer(markers: markers),
        measurementPanel,
      ],
    );
  }

  Marker _buildEditableVertexMarker(
    BuildContext context,
    LatLng point,
    int index,
    String label,
    ColorScheme colorScheme, {
    required Color measurementColor,
    required Color measurementOnColor,
    required bool isDragged,
    required String keyPrefix,
  }) {
    final isFirst = index == 0;
    return Marker(
      key: ValueKey('$keyPrefix-vertex-$index'),
      point: point,
      width: isDragged ? 44 : (isFirst ? 38 : 30),
      height: isDragged ? 44 : (isFirst ? 38 : 30),
      child: _AreaVertexHandle(
        key: ValueKey('$keyPrefix-vertex-gesture-$index'),
        label: label,
        isFirst: isFirst,
        isDragged: isDragged,
        colorScheme: colorScheme,
        measurementColor: measurementColor,
        measurementOnColor: measurementOnColor,
        desktopInteraction: isSuelosArDesktopPlatform(context),
        onDragStart: (position) => onStartAreaVertexDrag(index, position),
        onDragUpdate: (position) => onMoveAreaVertex(index, position),
        onDragEnd: onEndAreaVertexDrag,
        onTap: (position) => _showVertexMenu(
          context,
          index,
          position,
          pointCount: keyPrefix == 'area'
              ? areaPoints.length
              : distancePoints.length,
          minimumPointCount: keyPrefix == 'area' ? 3 : 1,
        ),
      ),
    );
  }

  Future<void> _showVertexMenu(
    BuildContext context,
    int index,
    Offset position, {
    required int pointCount,
    required int minimumPointCount,
  }) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) {
      return;
    }
    final desktop = isSuelosArDesktopPlatform(context);
    final colorScheme = Theme.of(context).colorScheme;
    var deleted = false;
    final selection = await showMenu<_VertexMenuOption>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      elevation: desktop ? 8 : null,
      color: desktop ? colorScheme.surfaceContainerLow : null,
      surfaceTintColor: desktop ? Colors.transparent : null,
      shadowColor: desktop ? colorScheme.shadow.withValues(alpha: 0.2) : null,
      shape: desktop
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                color: colorScheme.outlineVariant.withValues(alpha: 0.65),
              ),
            )
          : null,
      menuPadding: desktop ? const EdgeInsets.symmetric(vertical: 8) : null,
      items: desktop
          ? [
              PopupMenuItem(
                key: const ValueKey('delete-area-vertex'),
                value: _VertexMenuOption.delete,
                enabled: pointCount > minimumPointCount,
                height: 48,
                onTap: pointCount > minimumPointCount
                    ? () {
                        deleted = true;
                        onDeleteAreaVertex(index);
                      }
                    : null,
                child: Row(
                  children: [
                    Icon(
                      AppIcons.delete,
                      size: 19,
                      color: pointCount > minimumPointCount
                          ? colorScheme.error
                          : colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 12),
                    const Flexible(child: Text('Eliminar vértice')),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: _VertexMenuOption.cancel,
                height: 48,
                child: Row(
                  children: [
                    Icon(AppIcons.close, size: 19),
                    SizedBox(width: 12),
                    Flexible(child: Text('Cancelar')),
                  ],
                ),
              ),
            ]
          : [
              PopupMenuItem(
                key: const ValueKey('delete-area-vertex'),
                value: _VertexMenuOption.delete,
                enabled: pointCount > minimumPointCount,
                onTap: pointCount > minimumPointCount
                    ? () {
                        deleted = true;
                        onDeleteAreaVertex(index);
                      }
                    : null,
                child: const Text('Eliminar vértice'),
              ),
              const PopupMenuItem(
                value: _VertexMenuOption.cancel,
                child: Text('Cancelar'),
              ),
            ],
    );
    if (!deleted && selection == _VertexMenuOption.delete) {
      onDeleteAreaVertex(index);
    }
  }

  static String _formatDistance(double meters) {
    if (meters < 1000) {
      return '${meters.round()} m';
    }
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  static String _formatArea(double squareMeters) {
    if (squareMeters < 10000) {
      return '${squareMeters.round()} m²';
    }
    return '${(squareMeters / 10000).toStringAsFixed(1)} ha';
  }

  static double _calculatePerimeter(List<LatLng> points) {
    var perimeter = 0.0;
    for (var index = 0; index < points.length; index++) {
      perimeter += _distance(
        points[index],
        points[(index + 1) % points.length],
      );
    }
    return perimeter;
  }

  static double _calculatePathDistance(List<LatLng> points) {
    var distance = 0.0;
    for (var index = 1; index < points.length; index++) {
      distance += _distance(points[index - 1], points[index]);
    }
    return distance;
  }

  static double _calculateArea(List<LatLng> points) {
    var sum = 0.0;
    for (var index = 0; index < points.length; index++) {
      final current = points[index];
      final next = points[(index + 1) % points.length];
      sum +=
          _toRadians(next.longitude - current.longitude) *
          (2 +
              math.sin(_toRadians(current.latitude)) +
              math.sin(_toRadians(next.latitude)));
    }
    return (sum * _wgs84AuthalicRadius * _wgs84AuthalicRadius / 2).abs();
  }

  static double _toRadians(double degrees) => degrees * math.pi / 180;
}

class _MeasurementPanel extends StatelessWidget {
  const _MeasurementPanel({
    required this.selectedColor,
    required this.onColorChanged,
    required this.actions,
    this.showColorSelector = true,
    this.children = const <Widget>[],
  });

  final MeasurementColorOption selectedColor;
  final ValueChanged<MeasurementColorOption> onColorChanged;
  final List<Widget> children;
  final List<Widget> actions;
  final bool showColorSelector;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      decoration: _mapHudDecoration(colorScheme),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ...children,
            if (children.isNotEmpty) const SizedBox(height: 10),
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 2,
              runSpacing: 6,
              children: [
                if (showColorSelector)
                  MeasurementColorSelector(
                    selectedColor: selectedColor,
                    onChanged: onColorChanged,
                  ),
                if (showColorSelector) const SizedBox(width: 8),
                ...actions,
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MeasurementSaveButton extends StatelessWidget {
  const _MeasurementSaveButton({
    required this.highlighted,
    required this.onPressed,
  });

  final bool highlighted;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent =
        theme.extension<SuelosArMapControlColors>()?.activeAccent ??
        theme.colorScheme.primary;
    return FilledButton.tonalIcon(
      key: const ValueKey('save-measurement'),
      style: highlighted
          ? FilledButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: Colors.white,
            )
          : null,
      onPressed: onPressed,
      icon: const Icon(AppIcons.save, size: 17),
      label: const Text('Guardar'),
    );
  }
}

class _MeasurementExportButton extends StatelessWidget {
  const _MeasurementExportButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      key: const ValueKey('export-measurement'),
      icon: const Icon(AppIcons.pdf, size: 18),
      label: const Text('Exportar'),
      onPressed: onPressed,
    );
  }
}

class _AreaVertexHandle extends StatefulWidget {
  const _AreaVertexHandle({
    super.key,
    required this.label,
    required this.isFirst,
    required this.isDragged,
    required this.colorScheme,
    required this.measurementColor,
    required this.measurementOnColor,
    required this.desktopInteraction,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onTap,
  });

  final String label;
  final bool isFirst;
  final bool isDragged;
  final ColorScheme colorScheme;
  final Color measurementColor;
  final Color measurementOnColor;
  final bool desktopInteraction;
  final ValueChanged<Offset> onDragStart;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;
  final ValueChanged<Offset> onTap;

  @override
  State<_AreaVertexHandle> createState() => _AreaVertexHandleState();
}

class _AreaVertexHandleState extends State<_AreaVertexHandle> {
  bool _moved = false;
  bool _primaryDragActive = false;
  bool _secondaryClickActive = false;

  void _resetPointerState() {
    _primaryDragActive = false;
    _secondaryClickActive = false;
    _moved = false;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = widget.colorScheme;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        _moved = false;
        if (widget.desktopInteraction &&
            event.kind == PointerDeviceKind.mouse) {
          if (event.buttons == kSecondaryMouseButton) {
            _secondaryClickActive = true;
            _primaryDragActive = false;
            return;
          }
          if (event.buttons != kPrimaryMouseButton) {
            _resetPointerState();
            return;
          }
        }
        _primaryDragActive = true;
        _secondaryClickActive = false;
        widget.onDragStart(event.position);
      },
      onPointerMove: (event) {
        if (event.delta.distance > 0) {
          _moved = true;
        }
        if (_primaryDragActive) {
          widget.onDragUpdate(event.position);
        }
      },
      onPointerUp: (event) {
        final tapPosition = event.position;
        final showContextMenu =
            !_moved && (_secondaryClickActive || !widget.desktopInteraction);
        if (showContextMenu) {
          if (_secondaryClickActive && widget.desktopInteraction) {
            widget.onTap(tapPosition);
          } else {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              widget.onTap(tapPosition);
            });
          }
        }
        if (_primaryDragActive) {
          widget.onDragEnd();
        }
        _resetPointerState();
      },
      onPointerCancel: (_) {
        if (_primaryDragActive) {
          widget.onDragEnd();
        }
        _resetPointerState();
      },
      child: MouseRegion(
        cursor: widget.isDragged
            ? SystemMouseCursors.move
            : SystemMouseCursors.click,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: widget.isDragged
                ? colorScheme.error
                : widget.measurementColor,
            shape: BoxShape.circle,
            border: Border.all(
              color: widget.isDragged
                  ? colorScheme.onError
                  : colorScheme.surface,
              width: widget.isDragged ? 4 : 3,
            ),
          ),
          child: Center(
            child: Text(
              widget.label,
              style: TextStyle(
                color: widget.isDragged
                    ? colorScheme.onError
                    : widget.measurementOnColor,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SoilSeriesSearchEntry {
  _SoilSeriesSearchEntry({
    required this.name,
    required this.normalizedName,
    required this.subtitle,
    required this.type,
    required this.feature,
    required this.center,
    List<_SoilSeriesUnitMatch>? unitMatches,
  }) : unitMatches = unitMatches ?? <_SoilSeriesUnitMatch>[];

  final String name;
  final String normalizedName;
  final String subtitle;
  final _MapSearchEntryType type;
  final GisFeature feature;
  final LatLng center;
  final List<_SoilSeriesUnitMatch> unitMatches;
}

class _SoilSeriesUnitMatch {
  const _SoilSeriesUnitMatch({
    required this.unitSymbol,
    required this.unitName,
    required this.percentage,
    required this.searchEntry,
  });

  final String unitSymbol;
  final String unitName;
  final String percentage;
  final _SoilSeriesSearchEntry searchEntry;

  double get numericPercentage =>
      double.tryParse(percentage.replaceAll('%', '').trim()) ?? -1;

  String get displayPercentage {
    if (percentage.isEmpty) {
      return 'Sin porcentaje';
    }
    return percentage.endsWith('%') ? percentage : '$percentage%';
  }
}

enum _MapSearchEntryType {
  locality,
  unitSymbol,
  soilSeries;

  IconData get icon => switch (this) {
    locality => AppIcons.locality,
    unitSymbol => AppIcons.map,
    soilSeries => AppIcons.field,
  };

  String get sectionTitle => switch (this) {
    locality => 'Localidades',
    unitSymbol => 'Unidades cartográficas',
    soilSeries => 'Series de suelo',
  };
}

class _SearchSectionHeader extends StatelessWidget {
  const _SearchSectionHeader({required this.type});

  final _MapSearchEntryType type;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 8),
      child: Row(
        children: [
          Icon(
            type.icon,
            size: 16,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 9),
          Text(
            type.sectionTitle,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

int _searchMatchRank(String value, String query) {
  if (query.isEmpty || value == query) {
    return 0;
  }
  if (value.startsWith(query)) {
    return 1;
  }
  return 2;
}

bool _isSelfIntersecting(List<LatLng> points) {
  if (points.length < 4) {
    return false;
  }
  for (var first = 0; first < points.length; first++) {
    final firstNext = (first + 1) % points.length;
    for (var second = first + 1; second < points.length; second++) {
      final secondNext = (second + 1) % points.length;
      if (first == second || firstNext == second || secondNext == first) {
        continue;
      }
      if (_segmentsIntersect(
        points[first],
        points[firstNext],
        points[second],
        points[secondNext],
      )) {
        return true;
      }
    }
  }
  return false;
}

bool _segmentsIntersect(LatLng a, LatLng b, LatLng c, LatLng d) {
  final o1 = _orientation(a, b, c);
  final o2 = _orientation(a, b, d);
  final o3 = _orientation(c, d, a);
  final o4 = _orientation(c, d, b);
  return o1 * o2 < 0 && o3 * o4 < 0;
}

double _orientation(LatLng a, LatLng b, LatLng c) {
  return (b.longitude - a.longitude) * (c.latitude - a.latitude) -
      (b.latitude - a.latitude) * (c.longitude - a.longitude);
}

double _distanceToSegment(Offset point, Offset start, Offset end) {
  final segment = end - start;
  final lengthSquared = segment.dx * segment.dx + segment.dy * segment.dy;
  if (lengthSquared == 0) {
    return (point - start).distance;
  }
  final projection =
      ((point - start).dx * segment.dx + (point - start).dy * segment.dy) /
      lengthSquared;
  final closest = start + segment * projection.clamp(0.0, 1.0);
  return (point - closest).distance;
}

String _normalizeSearchText(String value) {
  const replacements = <String, String>{
    'á': 'a',
    'à': 'a',
    'ä': 'a',
    'â': 'a',
    'ã': 'a',
    'é': 'e',
    'è': 'e',
    'ë': 'e',
    'ê': 'e',
    'í': 'i',
    'ì': 'i',
    'ï': 'i',
    'î': 'i',
    'ó': 'o',
    'ò': 'o',
    'ö': 'o',
    'ô': 'o',
    'õ': 'o',
    'ú': 'u',
    'ù': 'u',
    'ü': 'u',
    'û': 'u',
    'ñ': 'n',
    'ç': 'c',
  };
  final normalized = StringBuffer();
  var previousWasSpace = false;

  for (final rune in value.toLowerCase().runes) {
    final character = String.fromCharCode(rune);
    final replacement = replacements[character] ?? character;
    final isSpace = replacement.trim().isEmpty;
    if (isSpace) {
      if (!previousWasSpace) {
        normalized.write(' ');
      }
      previousWasSpace = true;
    } else {
      normalized.write(replacement);
      previousWasSpace = false;
    }
  }

  return normalized.toString().trim();
}

LatLng? _lerpLatLng(LatLng start, LatLng end, double value) {
  if (!_isFiniteLatLng(start) ||
      !_isFiniteLatLng(end) ||
      !_isFiniteNumber(value)) {
    return null;
  }
  return _safeLatLng(
    _lerpDouble(start.latitude, end.latitude, value),
    _lerpDouble(start.longitude, end.longitude, value),
  );
}

double _lerpDouble(double start, double end, double value) {
  return start + (end - start) * value;
}

LatLng? _safeLatLng(double latitude, double longitude) {
  if (!_isFiniteCoordinateValues(latitude, longitude)) {
    return null;
  }
  return LatLng(latitude, longitude);
}

bool _isFiniteLatLng(LatLng point) {
  return _isFiniteCoordinateValues(point.latitude, point.longitude);
}

bool _isFiniteCoordinateValues(double latitude, double longitude) {
  return _isFiniteNumber(latitude) && _isFiniteNumber(longitude);
}

bool _isFiniteCamera(MapCamera camera) {
  return _isFiniteLatLng(camera.center) &&
      _isFiniteNumber(camera.zoom) &&
      _isFiniteNumber(camera.rotation);
}

bool _isFiniteOffset(Offset offset) {
  return _isFiniteNumber(offset.dx) && _isFiniteNumber(offset.dy);
}

bool _isFiniteNumber(double value) {
  return value.isFinite && !value.isNaN;
}

class _SelectionPreviewOverlay extends StatelessWidget {
  const _SelectionPreviewOverlay({
    required this.featureListenable,
    required this.bottomOffset,
    required this.rightInset,
    required this.onDismiss,
  });

  final ValueListenable<GisFeature?> featureListenable;
  final double bottomOffset;
  final double rightInset;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 16, rightInset, bottomOffset),
        child: ValueListenableBuilder<GisFeature?>(
          valueListenable: featureListenable,
          builder: (context, feature, child) {
            return AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              reverseDuration: const Duration(milliseconds: 160),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.12),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                );
              },
              child: feature == null
                  ? const SizedBox.shrink(
                      key: ValueKey('selection-preview-empty'),
                    )
                  : _SelectionPreviewCard(
                      key: ValueKey('selection-preview-${feature.id}'),
                      feature: feature,
                      onDismiss: onDismiss,
                    ),
            );
          },
        ),
      ),
    );
  }
}

class _SavedMeasurementActionBar extends StatelessWidget {
  const _SavedMeasurementActionBar({
    required this.onAnalyze,
    required this.onExport,
    required this.onExportGeoJson,
    required this.onExportCsv,
    required this.onDelete,
    required this.onEdit,
  });

  final VoidCallback? onAnalyze;
  final VoidCallback onExport;
  final VoidCallback onExportGeoJson;
  final VoidCallback onExportCsv;
  final VoidCallback onDelete;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final compactLayout = MediaQuery.sizeOf(context).width < 600;
    final colorScheme = Theme.of(context).colorScheme;
    return Positioned(
      left: 16,
      right: compactLayout ? 76 : 16,
      bottom: 72,
      child: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Material(
            elevation: 5,
            shadowColor: colorScheme.shadow.withValues(alpha: 0.18),
            color: colorScheme.surfaceContainerLow.withValues(alpha: 0.98),
            surfaceTintColor: Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (onAnalyze != null)
                    TextButton.icon(
                      key: const ValueKey('analyze-selected-measurement'),
                      onPressed: onAnalyze,
                      icon: const Icon(AppIcons.analytics, size: 18),
                      label: const Text('Analizar lote'),
                    ),
                  if (onAnalyze != null) const SizedBox(width: 4),
                  SavedMeasurementOverflowMenu(
                    onEdit: onEdit,
                    onExportPdf: onExport,
                    onExportGeoJson: onExportGeoJson,
                    onExportCsv: onExportCsv,
                    onDelete: onDelete,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectionPreviewCard extends StatelessWidget {
  const _SelectionPreviewCard({
    required this.feature,
    required this.onDismiss,
    super.key,
  });

  final GisFeature feature;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final series = GisSoilSeries.fromProperties(feature.properties);
    final seriesName = series.isEmpty ? 'Serie sin datos' : series.first.name;
    final capability = _propertyValue(feature, 'CAP_USO') ?? 'Sin datos';
    final area = _availableArea(feature);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Material(
        elevation: 5,
        shadowColor: colorScheme.shadow.withValues(alpha: 0.18),
        color: colorScheme.surfaceContainerLow.withValues(alpha: 0.97),
        surfaceTintColor: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 30),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      seriesName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text('Capacidad: $capability', style: textTheme.bodyMedium),
                    if (area != null) ...[
                      const SizedBox(height: 3),
                      Text('Área: $area', style: textTheme.bodyMedium),
                    ],
                    const SizedBox(height: 9),
                    Text(
                      'Tocá nuevamente para ver detalles ↑',
                      style: textTheme.labelMedium?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                top: -8,
                right: -10,
                child: IconButton(
                  key: const ValueKey('dismiss-soil-preview'),
                  tooltip: 'Cerrar',
                  visualDensity: VisualDensity.compact,
                  style: ButtonStyle(
                    shape: const WidgetStatePropertyAll(CircleBorder()),
                    side: const WidgetStatePropertyAll(BorderSide.none),
                    elevation: const WidgetStatePropertyAll(0),
                    shadowColor: const WidgetStatePropertyAll(
                      Colors.transparent,
                    ),
                    overlayColor: WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.pressed)) {
                        return colorScheme.onSurface.withValues(alpha: 0.10);
                      }
                      if (states.contains(WidgetState.hovered)) {
                        return colorScheme.onSurface.withValues(alpha: 0.06);
                      }
                      return Colors.transparent;
                    }),
                  ),
                  icon: const Icon(AppIcons.close, size: 18),
                  onPressed: onDismiss,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String? _availableArea(GisFeature feature) {
    for (final key in const ['AREA_HA', 'SUP_HA', 'HECTAREAS']) {
      final value = _propertyValue(feature, key);
      if (value != null) {
        return value.toLowerCase().contains('ha') ? value : '$value ha';
      }
    }
    return null;
  }

  static String? _propertyValue(GisFeature feature, String key) {
    final value = feature.properties[key]?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  }
}

class _MapViewportState {
  const _MapViewportState({
    required this.center,
    required this.zoom,
    required this.rotation,
  });

  final LatLng center;
  final double zoom;
  final double rotation;

  @override
  bool operator ==(Object other) {
    return other is _MapViewportState &&
        other.center.latitude == center.latitude &&
        other.center.longitude == center.longitude &&
        other.zoom == zoom &&
        other.rotation == rotation;
  }

  @override
  int get hashCode =>
      Object.hash(center.latitude, center.longitude, zoom, rotation);
}

class _MapCompassControl extends StatefulWidget {
  const _MapCompassControl({
    required this.viewStateListenable,
    required this.onResetNorth,
    this.desktopStyle = false,
    this.mapController,
  });

  final ValueListenable<_MapViewportState> viewStateListenable;
  final VoidCallback onResetNorth;

  /// True only on the desktop shell — swaps the shared mobile chrome
  /// (brown circle) for the white-surface look already used by the rest
  /// of the desktop floating controls. See
  /// [_MapChromeSurface.useDesktopSurfaceStyle]. Also gates the two
  /// desktop-only additions below (always-visible, drag-to-rotate) —
  /// mobile keeps its exact previous behavior either way.
  final bool desktopStyle;

  /// Only read when [desktopStyle] is true, to drive drag-to-rotate.
  /// Deliberately the same [MapController] the rest of this screen already
  /// drives (`_mapController`/`_animateMapToNorth`) — every drag step
  /// reads [MapController.camera]'s live rotation and writes back through
  /// [MapController.rotate], the same flutter_map API the existing reset-
  /// to-north animation already uses. There is no locally tracked
  /// rotation value here that could drift from the real camera: the
  /// glyph's own angle still comes exclusively from
  /// [viewStateListenable], which [MapController.rotate] itself feeds
  /// (via this screen's existing `onPositionChanged`/`onMapEvent` →
  /// `_updateMapViewportState` pipeline) — a drag step and any other
  /// rotation source (a reset, a two-finger gesture) update the exact
  /// same state the same way.
  final MapController? mapController;

  @override
  State<_MapCompassControl> createState() => _MapCompassControlState();
}

class _MapCompassControlState extends State<_MapCompassControl> {
  /// Degrees the map rotates per logical pixel of horizontal drag — a
  /// deliberately chosen feel (a full turn takes a comfortable ~600px),
  /// not an arbitrary pixel-to-degree sum: every update still reads the
  /// map's own current rotation before adding this increment (see
  /// [_handleDragUpdate]), so it's always anchored to the real camera
  /// rather than an independently accumulated value.
  static const double _dragDegreesPerPixel = 0.6;

  bool _isDragging = false;

  /// Desktop-only, purely for the rotation-hint arcs' opacity below — a
  /// separate `MouseRegion` from [_MapChromeSurface]'s own internal hover
  /// tracking (which still drives its existing elevation/scale feedback
  /// unchanged). Left at [MouseCursor.defer] (the default), so it never
  /// competes with [_MapChromeSurface]'s own grab/grabbing cursor.
  bool _isHovered = false;

  void _handleDragStart(DragStartDetails details) {
    setState(() => _isDragging = true);
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    final mapController = widget.mapController;
    if (mapController == null) return;
    final currentRotation = mapController.camera.rotation;
    mapController.rotate(
      currentRotation + details.delta.dx * _dragDegreesPerPixel,
    );
  }

  void _handleDragEnd(DragEndDetails details) {
    setState(() => _isDragging = false);
  }

  void _handleDragCancel() {
    setState(() => _isDragging = false);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_MapViewportState>(
      valueListenable: widget.viewStateListenable,
      builder: (context, viewState, child) {
        final normalizedRotation = ((viewState.rotation + 180) % 360) - 180;
        // Desktop: always on, per its own always-visible requirement.
        // Mobile keeps the original "only while actually rotated" rule,
        // untouched.
        final visible = widget.desktopStyle || normalizedRotation.abs() > 0.5;
        if (!visible) {
          return const SizedBox.shrink(key: ValueKey('map-compass-hidden'));
        }
        final button = _MapChromeIconButton(
          key: const ValueKey('map-compass'),
          includeOuterSpacing: false,
          useDesktopSurfaceStyle: widget.desktopStyle,
          cursorOverride: widget.desktopStyle
              ? (_isDragging
                    ? SystemMouseCursors.grabbing
                    : SystemMouseCursors.grab)
              : null,
          // Desktop states the drag affordance explicitly, since the
          // circular chrome alone reads as a plain button; mobile keeps
          // its original, purely click-to-reset wording.
          tooltip: widget.desktopStyle
              ? 'Arrastrá para rotar · clic para volver al norte'
              : 'Restablecer norte',
          // Unchanged click path — a plain click/tap still resets to
          // north exactly as before, on every platform. The horizontal
          // drag recognizer wrapped around it below only wins the gesture
          // arena once the pointer actually moves horizontally past the
          // platform's touch slop, so a real click never also triggers a
          // drag, and a real drag never also triggers this reset.
          onPressed: widget.onResetNorth,
          icon: _CompassGlyph(rotationTurns: -normalizedRotation / 360),
        );
        Widget compass = widget.desktopStyle
            ? GestureDetector(
                onHorizontalDragStart: _handleDragStart,
                onHorizontalDragUpdate: _handleDragUpdate,
                onHorizontalDragEnd: _handleDragEnd,
                onHorizontalDragCancel: _handleDragCancel,
                child: button,
              )
            : button;
        if (widget.desktopStyle) {
          // Purely decorative discoverability hint: two short arcs
          // tracing a "rotate" motif just outside the 48px circle.
          // `Positioned` (not a plain sized child) so it overflows the
          // Stack's own bounds without changing what the Stack reports as
          // its size to the layout above — the Stack still sizes itself
          // to `compass` (the only non-positioned child, still exactly
          // 48px), so this never shifts the compass's own position or the
          // layers button below it. `IgnorePointer` keeps it out of the
          // button's hit area, and it stays faint until hover/drag.
          final hintOpacity = _isDragging ? 0.85 : (_isHovered ? 0.55 : 0.0);
          compass = MouseRegion(
            onEnter: (_) => setState(() => _isHovered = true),
            onExit: (_) => setState(() => _isHovered = false),
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                compass,
                Positioned(
                  left: -5,
                  top: -5,
                  right: -5,
                  bottom: -5,
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: hintOpacity,
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOut,
                      child: CustomPaint(
                        painter: _CompassRotationHintPainter(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        }
        return Padding(
          padding: widget.desktopStyle
              ? const EdgeInsets.only(top: 4, right: 8, bottom: 14)
              : const EdgeInsets.only(bottom: 10),
          child: compass,
        );
      },
    );
  }
}

/// Two short opposing arcs traced just outside the compass's 48px circle —
/// the classic "rotate" motif (like a refresh glyph), kept as a partial
/// arc rather than a full ring so it reads as a subtle hint, not a second
/// decoration competing with the compass glyph itself. Only ever painted
/// at low opacity, driven by hover/drag state in
/// [_MapCompassControlState].
class _CompassRotationHintPainter extends CustomPainter {
  const _CompassRotationHintPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 1.5;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawArc(rect, -2.55, 1.15, false, paint);
    canvas.drawArc(rect, 0.6, 1.15, false, paint);
  }

  @override
  bool shouldRepaint(covariant _CompassRotationHintPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _CompassGlyph extends StatelessWidget {
  const _CompassGlyph({required this.rotationTurns});

  final double rotationTurns;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final color = iconTheme.color ?? Theme.of(context).colorScheme.onPrimary;

    return AnimatedRotation(
      turns: rotationTurns,
      duration: const Duration(milliseconds: 80),
      child: CustomPaint(
        size: Size.square((iconTheme.size ?? 21) + 3),
        painter: _CompassGlyphPainter(color),
      ),
    );
  }
}

class _CompassGlyphPainter extends CustomPainter {
  const _CompassGlyphPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2;
    final ringPaint = Paint()
      ..color = color.withValues(alpha: 0.74)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.45
      ..isAntiAlias = true;
    final axisPaint = Paint()
      ..color = color.withValues(alpha: 0.5)
      ..strokeWidth = 1.1
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    final needlePaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final shadowNeedlePaint = Paint()
      ..color = color.withValues(alpha: 0.38)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    canvas.drawCircle(center, radius - 2.2, ringPaint);
    canvas.drawLine(
      Offset(center.dx, center.dy - radius + 4.4),
      Offset(center.dx, center.dy - radius + 7.1),
      axisPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy + radius - 7.1),
      Offset(center.dx, center.dy + radius - 4.4),
      axisPaint,
    );
    canvas.drawLine(
      Offset(center.dx - radius + 4.4, center.dy),
      Offset(center.dx - radius + 7.1, center.dy),
      axisPaint,
    );
    canvas.drawLine(
      Offset(center.dx + radius - 7.1, center.dy),
      Offset(center.dx + radius - 4.4, center.dy),
      axisPaint,
    );

    final northNeedle = ui.Path()
      ..moveTo(center.dx, center.dy - radius + 4.6)
      ..lineTo(center.dx - 4.1, center.dy + 2.0)
      ..lineTo(center.dx, center.dy + 0.2)
      ..lineTo(center.dx + 4.1, center.dy + 2.0)
      ..close();
    final southNeedle = ui.Path()
      ..moveTo(center.dx, center.dy + radius - 4.6)
      ..lineTo(center.dx - 3.4, center.dy + 2.4)
      ..lineTo(center.dx, center.dy + 4.0)
      ..lineTo(center.dx + 3.4, center.dy + 2.4)
      ..close();

    canvas.drawPath(southNeedle, shadowNeedlePaint);
    canvas.drawPath(northNeedle, needlePaint);
    canvas.drawCircle(center, 1.5, needlePaint);
  }

  @override
  bool shouldRepaint(_CompassGlyphPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _MapViewportOverlay extends StatelessWidget {
  const _MapViewportOverlay({
    required this.viewStateListenable,
    required this.showScale,
  });

  final ValueListenable<_MapViewportState> viewStateListenable;
  final bool showScale;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox.expand(
        child: ValueListenableBuilder<_MapViewportState>(
          valueListenable: viewStateListenable,
          builder: (context, viewState, child) {
            return Stack(
              children: [
                if (showScale)
                  Positioned(
                    left: 16,
                    bottom: 16,
                    child: RepaintBoundary(
                      child: _MapScaleIndicator(viewState: viewState),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _MapScaleIndicator extends StatelessWidget {
  const _MapScaleIndicator({required this.viewState});

  static const double _preferredBarWidth = 112;
  static const double _minimumAgriculturalScaleMeters = 10;
  static const double _earthCircumferenceMeters = 40075016.686;
  static const double _webMercatorTileSize = 256;
  static const double _maxWebMercatorLatitude = 85.05112878;

  final _MapViewportState viewState;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: colorScheme.onSurface,
      fontFeatures: const [FontFeature.tabularFigures()],
      fontWeight: FontWeight.w600,
    );
    final metersPerPixel = _metersPerPixel(viewState);
    final scale = _selectAgriculturalScale(metersPerPixel);

    return DecoratedBox(
      decoration: _mapHudDecoration(colorScheme),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_formatScaleLabel(scale.distanceMeters), style: textStyle),
            const SizedBox(height: 6),
            SizedBox(
              width: scale.widthPixels,
              height: 8,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _ScaleTick(color: colorScheme.primary),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 1),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: colorScheme.primary,
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: const SizedBox(height: 2),
                      ),
                    ),
                  ),
                  _ScaleTick(color: colorScheme.primary),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static double _metersPerPixel(_MapViewportState viewState) {
    final latitude = viewState.center.latitude
        .clamp(-_maxWebMercatorLatitude, _maxWebMercatorLatitude)
        .toDouble();
    final latitudeRadians = latitude * math.pi / 180;
    final zoomScale = math.pow(2, viewState.zoom).toDouble();

    return _earthCircumferenceMeters *
        math.cos(latitudeRadians).abs() /
        (_webMercatorTileSize * zoomScale);
  }

  static ({double distanceMeters, double widthPixels}) _selectAgriculturalScale(
    double metersPerPixel,
  ) {
    if (!metersPerPixel.isFinite || metersPerPixel <= 0) {
      return (
        distanceMeters: _minimumAgriculturalScaleMeters,
        widthPixels: _preferredBarWidth,
      );
    }

    final targetDistanceMeters = metersPerPixel * _preferredBarWidth;
    final lowerDistance = _agriculturalScaleAtOrBelow(targetDistanceMeters);
    final upperDistance = _nextAgriculturalScale(targetDistanceMeters);
    final lowerWidth = lowerDistance / metersPerPixel;
    final upperWidth = upperDistance / metersPerPixel;
    final distanceMeters =
        (upperWidth - _preferredBarWidth).abs() <=
            (lowerWidth - _preferredBarWidth).abs()
        ? upperDistance
        : lowerDistance;
    final widthPixels = distanceMeters / metersPerPixel;

    return (distanceMeters: distanceMeters, widthPixels: widthPixels);
  }

  static double _agriculturalScaleAtOrBelow(double distanceMeters) {
    if (distanceMeters <= _minimumAgriculturalScaleMeters) {
      return _minimumAgriculturalScaleMeters;
    }

    final exponent = math
        .pow(10, (math.log(distanceMeters) / math.ln10).floor())
        .toDouble();
    final normalized = distanceMeters / exponent;
    final multiplier = normalized >= 5
        ? 5
        : normalized >= 2
        ? 2
        : 1;

    return math.max(_minimumAgriculturalScaleMeters, multiplier * exponent);
  }

  static double _nextAgriculturalScale(double minimumDistanceMeters) {
    if (minimumDistanceMeters <= _minimumAgriculturalScaleMeters) {
      return _minimumAgriculturalScaleMeters;
    }

    final exponent = math
        .pow(10, (math.log(minimumDistanceMeters) / math.ln10).floor())
        .toDouble();
    final normalized = minimumDistanceMeters / exponent;
    final multiplier = normalized <= 1
        ? 1
        : normalized <= 2
        ? 2
        : normalized <= 5
        ? 5
        : 10;

    return multiplier * exponent;
  }

  static String _formatScaleLabel(double distanceMeters) {
    final roundedMeters = distanceMeters.round();
    if (roundedMeters >= 1000) {
      final kilometers = roundedMeters / 1000;
      if (kilometers == kilometers.roundToDouble()) {
        return '${kilometers.round()} km';
      }

      return '${kilometers.toStringAsFixed(1)} km';
    }

    return '$roundedMeters m';
  }
}

class _ZoomLevelIndicator extends StatelessWidget {
  const _ZoomLevelIndicator({required this.zoom});

  final double zoom;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: colorScheme.onSurface,
      fontFeatures: const [FontFeature.tabularFigures()],
      fontWeight: FontWeight.w700,
    );

    return DecoratedBox(
      decoration: _mapHudDecoration(colorScheme),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text('Zoom ${zoom.round()}', style: textStyle),
      ),
    );
  }
}

class _ScaleTick extends StatelessWidget {
  const _ScaleTick({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(1),
      ),
      child: const SizedBox(width: 2, height: 8),
    );
  }
}

BoxDecoration _mapHudDecoration(ColorScheme colorScheme) {
  return BoxDecoration(
    color: colorScheme.surfaceContainerLowest.withValues(alpha: 0.94),
    border: Border.all(
      color: colorScheme.outlineVariant.withValues(alpha: 0.65),
    ),
    borderRadius: BorderRadius.circular(14),
    boxShadow: [
      BoxShadow(
        color: colorScheme.shadow.withValues(alpha: 0.16),
        blurRadius: 12,
        offset: const Offset(0, 4),
      ),
    ],
  );
}

class _GisVisibleTileLayers extends StatelessWidget {
  const _GisVisibleTileLayers({
    required this.snapshotListenable,
    required this.renderMetrics,
  });

  final ValueListenable<_VisibleTileSnapshot> snapshotListenable;
  final GisRenderMetrics renderMetrics;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_VisibleTileSnapshot>(
      valueListenable: snapshotListenable,
      builder: (context, snapshot, child) {
        renderMetrics.tileCollectionBuildCount++;
        return Stack(fit: StackFit.expand, children: snapshot.widgets);
      },
    );
  }
}

class _RenderedGisTile {
  _RenderedGisTile({
    required this.coordinates,
    required this.polygons,
    required this.renderMetrics,
  }) : featureIds = Set<String>.unmodifiable(
         polygons.map((polygon) => polygon.feature.id),
       );

  final GisTileCoordinates coordinates;
  final List<_RenderedGisPolygon> polygons;
  final GisRenderMetrics renderMetrics;
  final Set<String> featureIds;
  final ValueNotifier<String?> selectedFeatureId = ValueNotifier(null);

  late final Widget layerWidget = _GisTilePolygonLayer(
    key: ValueKey<GisTileCoordinates>(coordinates),
    tile: this,
    renderMetrics: renderMetrics,
  );

  GisFeature? hitTest(LatLng point) {
    final stopwatch = renderMetrics.enabled ? (Stopwatch()..start()) : null;
    GisFeature? result;
    for (final polygon in polygons.reversed) {
      if (polygon.contains(point)) {
        result = polygon.feature;
        break;
      }
    }
    if (stopwatch != null) {
      stopwatch.stop();
      renderMetrics.hitTestCount++;
      renderMetrics.totalHitTestDuration += stopwatch.elapsed;
    }
    return result;
  }

  void updateSelection(String? featureId) {
    final nextValue = featureIds.contains(featureId) ? featureId : null;
    if (selectedFeatureId.value != nextValue) {
      selectedFeatureId.value = nextValue;
    }
  }

  void dispose() {
    for (final polygon in polygons) {
      polygon.dispose();
    }
    selectedFeatureId.dispose();
  }
}

class _RenderedGisPolygon {
  _RenderedGisPolygon({
    required this.feature,
    required this.outerRing,
    required this.holes,
  }) : bounds = _GisBounds.fromPoints(outerRing);

  final GisFeature feature;
  final List<LatLng> outerRing;
  final List<List<LatLng>> holes;
  final _GisBounds bounds;
  _GisPolygonStyle? _cachedStyle;
  Polygon<GisFeature>? _normalPolygon;
  Polygon<GisFeature>? _selectedPolygon;

  int get vertexCount {
    return outerRing.length +
        holes.fold<int>(0, (count, hole) => count + hole.length);
  }

  void dispose() {
    _cachedStyle = null;
    _normalPolygon = null;
    _selectedPolygon = null;
  }

  bool contains(LatLng point) {
    if (!bounds.contains(point) || !_containsPoint(outerRing, point)) {
      return false;
    }
    return !holes.any((hole) => _containsPoint(hole, point));
  }

  _PolygonIntersectionResult intersectParcel(List<_Triangle> parcelTriangles) {
    final includedRings = _intersectTriangulations(
      parcelTriangles,
      _triangulateRing(outerRing),
    );
    final excludedRings = <List<LatLng>>[];
    for (final hole in holes) {
      excludedRings.addAll(
        _intersectTriangulations(parcelTriangles, _triangulateRing(hole)),
      );
    }
    final includedArea = includedRings.fold<double>(
      0,
      (area, ring) => area + _MeasurementLayer._calculateArea(ring),
    );
    final excludedArea = excludedRings.fold<double>(
      0,
      (area, ring) => area + _MeasurementLayer._calculateArea(ring),
    );
    return _PolygonIntersectionResult(
      includedRings: includedRings,
      excludedRings: excludedRings,
      areaSquareMeters: math.max(0, includedArea - excludedArea),
    );
  }

  Polygon<GisFeature> toPolygon(
    _GisPolygonStyle style,
    String? selectedFeatureId,
    GisRenderMetrics renderMetrics,
  ) {
    final isSelected = feature.id == selectedFeatureId;
    if (_cachedStyle != style) {
      _cachedStyle = style;
      _normalPolygon = null;
      _selectedPolygon = null;
    }

    final cached = isSelected ? _selectedPolygon : _normalPolygon;
    if (cached != null) {
      renderMetrics.polygonObjectReuseCount++;
      return cached;
    }

    renderMetrics.polygonObjectCreationCount++;
    final polygon = Polygon<GisFeature>(
      points: outerRing,
      holePointsList: holes.isEmpty ? null : holes,
      color: isSelected ? style.selectedFill : style.normalFill,
      borderColor: isSelected ? style.selectedBorder : style.normalBorder,
      borderStrokeWidth: isSelected ? 4 : 2,
    );
    if (isSelected) {
      _selectedPolygon = polygon;
    } else {
      _normalPolygon = polygon;
    }
    return polygon;
  }

  static bool _containsPoint(List<LatLng> ring, LatLng point) {
    var inside = false;
    for (
      var current = 0, previous = ring.length - 1;
      current < ring.length;
      previous = current++
    ) {
      final currentPoint = ring[current];
      final previousPoint = ring[previous];
      if (_isOnSegment(point, previousPoint, currentPoint)) {
        return true;
      }

      final crossesLatitude =
          (currentPoint.latitude > point.latitude) !=
          (previousPoint.latitude > point.latitude);
      if (!crossesLatitude) {
        continue;
      }

      final crossingLongitude =
          (previousPoint.longitude - currentPoint.longitude) *
              (point.latitude - currentPoint.latitude) /
              (previousPoint.latitude - currentPoint.latitude) +
          currentPoint.longitude;
      if (point.longitude < crossingLongitude) {
        inside = !inside;
      }
    }
    return inside;
  }

  static bool _isOnSegment(LatLng point, LatLng start, LatLng end) {
    const epsilon = 1e-10;
    final crossProduct =
        (point.latitude - start.latitude) * (end.longitude - start.longitude) -
        (point.longitude - start.longitude) * (end.latitude - start.latitude);
    if (crossProduct.abs() > epsilon) {
      return false;
    }

    return point.latitude >= math.min(start.latitude, end.latitude) - epsilon &&
        point.latitude <= math.max(start.latitude, end.latitude) + epsilon &&
        point.longitude >= math.min(start.longitude, end.longitude) - epsilon &&
        point.longitude <= math.max(start.longitude, end.longitude) + epsilon;
  }
}

class _ParcelAnalysisInvalidated implements Exception {
  const _ParcelAnalysisInvalidated();
}

class _ParcelIntersectionBuilder {
  _ParcelIntersectionBuilder({
    required this.featureId,
    required this.unitSymbol,
    required this.dominantSoilSeries,
    required this.capabilityClass,
  });

  final String featureId;
  final String unitSymbol;
  final String dominantSoilSeries;
  final String capabilityClass;
  final List<List<LatLng>> _includedRings = <List<LatLng>>[];
  final List<List<LatLng>> _excludedRings = <List<LatLng>>[];
  double _areaSquareMeters = 0;

  void add(_PolygonIntersectionResult intersection) {
    _includedRings.addAll(intersection.includedRings);
    _excludedRings.addAll(intersection.excludedRings);
    _areaSquareMeters += intersection.areaSquareMeters;
  }

  ParcelSoilIntersection build() {
    List<List<ParcelCoordinate>> convert(List<List<LatLng>> rings) {
      return List<List<ParcelCoordinate>>.unmodifiable(
        rings.map(
          (ring) => List<ParcelCoordinate>.unmodifiable(
            ring.map(
              (point) => ParcelCoordinate(
                latitude: point.latitude,
                longitude: point.longitude,
              ),
            ),
          ),
        ),
      );
    }

    return ParcelSoilIntersection(
      featureId: featureId,
      unitSymbol: unitSymbol,
      dominantSoilSeries: dominantSoilSeries,
      capabilityClass: capabilityClass,
      geometry: ParcelIntersectionGeometry(
        includedRings: convert(_includedRings),
        excludedRings: convert(_excludedRings),
      ),
      areaSquareMeters: _areaSquareMeters,
    );
  }
}

class _PolygonIntersectionResult {
  const _PolygonIntersectionResult({
    required this.includedRings,
    required this.excludedRings,
    required this.areaSquareMeters,
  });

  final List<List<LatLng>> includedRings;
  final List<List<LatLng>> excludedRings;
  final double areaSquareMeters;
}

class _Triangle {
  _Triangle(this.a, this.b, this.c)
    : south = math.min(a.latitude, math.min(b.latitude, c.latitude)),
      west = math.min(a.longitude, math.min(b.longitude, c.longitude)),
      north = math.max(a.latitude, math.max(b.latitude, c.latitude)),
      east = math.max(a.longitude, math.max(b.longitude, c.longitude));

  final LatLng a;
  final LatLng b;
  final LatLng c;
  final double south;
  final double west;
  final double north;
  final double east;
}

List<_Triangle> _triangulateRing(List<LatLng> source) {
  final points = _normalizeRing(source);
  if (points.length < 3) return const <_Triangle>[];
  final indices = List<int>.generate(points.length, (index) => index);
  final triangles = <_Triangle>[];
  final counterClockwise = _signedRingArea(points) > 0;
  const epsilon = 1e-14;

  while (indices.length > 3) {
    var earFound = false;
    for (var position = 0; position < indices.length; position++) {
      final previousIndex =
          indices[(position - 1 + indices.length) % indices.length];
      final currentIndex = indices[position];
      final nextIndex = indices[(position + 1) % indices.length];
      final a = points[previousIndex];
      final b = points[currentIndex];
      final c = points[nextIndex];
      final cross = _cross(a, b, c);
      if (counterClockwise ? cross <= epsilon : cross >= -epsilon) {
        continue;
      }

      var containsPoint = false;
      for (final candidateIndex in indices) {
        if (candidateIndex == previousIndex ||
            candidateIndex == currentIndex ||
            candidateIndex == nextIndex) {
          continue;
        }
        if (_pointInTriangle(points[candidateIndex], a, b, c)) {
          containsPoint = true;
          break;
        }
      }
      if (containsPoint) continue;

      triangles.add(_Triangle(a, b, c));
      indices.removeAt(position);
      earFound = true;
      break;
    }
    if (!earFound) return const <_Triangle>[];
  }

  triangles.add(
    _Triangle(points[indices[0]], points[indices[1]], points[indices[2]]),
  );
  return triangles;
}

List<LatLng> _normalizeRing(List<LatLng> source) {
  if (source.isEmpty) return const <LatLng>[];
  final points = <LatLng>[];
  for (final point in source) {
    if (points.isEmpty || !_samePoint(points.last, point)) {
      points.add(point);
    }
  }
  if (points.length > 1 && _samePoint(points.first, points.last)) {
    points.removeLast();
  }
  var changed = true;
  while (changed && points.length > 3) {
    changed = false;
    for (var index = 0; index < points.length; index++) {
      final previous = points[(index - 1 + points.length) % points.length];
      final current = points[index];
      final next = points[(index + 1) % points.length];
      if (_cross(previous, current, next).abs() <= 1e-14) {
        points.removeAt(index);
        changed = true;
        break;
      }
    }
  }
  return points;
}

List<List<LatLng>> _intersectTriangulations(
  List<_Triangle> parcelTriangles,
  List<_Triangle> soilTriangles,
) {
  final intersections = <List<LatLng>>[];
  for (final parcelTriangle in parcelTriangles) {
    for (final soilTriangle in soilTriangles) {
      if (parcelTriangle.east < soilTriangle.west ||
          parcelTriangle.west > soilTriangle.east ||
          parcelTriangle.north < soilTriangle.south ||
          parcelTriangle.south > soilTriangle.north) {
        continue;
      }
      final ring = _clipTriangle(parcelTriangle, soilTriangle);
      if (ring.length >= 3 && _MeasurementLayer._calculateArea(ring) > 0.01) {
        intersections.add(ring);
      }
    }
  }
  return intersections;
}

List<_Triangle> _clipTrianglesToTile(
  List<_Triangle> triangles,
  GisTileCoordinates coordinates,
) {
  final tilesAtZoom = 1 << coordinates.zoom;
  final west = coordinates.x / tilesAtZoom * 360 - 180;
  final east = (coordinates.x + 1) / tilesAtZoom * 360 - 180;

  double tileYToLatitude(int y) {
    final mercator = math.pi * (1 - 2 * y / tilesAtZoom);
    final hyperbolicSine = (math.exp(mercator) - math.exp(-mercator)) / 2;
    return math.atan(hyperbolicSine) * 180 / math.pi;
  }

  final north = tileYToLatitude(coordinates.y);
  final south = tileYToLatitude(coordinates.y + 1);
  final northWest = _safeLatLng(north, west);
  final southWest = _safeLatLng(south, west);
  final southEast = _safeLatLng(south, east);
  final northEast = _safeLatLng(north, east);
  if (northWest == null ||
      southWest == null ||
      southEast == null ||
      northEast == null) {
    return const <_Triangle>[];
  }
  final tileTriangles = <_Triangle>[
    _Triangle(northWest, southWest, southEast),
    _Triangle(northWest, southEast, northEast),
  ];
  final clippedRings = _intersectTriangulations(triangles, tileTriangles);
  return <_Triangle>[
    for (final ring in clippedRings) ..._triangulateRing(ring),
  ];
}

List<LatLng> _clipTriangle(_Triangle subject, _Triangle clip) {
  var output = <LatLng>[subject.a, subject.b, subject.c];
  final clipPoints = <LatLng>[clip.a, clip.b, clip.c];
  final counterClockwise = _signedRingArea(clipPoints) > 0;

  for (var edgeIndex = 0; edgeIndex < 3; edgeIndex++) {
    final edgeStart = clipPoints[edgeIndex];
    final edgeEnd = clipPoints[(edgeIndex + 1) % 3];
    final input = output;
    output = <LatLng>[];
    if (input.isEmpty) break;
    var start = input.last;
    var startInside = _insideClipEdge(
      start,
      edgeStart,
      edgeEnd,
      counterClockwise,
    );
    for (final end in input) {
      final endInside = _insideClipEdge(
        end,
        edgeStart,
        edgeEnd,
        counterClockwise,
      );
      if (endInside) {
        if (!startInside) {
          output.add(_lineIntersection(start, end, edgeStart, edgeEnd));
        }
        output.add(end);
      } else if (startInside) {
        output.add(_lineIntersection(start, end, edgeStart, edgeEnd));
      }
      start = end;
      startInside = endInside;
    }
  }
  return output;
}

bool _insideClipEdge(
  LatLng point,
  LatLng edgeStart,
  LatLng edgeEnd,
  bool counterClockwise,
) {
  final cross = _cross(edgeStart, edgeEnd, point);
  return counterClockwise ? cross >= -1e-14 : cross <= 1e-14;
}

LatLng _lineIntersection(
  LatLng start,
  LatLng end,
  LatLng edgeStart,
  LatLng edgeEnd,
) {
  final segmentX = end.longitude - start.longitude;
  final segmentY = end.latitude - start.latitude;
  final edgeX = edgeEnd.longitude - edgeStart.longitude;
  final edgeY = edgeEnd.latitude - edgeStart.latitude;
  final denominator = segmentX * edgeY - segmentY * edgeX;
  if (denominator.abs() <= 1e-16) return end;
  final offsetX = edgeStart.longitude - start.longitude;
  final offsetY = edgeStart.latitude - start.latitude;
  final factor = (offsetX * edgeY - offsetY * edgeX) / denominator;
  return _safeLatLng(
        start.latitude + factor * segmentY,
        start.longitude + factor * segmentX,
      ) ??
      end;
}

bool _pointInTriangle(LatLng point, LatLng a, LatLng b, LatLng c) {
  final first = _cross(a, b, point);
  final second = _cross(b, c, point);
  final third = _cross(c, a, point);
  final hasNegative = first < -1e-14 || second < -1e-14 || third < -1e-14;
  final hasPositive = first > 1e-14 || second > 1e-14 || third > 1e-14;
  return !(hasNegative && hasPositive);
}

double _signedRingArea(List<LatLng> points) {
  var area = 0.0;
  for (var index = 0; index < points.length; index++) {
    final current = points[index];
    final next = points[(index + 1) % points.length];
    area +=
        current.longitude * next.latitude - next.longitude * current.latitude;
  }
  return area / 2;
}

double _cross(LatLng a, LatLng b, LatLng c) {
  return (b.longitude - a.longitude) * (c.latitude - a.latitude) -
      (b.latitude - a.latitude) * (c.longitude - a.longitude);
}

bool _samePoint(LatLng first, LatLng second) {
  return (first.latitude - second.latitude).abs() <= 1e-12 &&
      (first.longitude - second.longitude).abs() <= 1e-12;
}

class _GisPolygonStyle {
  const _GisPolygonStyle({
    required this.normalFill,
    required this.selectedFill,
    required this.normalBorder,
    required this.selectedBorder,
  });

  factory _GisPolygonStyle.fromColorScheme(ColorScheme colorScheme) {
    return _GisPolygonStyle(
      normalFill: colorScheme.primary.withValues(alpha: 0.10),
      selectedFill: colorScheme.tertiary.withValues(alpha: 0.55),
      normalBorder: colorScheme.primary,
      selectedBorder: colorScheme.tertiary,
    );
  }

  final Color normalFill;
  final Color selectedFill;
  final Color normalBorder;
  final Color selectedBorder;

  @override
  bool operator ==(Object other) {
    return other is _GisPolygonStyle &&
        other.normalFill == normalFill &&
        other.selectedFill == selectedFill &&
        other.normalBorder == normalBorder &&
        other.selectedBorder == selectedBorder;
  }

  @override
  int get hashCode {
    return Object.hash(normalFill, selectedFill, normalBorder, selectedBorder);
  }
}

class _GisBounds {
  const _GisBounds({
    required this.south,
    required this.west,
    required this.north,
    required this.east,
  });

  factory _GisBounds.fromPoints(List<LatLng> points) {
    final validPoints = points.where(_isFiniteLatLng);
    final firstPoint = validPoints.firstOrNull;
    if (firstPoint == null) {
      return const _GisBounds(south: 0, west: 0, north: 0, east: 0);
    }
    var south = firstPoint.latitude;
    var north = firstPoint.latitude;
    var west = firstPoint.longitude;
    var east = firstPoint.longitude;

    for (final point in validPoints.skip(1)) {
      south = math.min(south, point.latitude);
      north = math.max(north, point.latitude);
      west = math.min(west, point.longitude);
      east = math.max(east, point.longitude);
    }

    return _GisBounds(south: south, west: west, north: north, east: east);
  }

  final double south;
  final double west;
  final double north;
  final double east;

  LatLng get center {
    final latitude = (south + north) / 2;
    final longitude = (west + east) / 2;
    if (!_isFiniteCoordinateValues(latitude, longitude)) {
      return const LatLng(0, 0);
    }
    return LatLng(latitude, longitude);
  }

  bool contains(LatLng point) {
    return point.latitude >= south &&
        point.latitude <= north &&
        point.longitude >= west &&
        point.longitude <= east;
  }

  bool intersects(LatLngBounds other) {
    return east >= other.west &&
        west <= other.east &&
        north >= other.south &&
        south <= other.north;
  }
}

class _GisTilePolygonLayer extends StatefulWidget {
  const _GisTilePolygonLayer({
    required this.tile,
    required this.renderMetrics,
    super.key,
  });

  final _RenderedGisTile tile;
  final GisRenderMetrics renderMetrics;

  @override
  State<_GisTilePolygonLayer> createState() => _GisTilePolygonLayerState();
}

class _GisTilePolygonLayerState extends State<_GisTilePolygonLayer> {
  int? _cachedZoom;
  String? _cachedSelection;
  _GisPolygonStyle? _cachedStyle;
  Widget? _cachedPolygonLayer;

  @override
  Widget build(BuildContext context) {
    final renderMetrics = widget.renderMetrics;
    renderMetrics.polygonLayerBuildCount++;
    final zoom = MapCamera.of(context).zoom.floor();
    final style = _GisPolygonStyle.fromColorScheme(
      Theme.of(context).colorScheme,
    );

    return IgnorePointer(
      child: ValueListenableBuilder<String?>(
        valueListenable: widget.tile.selectedFeatureId,
        builder: (context, selectedFeatureId, child) {
          final cachedLayer = _cachedPolygonLayer;
          if (cachedLayer != null &&
              _cachedZoom == zoom &&
              _cachedSelection == selectedFeatureId &&
              _cachedStyle == style) {
            renderMetrics.projectedGeometryCacheHitCount++;
            return cachedLayer;
          }

          final polygons = widget.tile.polygons
              .map(
                (polygon) =>
                    polygon.toPolygon(style, selectedFeatureId, renderMetrics),
              )
              .toList(growable: false);
          final vertexCount = widget.tile.polygons.fold<int>(
            0,
            (count, polygon) => count + polygon.vertexCount,
          );
          renderMetrics.projectedPolygonCount += polygons.length;
          renderMetrics.projectedVertexCount += vertexCount;

          final polygonLayer = PolygonLayer<GisFeature>(
            polygonLabels: false,
            polygonCulling: true,
            drawInSingleWorld: true,
            painterFillMethod: PolygonPainterFillMethod.evenOdd,
            polygons: polygons,
          );
          final profiledLayer = !renderMetrics.enabled
              ? polygonLayer
              : _GisPaintProfiler(
                  renderMetrics: renderMetrics,
                  polygonCount: polygons.length,
                  vertexCount: vertexCount,
                  child: polygonLayer,
                );
          _cachedZoom = zoom;
          _cachedSelection = selectedFeatureId;
          _cachedStyle = style;
          return _cachedPolygonLayer = profiledLayer;
        },
      ),
    );
  }
}

class _GisPaintProfiler extends SingleChildRenderObjectWidget {
  const _GisPaintProfiler({
    required this.renderMetrics,
    required this.polygonCount,
    required this.vertexCount,
    required super.child,
  });

  final GisRenderMetrics renderMetrics;
  final int polygonCount;
  final int vertexCount;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderGisPaintProfiler(
      renderMetrics: renderMetrics,
      polygonCount: polygonCount,
      vertexCount: vertexCount,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderGisPaintProfiler renderObject,
  ) {
    renderObject
      ..renderMetrics = renderMetrics
      ..polygonCount = polygonCount
      ..vertexCount = vertexCount;
  }
}

class _RenderGisPaintProfiler extends RenderProxyBox {
  _RenderGisPaintProfiler({
    required this.renderMetrics,
    required this.polygonCount,
    required this.vertexCount,
  });

  GisRenderMetrics renderMetrics;
  int polygonCount;
  int vertexCount;

  @override
  void paint(PaintingContext context, Offset offset) {
    final stopwatch = Stopwatch()..start();
    super.paint(context, offset);
    stopwatch.stop();

    renderMetrics.paintCount++;
    renderMetrics.submittedPolygonCount += polygonCount;
    renderMetrics.submittedVertexCount += vertexCount;
    renderMetrics.totalPaintDuration += stopwatch.elapsed;
  }
}

class _MapChromeIconButton extends StatelessWidget {
  const _MapChromeIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.includeOuterSpacing = true,
    this.useDesktopSurfaceStyle = false,
    this.cursorOverride,
  });

  final String tooltip;
  final Widget icon;
  final VoidCallback? onPressed;
  final bool includeOuterSpacing;

  /// See [_MapChromeSurface.useDesktopSurfaceStyle].
  final bool useDesktopSurfaceStyle;

  /// See [_MapChromeSurface.cursorOverride].
  final MouseCursor? cursorOverride;

  @override
  Widget build(BuildContext context) {
    return _MapChromeSurface(
      enabled: onPressed != null,
      includeOuterSpacing: includeOuterSpacing,
      useDesktopSurfaceStyle: useDesktopSurfaceStyle,
      cursorOverride: cursorOverride,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: icon,
        iconSize: useDesktopSurfaceStyle ? 26 : 21,
        padding: EdgeInsets.zero,
      ),
    );
  }
}

typedef _SynchronizedMapHeaderBuilder =
    Widget Function(
      BuildContext context,
      double titleFactor,
      double undoFactor,
      double clearFactor,
    );

class _SynchronizedMapHeaderTransition extends StatefulWidget {
  const _SynchronizedMapHeaderTransition({
    required this.titleVisible,
    required this.undoVisible,
    required this.clearVisible,
    required this.builder,
  });

  final bool titleVisible;
  final bool undoVisible;
  final bool clearVisible;
  final _SynchronizedMapHeaderBuilder builder;

  @override
  State<_SynchronizedMapHeaderTransition> createState() =>
      _SynchronizedMapHeaderTransitionState();
}

class _SynchronizedMapHeaderTransitionState
    extends State<_SynchronizedMapHeaderTransition>
    with SingleTickerProviderStateMixin {
  static const _kHeaderTransitionDuration = Duration(milliseconds: 220);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _kHeaderTransitionDuration,
    reverseDuration: _kHeaderTransitionDuration,
    value: 1,
  );

  late double _titleStart = widget.titleVisible ? 1 : 0;
  late double _undoStart = widget.undoVisible ? 1 : 0;
  late double _clearStart = widget.clearVisible ? 1 : 0;
  late double _titleTarget = _titleStart;
  late double _undoTarget = _undoStart;
  late double _clearTarget = _clearStart;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final duration = AppMotion.duration(context, _kHeaderTransitionDuration);

    _controller.duration = duration;
    _controller.reverseDuration = duration;

    if (duration == Duration.zero) {
      _controller.value = 1;
    }
  }

  @override
  void didUpdateWidget(_SynchronizedMapHeaderTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.titleVisible == widget.titleVisible &&
        oldWidget.undoVisible == widget.undoVisible &&
        oldWidget.clearVisible == widget.clearVisible) {
      return;
    }
    _titleStart = _factor(_titleStart, _titleTarget);
    _undoStart = _factor(_undoStart, _undoTarget);
    _clearStart = _factor(_clearStart, _clearTarget);
    _titleTarget = widget.titleVisible ? 1 : 0;
    _undoTarget = widget.undoVisible ? 1 : 0;
    _clearTarget = widget.clearVisible ? 1 : 0;
    if (_controller.duration == Duration.zero) {
      _controller.value = 1;
    } else {
      _controller.forward(from: 0);
    }
  }

  double _factor(double start, double target) {
    if (start == target) return target;
    final progress = Curves.easeOutCubic.transform(_controller.value);
    return ui.lerpDouble(start, target, progress)!;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => widget.builder(
        context,
        _factor(_titleStart, _titleTarget),
        _factor(_undoStart, _undoTarget),
        _factor(_clearStart, _clearTarget),
      ),
    );
  }
}

class _MapHeaderTransitionItem extends StatelessWidget {
  const _MapHeaderTransitionItem({
    super.key,
    required this.factor,
    required this.child,
  });

  final double factor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Offstage(
      offstage: factor == 0,
      child: ClipRect(
        child: Align(
          alignment: Alignment.centerLeft,
          widthFactor: factor,
          heightFactor: 1,
          child: Opacity(
            opacity: factor,
            child: IgnorePointer(
              ignoring: factor < 1,
              child: ExcludeSemantics(excluding: factor < 1, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

class _AnimatedMapHeaderItem extends StatefulWidget {
  const _AnimatedMapHeaderItem({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  State<_AnimatedMapHeaderItem> createState() => _AnimatedMapHeaderItemState();
}

class _AnimatedMapHeaderItemState extends State<_AnimatedMapHeaderItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    value: widget.visible ? 1 : 0,
  );
  late final Animation<double> _animation = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final duration = AppMotion.duration(
      context,
      const Duration(milliseconds: 160),
    );
    _controller.duration = duration;
    _controller.reverseDuration = duration;
    _animateToVisibility();
  }

  @override
  void didUpdateWidget(_AnimatedMapHeaderItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) {
      _animateToVisibility();
    }
  }

  void _animateToVisibility() {
    if (_controller.duration == Duration.zero) {
      _controller.value = widget.visible ? 1 : 0;
    } else if (widget.visible) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedBuilder(
        animation: _animation,
        child: widget.child,
        builder: (context, child) {
          if (!widget.visible && _animation.value == 0) {
            return const SizedBox.shrink();
          }
          return Align(
            alignment: Alignment.centerLeft,
            widthFactor: _animation.value,
            heightFactor: 1,
            child: Opacity(
              opacity: _animation.value,
              child: IgnorePointer(
                ignoring: !widget.visible,
                child: ExcludeSemantics(
                  excluding: !widget.visible,
                  child: child,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _MapTopBarCard extends StatelessWidget {
  const _MapTopBarCard({
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 10),
    this.elevation = 3,
    this.shadowAlpha = 0.18,
    this.side,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double elevation;
  final double shadowAlpha;
  final BorderSide? side;

  @override
  Widget build(BuildContext context) {
    return FloatingAppBarCard(
      padding: padding,
      elevation: elevation,
      shadowAlpha: shadowAlpha,
      side: side,
      child: child,
    );
  }
}

class _LayersMenuButton extends StatefulWidget {
  const _LayersMenuButton({
    required this.showSoilPolygons,
    required this.showReferenceBasemap,
    required this.onToggle,
  });

  final bool showSoilPolygons;
  final bool showReferenceBasemap;
  final ValueChanged<_LayerVisibilityOption> onToggle;

  @override
  State<_LayersMenuButton> createState() => _LayersMenuButtonState();
}

class _LayersMenuButtonState extends State<_LayersMenuButton> {
  final MenuController _controller = MenuController();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final compactMenu = viewportWidth < 344;
    final compactMenuWidth = viewportWidth - 24;
    final menuContentWidth = compactMenu ? compactMenuWidth : 300.0;
    return MenuAnchor(
      controller: _controller,
      alignmentOffset: Offset(compactMenu ? -(compactMenuWidth - 44) : -256, 8),
      style: MenuStyle(
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 10),
        ),
        minimumSize: WidgetStatePropertyAll(
          Size(compactMenu ? compactMenuWidth : 300, 0),
        ),
        maximumSize: WidgetStatePropertyAll(
          Size(compactMenu ? compactMenuWidth : 320, double.infinity),
        ),
        elevation: const WidgetStatePropertyAll(6),
        shadowColor: WidgetStatePropertyAll(
          colorScheme.shadow.withValues(alpha: 0.18),
        ),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        backgroundColor: WidgetStatePropertyAll(
          colorScheme.surfaceContainerLow,
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: BorderSide(
              color: colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
        ),
      ),
      menuChildren: [
        SizedBox(
          width: menuContentWidth,
          child: _LayerVisibilityMenuItem(
            title: 'Polígonos de suelo',
            subtitle: 'Unidades cartográficas',
            icon: AppIcons.map,
            isVisible: widget.showSoilPolygons,
            onChanged: () =>
                widget.onToggle(_LayerVisibilityOption.soilPolygons),
          ),
        ),
        SizedBox(
          width: menuContentWidth,
          child: _LayerVisibilityMenuItem(
            title: 'Mapa de referencia',
            subtitle: 'Rutas, ríos y localidades',
            icon: AppIcons.layers,
            isVisible: widget.showReferenceBasemap,
            onChanged: () =>
                widget.onToggle(_LayerVisibilityOption.referenceBasemap),
          ),
        ),
      ],
      builder: (context, controller, child) {
        return IconButton(
          tooltip: 'Capas',
          padding: EdgeInsets.zero,
          iconSize: 21,
          icon: const Icon(AppIcons.layers),
          onPressed: () {
            controller.isOpen ? controller.close() : controller.open();
          },
        );
      },
    );
  }
}

class _LayerVisibilityMenuItem extends StatelessWidget {
  const _LayerVisibilityMenuItem({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.isVisible,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final bool isVisible;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: Material(
        color: isVisible
            ? colorScheme.primaryContainer.withValues(alpha: 0.22)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onChanged,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Row(
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: SizedBox.square(
                    dimension: 38,
                    child: Icon(icon, size: 19, color: colorScheme.primary),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Switch(
                  value: isVisible,
                  onChanged: (_) => onChanged(),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MapChromeSurface extends StatefulWidget {
  const _MapChromeSurface({
    required this.child,
    this.enabled = true,
    this.includeOuterSpacing = true,
    this.useDesktopSurfaceStyle = false,
    this.cursorOverride,
  });

  final Widget child;
  final bool enabled;
  final bool includeOuterSpacing;

  /// Replaces the default `enabled ? click : basic` cursor with this
  /// value while hovering. Only the desktop compass sets this (to show a
  /// grab/grabbing hand, since it's draggable, not just clickable) — null
  /// for every other caller keeps today's plain click cursor.
  final MouseCursor? cursorOverride;

  /// True only for the desktop compass control. Swaps the brown/cream
  /// mobile chrome tokens ([SuelosArMapControlColors]) for the white
  /// surface + [ColorScheme.shadow] alpha 0.18 that [FloatingAppBarCard]
  /// already uses for the rest of the desktop GIS's floating chrome, and
  /// tints the icon with [ColorScheme.primary] — the same accent
  /// `_DesktopMapPanelAction`/`_GisFavoriteStarButton` already use —
  /// instead of the mobile chrome's cream foreground. Every other caller
  /// (the mobile compass, the layers button, the "Mi ubicación" button,
  /// etc.) keeps rendering the existing brown chrome unchanged; the
  /// hover/press scale-and-elevation behavior below is untouched either
  /// way, only the color tokens differ.
  final bool useDesktopSurfaceStyle;

  @override
  State<_MapChromeSurface> createState() => _MapChromeSurfaceState();
}

class _MapChromeSurfaceState extends State<_MapChromeSurface> {
  static const Duration _animationDuration = Duration(milliseconds: 180);

  bool _isHovered = false;
  bool _isPressed = false;

  void _setHovered(bool value) {
    if (widget.enabled && _isHovered != value) {
      setState(() => _isHovered = value);
    }
  }

  void _setPressed(bool value) {
    if (widget.enabled && _isPressed != value) {
      setState(() => _isPressed = value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final mapControlColors =
        Theme.of(context).extension<SuelosArMapControlColors>() ??
        const SuelosArMapControlColors(
          background: Color(0xFF9B7657),
          foreground: Color(0xFFFFF9F0),
          activeAccent: Color(0xFF71805A),
        );
    final elevation = _isHovered ? 3.0 : 1.0;
    final scale = _isPressed ? 0.96 : (_isHovered ? 1.02 : 1.0);
    final surfaceColor = widget.useDesktopSurfaceStyle
        ? Colors.white
        : mapControlColors.background.withValues(alpha: 0.97);
    final iconColor = widget.useDesktopSurfaceStyle
        ? colorScheme.primary
        : mapControlColors.foreground;
    // Desktop style sits directly over map imagery (not a chrome bar), so
    // it gets a more visible shadow and a thin outline for contrast on
    // bright/white map areas — neither is needed for the mobile chrome,
    // which already sits on its own opaque brown surface.
    final shadowAlpha = widget.useDesktopSurfaceStyle ? 0.26 : 0.16;
    final borderSide = widget.useDesktopSurfaceStyle
        ? BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.5))
        : BorderSide.none;
    final dimension = widget.useDesktopSurfaceStyle ? 48.0 : 44.0;

    final surface = MouseRegion(
      cursor: !widget.enabled
          ? SystemMouseCursors.basic
          : widget.cursorOverride ?? SystemMouseCursors.click,
      onEnter: (_) => _setHovered(true),
      onExit: (_) {
        _setHovered(false);
        _setPressed(false);
      },
      child: Listener(
        onPointerDown: (_) => _setPressed(true),
        onPointerUp: (_) => _setPressed(false),
        onPointerCancel: (_) => _setPressed(false),
        child: AnimatedScale(
          scale: scale,
          duration: _animationDuration,
          curve: Curves.easeOutCubic,
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: elevation),
            duration: _animationDuration,
            curve: Curves.easeOutCubic,
            builder: (context, animatedElevation, child) {
              return Material(
                elevation: animatedElevation,
                shadowColor: colorScheme.shadow.withValues(alpha: shadowAlpha),
                color: surfaceColor,
                surfaceTintColor: Colors.transparent,
                shape: CircleBorder(side: borderSide),
                clipBehavior: Clip.antiAlias,
                child: child,
              );
            },
            child: SizedBox.square(
              dimension: dimension,
              child: IconTheme.merge(
                data: IconThemeData(color: iconColor),
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );

    return Padding(
      padding: widget.includeOuterSpacing
          ? const EdgeInsets.symmetric(horizontal: 3.5)
          : EdgeInsets.zero,
      child: surface,
    );
  }
}
