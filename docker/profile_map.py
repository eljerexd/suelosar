#!/usr/bin/env python3

import json
import math
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path


CENTER_LONGITUDE = -60.0
CENTER_LATITUDE = -36.5
LAYER_NAME = os.environ.get("LAYER_NAME", "soil_polygons")
PROFILE_RUNS = int(os.environ.get("PROFILE_RUNS", "3"))


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


def square(zoom, radius):
    center_x, center_y = tile_coordinates(
        CENTER_LONGITUDE,
        CENTER_LATITUDE,
        zoom,
    )
    return [
        (zoom, x, y)
        for x in range(center_x - radius, center_x + radius + 1)
        for y in range(center_y - radius, center_y + radius + 1)
    ]


def entering_pan_column():
    zoom = 6
    center_x, center_y = tile_coordinates(
        CENTER_LONGITUDE,
        CENTER_LATITUDE,
        zoom,
    )
    return [
        (zoom, center_x + 1, y)
        for y in range(center_y - 1, center_y + 2)
    ]


SCENARIOS = {
    "startup_z6_5x5": square(6, 2),
    "pan_new_column_z6": entering_pan_column(),
    "zoom_z8_3x3": square(8, 1),
    "zoom_z9_3x3": square(9, 1),
    "zoom_z10_3x3": square(10, 1),
    "zoom_z11_3x3": square(11, 1),
    "zoom_z12_3x3": square(12, 1),
    "zoom_z13_3x3": square(13, 1),
    "zoom_z14_3x3": square(14, 1),
}


def vertex_count(value):
    if not isinstance(value, list):
        return 0
    if (
        len(value) >= 2
        and isinstance(value[0], (int, float))
        and isinstance(value[1], (int, float))
    ):
        return 1
    return sum(vertex_count(item) for item in value)


def decode_tile(archive, coordinates):
    zoom, x, y = coordinates
    result = subprocess.run(
        [
            "tippecanoe-decode",
            str(archive),
            str(zoom),
            str(x),
            str(y),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if not result.stdout.strip():
        return 0, 0

    decoded = json.loads(result.stdout)
    features = [
        feature
        for layer in decoded.get("features", [])
        if layer.get("type") == "FeatureCollection"
        and layer.get("properties", {}).get("layer") == LAYER_NAME
        for feature in layer.get("features", [])
    ]
    vertices = sum(
        vertex_count(feature.get("geometry", {}).get("coordinates"))
        for feature in features
    )
    return len(features), vertices


def percentile(values, percentile_value):
    if not values:
        return 0
    ordered = sorted(values)
    index = math.ceil(percentile_value / 100.0 * len(ordered)) - 1
    return ordered[max(0, index)]


def profile_scenario(archive, coordinates):
    durations = []
    feature_counts = []
    vertex_counts = []

    for run in range(PROFILE_RUNS):
        run_features = []
        run_vertices = []
        started = time.perf_counter()
        for coordinate in coordinates:
            features, vertices = decode_tile(archive, coordinate)
            run_features.append(features)
            run_vertices.append(vertices)
        durations.append((time.perf_counter() - started) * 1000.0)
        if run == 0:
            feature_counts = run_features
            vertex_counts = run_vertices

    return {
        "tiles": len(coordinates),
        "populated_tiles": sum(count > 0 for count in feature_counts),
        "decode_ms": statistics.median(durations),
        "total_features": sum(feature_counts),
        "features_per_tile": statistics.mean(feature_counts),
        "features_p95": percentile(feature_counts, 95),
        "features_max": max(feature_counts, default=0),
        "total_vertices": sum(vertex_counts),
        "vertices_per_tile": statistics.mean(vertex_counts),
        "vertices_p95": percentile(vertex_counts, 95),
        "vertices_max": max(vertex_counts, default=0),
    }


def profile_archive(archive):
    if not archive.is_file():
        raise SystemExit(f"Archive not found: {archive}")

    decode_tile(archive, next(iter(SCENARIOS["startup_z6_5x5"])))
    return {
        "path": str(archive),
        "size_bytes": archive.stat().st_size,
        "scenarios": {
            name: profile_scenario(archive, coordinates)
            for name, coordinates in SCENARIOS.items()
        },
    }


def percentage_change(baseline, candidate):
    if baseline == 0:
        return 0.0
    return (candidate - baseline) / baseline * 100.0


def print_report(baseline, candidate):
    baseline_size = baseline["size_bytes"] / 1024.0 / 1024.0
    candidate_size = candidate["size_bytes"] / 1024.0 / 1024.0
    size_change = percentage_change(
        baseline["size_bytes"],
        candidate["size_bytes"],
    )

    print("# SuelosAR PMTiles profile")
    print()
    print(f"- Runs per scenario: {PROFILE_RUNS} (median reported)")
    print(f"- Baseline: `{baseline['path']}`")
    print(f"- Candidate: `{candidate['path']}`")
    print()
    print("| Metric | Baseline | Candidate | Change |")
    print("| --- | ---: | ---: | ---: |")
    print(
        f"| File size | {baseline_size:.2f} MiB | "
        f"{candidate_size:.2f} MiB | {size_change:+.1f}% |"
    )

    for name in SCENARIOS:
        before = baseline["scenarios"][name]
        after = candidate["scenarios"][name]
        print(
            f"| {name}: decode | {before['decode_ms']:.1f} ms | "
            f"{after['decode_ms']:.1f} ms | "
            f"{percentage_change(before['decode_ms'], after['decode_ms']):+.1f}% |"
        )
        print(
            f"| {name}: features/tile | "
            f"{before['features_per_tile']:.1f} | "
            f"{after['features_per_tile']:.1f} | "
            f"{percentage_change(before['features_per_tile'], after['features_per_tile']):+.1f}% |"
        )
        print(
            f"| {name}: vertices/tile | "
            f"{before['vertices_per_tile']:.1f} | "
            f"{after['vertices_per_tile']:.1f} | "
            f"{percentage_change(before['vertices_per_tile'], after['vertices_per_tile']):+.1f}% |"
        )

    print()
    print("Raw metrics:")
    print("```json")
    print(
        json.dumps(
            {"baseline": baseline, "candidate": candidate},
            indent=2,
            ensure_ascii=False,
        )
    )
    print("```")


def main():
    if len(sys.argv) != 3:
        raise SystemExit(
            "Usage: profile_map.py BASELINE.pmtiles CANDIDATE.pmtiles"
        )

    baseline = profile_archive(Path(sys.argv[1]))
    candidate = profile_archive(Path(sys.argv[2]))
    print_report(baseline, candidate)


if __name__ == "__main__":
    main()
