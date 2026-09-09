#!/usr/bin/env bash

set -Eeuo pipefail

log() {
  printf '[SuelosAR GIS] %s\n' "$*"
}

fail() {
  printf '[SuelosAR GIS] ERROR: %s\n' "$*" >&2
  exit 1
}

find_sidecar() {
  local base_path="$1"
  local extension="$2"

  if [[ -f "${base_path}.${extension}" ]]; then
    printf '%s\n' "${base_path}.${extension}"
    return
  fi

  if [[ -f "${base_path}.${extension^^}" ]]; then
    printf '%s\n' "${base_path}.${extension^^}"
    return
  fi

  return 1
}

INPUT_DIR="${INPUT_DIR:-/data/input}"
OUTPUT_DIR="${OUTPUT_DIR:-/data/output}"
OUTPUT_NAME="${OUTPUT_NAME:-soil_polygons.pmtiles}"
LAYER_NAME="${LAYER_NAME:-soil_polygons}"
MIN_ZOOM="${MIN_ZOOM:-4}"
MAX_ZOOM="${MAX_ZOOM:-14}"
LOW_MAX_ZOOM="${LOW_MAX_ZOOM:-6}"
MEDIUM_MAX_ZOOM="${MEDIUM_MAX_ZOOM:-10}"
INTERMEDIATE_MAX_ZOOM="${INTERMEDIATE_MAX_ZOOM:-12}"
SOURCE_SHAPEFILE="${SOURCE_SHAPEFILE:-}"
SOURCE_SRS="${SOURCE_SRS:-}"
# Comma-separated subset of the required attributes below that may be
# present as an empty column (schema still enforced) instead of needing at
# least one populated sample. Empty by default: every dataset that does not
# set this — including Buenos Aires — keeps the exact original behavior,
# since required_attributes minus an empty set is required_attributes.
OPTIONAL_ATTRIBUTES="${OPTIONAL_ATTRIBUTES:-}"

[[ -d "${INPUT_DIR}" ]] || fail "Input directory not found: ${INPUT_DIR}"
[[ -d "${OUTPUT_DIR}" ]] || fail "Output directory not found: ${OUTPUT_DIR}"
[[ "${OUTPUT_NAME}" != */* ]] || fail "OUTPUT_NAME must be a filename."
[[ "${OUTPUT_NAME,,}" == *.pmtiles ]] || fail "OUTPUT_NAME must end in .pmtiles."
[[ "${MIN_ZOOM}" =~ ^[0-9]+$ ]] || fail "MIN_ZOOM must be an integer."
[[ "${MAX_ZOOM}" =~ ^[0-9]+$ ]] || fail "MAX_ZOOM must be an integer."
[[ "${LOW_MAX_ZOOM}" =~ ^[0-9]+$ ]] \
  || fail "LOW_MAX_ZOOM must be an integer."
[[ "${MEDIUM_MAX_ZOOM}" =~ ^[0-9]+$ ]] \
  || fail "MEDIUM_MAX_ZOOM must be an integer."
[[ "${INTERMEDIATE_MAX_ZOOM}" =~ ^[0-9]+$ ]] \
  || fail "INTERMEDIATE_MAX_ZOOM must be an integer."
(( MIN_ZOOM <= MAX_ZOOM )) || fail "MIN_ZOOM cannot exceed MAX_ZOOM."
(( MIN_ZOOM <= LOW_MAX_ZOOM )) \
  || fail "LOW_MAX_ZOOM cannot be lower than MIN_ZOOM."
(( LOW_MAX_ZOOM == 6 )) \
  || fail "LOW_MAX_ZOOM must be 6 because z7 uses a dedicated transition LOD."
(( LOW_MAX_ZOOM < MEDIUM_MAX_ZOOM )) \
  || fail "LOW_MAX_ZOOM must be lower than MEDIUM_MAX_ZOOM."
(( MEDIUM_MAX_ZOOM < INTERMEDIATE_MAX_ZOOM )) \
  || fail "MEDIUM_MAX_ZOOM must be lower than INTERMEDIATE_MAX_ZOOM."
(( INTERMEDIATE_MAX_ZOOM < MAX_ZOOM )) \
  || fail "INTERMEDIATE_MAX_ZOOM must be lower than MAX_ZOOM."

if [[ -n "${SOURCE_SHAPEFILE}" ]]; then
  if [[ "${SOURCE_SHAPEFILE}" != /* ]]; then
    SOURCE_SHAPEFILE="${INPUT_DIR}/${SOURCE_SHAPEFILE}"
  fi
else
  mapfile -d '' SHAPEFILES < <(
    find "${INPUT_DIR}" -maxdepth 1 -type f -iname '*.shp' -print0
  )

  if (( ${#SHAPEFILES[@]} == 0 )); then
    fail "No shapefile found in ${INPUT_DIR}."
  fi
  if (( ${#SHAPEFILES[@]} > 1 )); then
    fail "Multiple shapefiles found. Set SOURCE_SHAPEFILE to choose one."
  fi

  SOURCE_SHAPEFILE="${SHAPEFILES[0]}"
fi

[[ -f "${SOURCE_SHAPEFILE}" ]] || fail "Shapefile not found: ${SOURCE_SHAPEFILE}"

SOURCE_BASE="${SOURCE_SHAPEFILE%.*}"
find_sidecar "${SOURCE_BASE}" dbf >/dev/null \
  || fail "Required .dbf sidecar is missing."
find_sidecar "${SOURCE_BASE}" shx >/dev/null \
  || fail "Required .shx sidecar is missing."
if [[ -z "${SOURCE_SRS}" ]]; then
  find_sidecar "${SOURCE_BASE}" prj >/dev/null \
    || fail "A .prj sidecar or SOURCE_SRS is required."
fi

WORK_DIR="$(mktemp -d /tmp/suelosar-gis.XXXXXX)"
VALIDATED_DATA="${WORK_DIR}/validated.fgb"
ATTRIBUTE_SAMPLES="${WORK_DIR}/attribute_samples.json"
LOW_TILES="${WORK_DIR}/low.pmtiles"
ZOOM7_TILES="${WORK_DIR}/zoom7.pmtiles"
MEDIUM_TILES="${WORK_DIR}/medium.pmtiles"
INTERMEDIATE_TILES="${WORK_DIR}/intermediate.pmtiles"
HIGH_TILES="${WORK_DIR}/high.pmtiles"
OUTPUT_PATH="${OUTPUT_DIR}/${OUTPUT_NAME}"
TEMP_OUTPUT="${OUTPUT_DIR}/.${OUTPUT_NAME%.pmtiles}.tmp.pmtiles"
VERSION_PATH="${OUTPUT_PATH}.sha256"
TEMP_VERSION="${VERSION_PATH}.tmp"

cleanup() {
  rm -rf "${WORK_DIR}"
  rm -f "${TEMP_OUTPUT}"
  rm -f "${TEMP_VERSION}"
}
trap cleanup EXIT

SOURCE_SRS_ARGS=()
if [[ -n "${SOURCE_SRS}" ]]; then
  SOURCE_SRS_ARGS=(-s_srs "${SOURCE_SRS}")
fi

log "Reading ${SOURCE_SHAPEFILE}"
ogrinfo -ro -so "${SOURCE_SHAPEFILE}" >/dev/null

log "Repairing geometries and reprojecting to EPSG:4326"
ogr2ogr \
  -f FlatGeobuf \
  "${VALIDATED_DATA}" \
  "${SOURCE_SHAPEFILE}" \
  "${SOURCE_SRS_ARGS[@]}" \
  -t_srs EPSG:4326 \
  -makevalid \
  -nlt PROMOTE_TO_MULTI \
  -dim XY \
  -nln "${LAYER_NAME}" \
  -lco SPATIAL_INDEX=YES

log "Validating repaired geometries"
python3 - "${VALIDATED_DATA}" "${LAYER_NAME}" "${ATTRIBUTE_SAMPLES}" "${OPTIONAL_ATTRIBUTES}" <<'PY'
import json
import sys

from osgeo import ogr

dataset_path, layer_name, samples_path, optional_attributes_csv = sys.argv[1:5]
dataset = ogr.Open(dataset_path, 0)
if dataset is None:
    raise SystemExit(f"Unable to open validated dataset: {dataset_path}")

layer = dataset.GetLayerByName(layer_name)
if layer is None:
    raise SystemExit(f"Validated layer not found: {layer_name}")

feature_count = layer.GetFeatureCount()
if feature_count <= 0:
    raise SystemExit("The validated layer contains no features.")

invalid_count = 0
missing_count = 0
required_attributes = {
    "SIMBC",
    "Nombre_UC",
    "TIPO",
    "CAP_USO",
    "PAISAJE",
    *(f"SERIE{index}" for index in range(1, 7)),
    *(f"PORC{index}" for index in range(1, 7)),
}
field_names = {
    layer.GetLayerDefn().GetFieldDefn(index).GetName()
    for index in range(layer.GetLayerDefn().GetFieldCount())
}
missing_fields = sorted(required_attributes - field_names)
if missing_fields:
    raise SystemExit(
        "Required source attributes are missing: " + ", ".join(missing_fields)
    )

# Attributes listed here must still exist as columns (checked above) but are
# allowed to be empty on every feature — for datasets whose source genuinely
# has no data for that attribute (documented per-dataset, not invented).
optional_attributes = {
    name.strip() for name in optional_attributes_csv.split(",") if name.strip()
}
unknown_optional = sorted(optional_attributes - required_attributes)
if unknown_optional:
    raise SystemExit(
        "OPTIONAL_ATTRIBUTES lists unknown attributes: "
        + ", ".join(unknown_optional)
    )
attributes_needing_samples = required_attributes - optional_attributes

attribute_samples = {}
for feature in layer:
    geometry = feature.GetGeometryRef()
    if geometry is None:
        missing_count += 1
    elif not geometry.IsValid():
        invalid_count += 1
    else:
        representative_point = geometry.PointOnSurface()
        for attribute in attributes_needing_samples - attribute_samples.keys():
            value = feature.GetField(attribute)
            if value is not None and str(value).strip():
                attribute_samples[attribute] = [
                    representative_point.GetX(),
                    representative_point.GetY(),
                ]

if missing_count or invalid_count:
    raise SystemExit(
        f"Geometry validation failed: {invalid_count} invalid, "
        f"{missing_count} missing."
    )

missing_samples = sorted(attributes_needing_samples - attribute_samples.keys())
if missing_samples:
    raise SystemExit(
        "Required attributes have no populated source values: "
        + ", ".join(missing_samples)
    )

with open(samples_path, "w", encoding="utf-8") as samples_file:
    json.dump(attribute_samples, samples_file, ensure_ascii=False)

print(f"[SuelosAR GIS] Validated {feature_count} features.")
PY

COMMON_OPTIONS=(
  --force
  --layer="${LAYER_NAME}"
  --projection=EPSG:4326
  --generate-ids
  --no-simplification-of-shared-nodes
  --hilbert
  --read-parallel
  --no-progress-indicator
)

log "Building low-detail LOD (z${MIN_ZOOM}-z${LOW_MAX_ZOOM})"
tippecanoe \
  --output="${LOW_TILES}" \
  --name="SuelosAR soil polygons - low LOD" \
  --description="Highly simplified overview polygons" \
  --minimum-zoom="${MIN_ZOOM}" \
  --maximum-zoom="${LOW_MAX_ZOOM}" \
  --full-detail=10 \
  --low-detail=9 \
  --minimum-detail=8 \
  --simplification=10 \
  --simplification-at-maximum-zoom=10 \
  --tiny-polygon-size=4 \
  --base-zoom="${LOW_MAX_ZOOM}" \
  --drop-rate=2 \
  --drop-polygons \
  --drop-smallest-as-needed \
  --maximum-tile-bytes=200000 \
  --maximum-tile-features=1000 \
  --buffer=4 \
  "${COMMON_OPTIONS[@]}" \
  "${VALIDATED_DATA}"

log "Building zoom-7 transition LOD"
tippecanoe \
  --output="${ZOOM7_TILES}" \
  --name="SuelosAR soil polygons - zoom 7 transition LOD" \
  --description="Strongly simplified transition polygons for z7" \
  --minimum-zoom=7 \
  --maximum-zoom=7 \
  --full-detail=9 \
  --low-detail=9 \
  --minimum-detail=8 \
  --simplification=60 \
  --simplification-at-maximum-zoom=60 \
  --tiny-polygon-size=10 \
  --base-zoom=7 \
  --drop-rate=4 \
  --drop-polygons \
  --drop-smallest-as-needed \
  --maximum-tile-bytes=100000 \
  --maximum-tile-features=600 \
  --buffer=4 \
  "${COMMON_OPTIONS[@]}" \
  "${VALIDATED_DATA}"

log "Building medium-detail LOD (z$((LOW_MAX_ZOOM + 2))-z${MEDIUM_MAX_ZOOM})"
tippecanoe \
  --output="${MEDIUM_TILES}" \
  --name="SuelosAR soil polygons - medium LOD" \
  --description="Moderately simplified regional polygons" \
  --minimum-zoom="$((LOW_MAX_ZOOM + 2))" \
  --maximum-zoom="${MEDIUM_MAX_ZOOM}" \
  --full-detail=10 \
  --low-detail=10 \
  --minimum-detail=9 \
  --simplification=4 \
  --simplification-at-maximum-zoom=4 \
  --base-zoom="${MEDIUM_MAX_ZOOM}" \
  --drop-rate=2 \
  --drop-polygons \
  --drop-smallest-as-needed \
  --maximum-tile-bytes=350000 \
  --maximum-tile-features=2500 \
  --buffer=5 \
  "${COMMON_OPTIONS[@]}" \
  "${VALIDATED_DATA}"

log "Building intermediate LOD (z$((MEDIUM_MAX_ZOOM + 1))-z${INTERMEDIATE_MAX_ZOOM})"
tippecanoe \
  --output="${INTERMEDIATE_TILES}" \
  --name="SuelosAR soil polygons - intermediate LOD" \
  --description="High-precision transition polygons without density reduction" \
  --minimum-zoom="$((MEDIUM_MAX_ZOOM + 1))" \
  --maximum-zoom="${INTERMEDIATE_MAX_ZOOM}" \
  --full-detail=12 \
  --low-detail=11 \
  --minimum-detail=10 \
  --simplification=4 \
  --simplification-at-maximum-zoom=2 \
  --maximum-tile-bytes=750000 \
  --maximum-tile-features=10000 \
  --buffer=5 \
  "${COMMON_OPTIONS[@]}" \
  "${VALIDATED_DATA}"

log "Building high-detail LOD (z$((INTERMEDIATE_MAX_ZOOM + 1))-z${MAX_ZOOM})"
tippecanoe \
  --output="${HIGH_TILES}" \
  --name="SuelosAR soil polygons - high LOD" \
  --description="Full-accuracy inspection polygons" \
  --minimum-zoom="$((INTERMEDIATE_MAX_ZOOM + 1))" \
  --maximum-zoom="${MAX_ZOOM}" \
  --full-detail=12 \
  --low-detail=12 \
  --minimum-detail=12 \
  --no-line-simplification \
  --no-tiny-polygon-reduction \
  --no-tile-size-limit \
  --no-feature-limit \
  --buffer=5 \
  "${COMMON_OPTIONS[@]}" \
  "${VALIDATED_DATA}"

log "Joining LOD tiers into one PMTiles archive"
rm -f "${TEMP_OUTPUT}"
tile-join \
  -f \
  -pk \
  --name="SuelosAR soil polygons" \
  --description="LOD-optimized soil polygons for offline use" \
  --output="${TEMP_OUTPUT}" \
  "${LOW_TILES}" \
  "${ZOOM7_TILES}" \
  "${MEDIUM_TILES}" \
  "${INTERMEDIATE_TILES}" \
  "${HIGH_TILES}"

[[ -s "${TEMP_OUTPUT}" ]] || fail "Tippecanoe produced an empty output file."

python3 /usr/local/bin/validate_map.py \
  "${TEMP_OUTPUT}" \
  "${LAYER_NAME}" \
  "${MIN_ZOOM}" \
  "${MAX_ZOOM}" \
  "${ATTRIBUTE_SAMPLES}" \
  "${OPTIONAL_ATTRIBUTES}"

python3 - "${TEMP_OUTPUT}" <<'PY'
import sys

with open(sys.argv[1], "rb") as pmtiles:
    header = pmtiles.read(7)

if header != b"PMTiles":
    raise SystemExit("The generated file does not have a PMTiles header.")
PY

sha256sum "${TEMP_OUTPUT}" | cut -d ' ' -f1 > "${TEMP_VERSION}"
mv -f "${TEMP_OUTPUT}" "${OUTPUT_PATH}"
mv -f "${TEMP_VERSION}" "${VERSION_PATH}"
log "Created ${OUTPUT_PATH} ($(du -h "${OUTPUT_PATH}" | cut -f1))"
