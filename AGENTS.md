# AGENTS.md

# SuelosAR — AI Development Guidelines

## Project Overview

SuelosAR is a professional offline Geographic Information System (GIS) for consulting the official INTA Soil Maps of Argentina.

The application is designed for:

- Agronomists
- Agricultural engineers
- Students
- Researchers
- Field technicians

The application must always prioritize:

1. Offline operation.
2. Stability.
3. Rendering performance.
4. Geographic accuracy.
5. Clean architecture.

Performance is more important than adding new features quickly.

---

# Current State

The GIS engine is considered stable.

Implemented:

- Offline PMTiles renderer
- Vector Tile (MVT) decoding
- Tile cache
- Background isolate decoding
- Tile memoization
- Spatial hit testing
- Polygon selection
- PDF integration
- Docker map generation pipeline
- Multi-level LOD optimization
- Rendering optimizations

These systems should be considered production-ready.

---

# Core Rule

Do NOT modify the GIS engine unless absolutely necessary.

The following components are considered stable:

- PMTiles loading
- Tile cache
- Renderer
- Polygon generation
- Tile memoization
- Hit testing
- LOD generation
- Docker pipeline

New features should integrate around the engine, not rewrite it.

---

# Development Philosophy

Implement one feature at a time.

Never mix multiple unrelated changes.

Avoid large refactors.

Small isolated changes are always preferred.

---

# Offline First

Everything must work without Internet.

Never introduce mandatory online services.

If online functionality is added in the future it must always be optional.

---

# Performance

Maintain current rendering performance.

Avoid:

- rebuilding FlutterMap
- decoding tiles twice
- unnecessary allocations
- unnecessary repaints
- unnecessary polygon recreation

Performance regressions are considered bugs.

---

# UI Rules

Do not redesign the interface unless explicitly requested.

Respect the existing user experience.

Keep the application simple and professional.

---

# GIS Rules

Soil polygons are always the primary information.

Reference maps must never compete visually with soil polygons.

Reference layers:

- must stay behind polygons
- must never participate in hit testing
- must have negligible performance cost

---

# GPS

GPS must be independent of the GIS engine.

Never change the renderer to implement GPS.

Location should only:

- obtain position
- center the map
- optionally select the polygon

Nothing else.

---

# Architecture

Keep responsibilities separated.

Example:

lib/

constants/
data/
gis/
models/
screens/
services/
widgets/

Business logic does not belong inside main.dart.

---

# Before Modifying Code

Always understand:

- why the code exists
- what problem it solves
- whether it is already optimized

Do not replace optimized code without evidence.

---

# Regression Policy

If a new feature breaks existing behavior:

1. Restore the previous working behavior.
2. Identify the root cause.
3. Reimplement using the smallest possible change.

Never solve regressions with large refactors.

---

# Validation

Every task must finish with:

flutter analyze

flutter test

If UI or GIS changed:

Run the real application and verify manually.

Do not rely only on automated tests.
Development policy

For small UI-only changes:

- Run flutter analyze.
- Run flutter test.
- Do NOT launch the Windows application.

Launch the Windows application only when changes affect:

- map rendering;
- FlutterMap;
- GPS;
- animations;
- hit testing;
- PMTiles;
- platform-specific behavior.

This policy reduces development time and unnecessary resource usage.

---

# Feature Development Order

Priority:

1. Stability
2. Performance
3. Offline functionality
4. GIS tools
5. User experience
6. New features

---

# Coding Style

Keep code:

- readable
- modular
- documented
- reusable

Avoid duplicated logic.

Avoid unnecessary abstractions.

Prefer explicit code over clever code.

---

# When Unsure

Stop.

Explain the uncertainty.

Ask before making architectural changes.

Never guess architectural decisions.

---

# Goal

Build the best offline soil GIS application for Argentina.

Every decision should move the project toward a stable, professional, long-term tool suitable for daily field work.
The PMTiles generation pipeline is considered stable. Do not modify it unless explicitly requested or fixing a verified bug.