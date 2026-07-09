#!/usr/bin/env python3

import json
import math
import subprocess
import sys
from pathlib import Path


REQUIRED_ATTRIBUTES = {
    "SIMBC",
    "Nombre_UC",
    "TIPO",
    "CAP_USO",
    "PAISAJE",
    *(f"SERIE{index}" for index in range(1, 7)),
    *(f"PORC{index}" for index in range(1, 7)),
}


def fail(message):
    raise SystemExit(f"[SuelosAR GIS] ERROR: {message}")


def tile_coordinates(longitude, latitude, zoom):
    scale = 1 << zoom
    x = int((longitude + 180.0) / 360.0 * scale)
    latitude = max(-85.05112878, min(85.05112878, latitude))
    radians = math.radians(latitude)
    y = int(
        (1.0 - math.asinh(math.tan(radians)) / math.pi)
        / 2.0
        * scale
    )
    return x, y


def decode_tile(archive, zoom, x, y):
    result = subprocess.run(
        ["tippecanoe-decode", str(archive), str(zoom), str(x), str(y)],
        check=False,
        capture_output=True,
        text=True,
    )
    if not result.stdout.strip():
        return []

    decoded = json.loads(result.stdout)
    return [
        layer
        for layer in decoded.get("features", [])
        if layer.get("type") == "FeatureCollection"
    ]


def sample_zoom(archive, layer_name, zoom):
    center_x, center_y = tile_coordinates(-60.0, -36.5, zoom)
    layers = []
    for radius in range(0, 4):
        for x in range(center_x - radius, center_x + radius + 1):
            for y in range(center_y - radius, center_y + radius + 1):
                layers.extend(decode_tile(archive, zoom, x, y))
        matching = [
            layer
            for layer in layers
            if layer.get("properties", {}).get("layer") == layer_name
            and layer.get("features")
        ]
        if matching:
            return matching
    fail(f"No features found near the archive center at zoom {zoom}.")


def main():
    if len(sys.argv) != 6:
        fail(
            "Usage: validate_map.py "
            "ARCHIVE LAYER_NAME MIN_ZOOM MAX_ZOOM ATTRIBUTE_SAMPLES"
        )

    archive = Path(sys.argv[1])
    layer_name = sys.argv[2]
    expected_min_zoom = int(sys.argv[3])
    expected_max_zoom = int(sys.argv[4])
    samples_path = Path(sys.argv[5])

    with archive.open("rb") as source:
        header = source.read(127)

    if len(header) != 127 or header[:7] != b"PMTiles":
        fail("The generated archive has an invalid PMTiles header.")
    if header[7] != 3:
        fail(f"Unsupported PMTiles version: {header[7]}.")
    if header[0x63] != 1:
        fail("The generated archive does not contain MVT vector tiles.")
    if header[0x64] != expected_min_zoom or header[0x65] != expected_max_zoom:
        fail(
            "Unexpected zoom range: "
            f"{header[0x64]}-{header[0x65]} "
            f"(expected {expected_min_zoom}-{expected_max_zoom})."
        )

    sampled_layers = []
    for zoom in {
        expected_min_zoom,
        min(6, expected_max_zoom),
        min(10, expected_max_zoom),
        expected_max_zoom,
    }:
        if zoom >= expected_min_zoom:
            sampled_layers.extend(sample_zoom(archive, layer_name, zoom))

    with samples_path.open(encoding="utf-8") as samples_file:
        attribute_samples = json.load(samples_file)

    missing_attributes = []
    for attribute in sorted(REQUIRED_ATTRIBUTES):
        longitude, latitude = attribute_samples[attribute]
        x, y = tile_coordinates(
            longitude,
            latitude,
            expected_max_zoom,
        )
        layers = decode_tile(archive, expected_max_zoom, x, y)
        if not any(
            attribute in feature.get("properties", {})
            for layer in layers
            if layer.get("properties", {}).get("layer") == layer_name
            for feature in layer.get("features", [])
        ):
            missing_attributes.append(attribute)

    if missing_attributes:
        fail(
            "Required application attributes are missing: "
            + ", ".join(missing_attributes)
        )

    print(
        "[SuelosAR GIS] PMTiles validation passed: "
        f"layer={layer_name}, zooms={expected_min_zoom}-{expected_max_zoom}, "
        f"required_attributes={len(REQUIRED_ATTRIBUTES)}."
    )


if __name__ == "__main__":
    main()
