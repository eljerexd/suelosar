# SuelosAR GIS pipeline

This Docker pipeline rebuilds the offline vector map from the original
shapefile. It repairs geometries with GDAL, verifies the repaired dataset,
creates four level-of-detail (LOD) tiers with Tippecanoe, and joins them into
one PMTiles archive.

## Prerequisites

- Docker Desktop or Docker Engine
- Docker Compose v2
- The original shapefile and its sidecars

## Source data

Copy one shapefile dataset into `docker/input/`. At minimum it must contain
files with the same base name and these extensions:

```text
soil_polygons.shp
soil_polygons.dbf
soil_polygons.shx
soil_polygons.prj
```

An optional `.cpg` file should be included when the source uses a specific text
encoding. If the source has no `.prj`, provide its CRS through `SOURCE_SRS`.

## Rebuild

From the project root, run:

```text
docker compose -f docker/docker-compose.yml run --rm --build map-builder
```

The command automatically detects the only `.shp` file in `docker/input/` and
writes:

```text
assets/maps/soil_polygons.pmtiles
assets/maps/soil_polygons.pmtiles.sha256
```

The existing output is replaced only after the new PMTiles file has been built
and fully validated. Validation checks the PMTiles version, MVT tile type, zoom
range, layer name, and every GIS attribute used by the application. The
SHA-256 sidecar lets Flutter refresh its local random-access copy only when the
archive changes.

## Level-of-detail strategy

The final archive keeps the `soil_polygons` layer and zoom range expected by
the application, but each zoom band is generated separately:

| LOD | Zooms | Geometry | Feature density | Tile limits |
| --- | --- | --- | --- | --- |
| Low | 4-6 | Highly simplified, 1024-unit maximum extent | Progressively drops the smallest polygons in overview zooms | 200 KB, 1,000 features |
| Zoom 7 transition | 7 | Strongly simplified transition geometry | Preserves polygon features unless tile limits require reduction | 200 KB, 1,000 features |
| Medium | 8-10 | Moderate simplification, 1024-unit extent | Reduces polygon density at z8-z9 | 350 KB, 2,500 features |
| Intermediate | 11-12 | Gradual simplification from scale 4 to 2 | Keeps every feature | 750 KB, 10,000 features |
| High | 13-14 | Unsimplified source geometry | Keeps every feature | No forced size or feature reduction |

The low overview retains its existing density policy through z6. Zoom 7 uses a
dedicated transition tier to avoid overloading the renderer before z8. From z8
upward, polygon density is reduced only at z8-z9: the intermediate and high
tiers retain every feature. The high tier preserves unsimplified source geometry. All source
attributes are passed through unchanged. Polygon coalescing is intentionally
not used because it can discard the attributes needed by polygon selection and
PDF matching.

Every tier uses spatial Hilbert ordering and shared-node-aware simplification.
This improves compression while keeping adjacent polygon boundaries aligned.

## Updating the source

Replace every shapefile component in `docker/input/` and run the same rebuild
command. Do not mix sidecars from different source versions.

If the input directory contains more than one shapefile, select one explicitly:

```text
SOURCE_SHAPEFILE=updated_soils.shp docker compose -f docker/docker-compose.yml run --rm --build map-builder
```

In PowerShell:

```powershell
$env:SOURCE_SHAPEFILE = "updated_soils.shp"
docker compose -f docker/docker-compose.yml run --rm --build map-builder
```

## Compare a candidate

Build a candidate without replacing the active archive:

```powershell
$env:OUTPUT_NAME = "soil_polygons_candidate.pmtiles"
docker compose -f docker/docker-compose.yml run --rm --build map-builder
Remove-Item Env:OUTPUT_NAME
```

Profile the active map against the candidate:

```powershell
$env:BASELINE_MAP = "soil_polygons.pmtiles"
$env:CANDIDATE_MAP = "soil_polygons_candidate.pmtiles"
docker compose -f docker/docker-compose.yml run --rm --build map-profiler
Remove-Item Env:BASELINE_MAP
Remove-Item Env:CANDIDATE_MAP
```

The profiler reports file size plus median decode time, features per tile, and
vertices per tile for startup, panning, and zoom workloads. Set
`PROFILE_RUNS` to change the default three repetitions.

## Configuration

The Compose service accepts these optional environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `SOURCE_SHAPEFILE` | auto-detected | Input filename inside `docker/input/` |
| `SOURCE_SRS` | value from `.prj` | CRS override such as `EPSG:22185` |
| `OUTPUT_NAME` | `soil_polygons.pmtiles` | Output filename |
| `LAYER_NAME` | `soil_polygons` | Vector tile layer name |
| `MIN_ZOOM` | `4` | Minimum generated zoom |
| `MAX_ZOOM` | `14` | Maximum generated zoom |
| `LOW_MAX_ZOOM` | `6` | Last highly simplified overview zoom; z7 is generated separately |
| `MEDIUM_MAX_ZOOM` | `10` | Last density-reduced medium zoom |
| `INTERMEDIATE_MAX_ZOOM` | `12` | Last transition zoom before full geometry |
| `PROFILE_RUNS` | `3` | Repetitions used by the profiler |
| `TIPPECANOE_REF` | pinned commit | Tippecanoe source revision |

The source directory is mounted read-only. Temporary validated data stays
inside the container and is deleted after every run.
