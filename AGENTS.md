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

# GIS Engine Migration Status

The project has started evaluating a migration of the GIS rendering
engine away from flutter_map (migration candidate: MapLibre). This is a
staged, reversible process — not a decision that flutter_map will
definitely be replaced on any fixed timeline.

Until this section says otherwise:

- flutter_map must NOT be assumed to be the permanent rendering engine.
  Do not write new code, tests, or documentation that assumes flutter_map
  is a long-term architectural decision.
- flutter_map must also NOT be removed or replaced outside of the staged
  plan below. It remains the production engine until an alternative is
  fully validated.
- `gis_repository.dart` remains fully protected under the Core Rule
  below. It is the data layer (PMTiles + MVT decoding + cache) and is
  already independent of the rendering engine, which is exactly why it
  does not need to change for this migration.
- Any GIS architecture change must go through the stages listed here, in
  order, without skipping stages.
- Before modifying the rendering engine, the current migration plan must
  be respected. Do not start engine-replacement work without explicitly
  being in Stage 3 or later.
- Each stage must be safe and reversible: it must be possible to abandon
  a stage and return to the previous known-good state without data loss
  or broken functionality.
- The current engine must keep working end-to-end until a validated
  alternative exists. No stage may leave the app without a functional
  map.

## Migration Stages

**ETAPA 0 — Contexto**
Update agent-facing documentation (this file and CLAUDE.md) so agents
stop assuming flutter_map is permanent, and record the staged plan. No
application code changes.

**ETAPA 1 — Investigación técnica y validación experimental, cero cambios en la app**
Research the candidate engine and validate it practically in an isolated
Flutter project, separate from the SuelosAR project, using the real
SuelosAR PMTiles file (`assets/maps/soil_polygons.pmtiles`). This stage
must verify:

- loading of the real PMTiles file;
- MVT support;
- performance with the real data volume;
- `queryRenderedFeatures` or an equivalent hit-testing/query mechanism;
- attribute retrieval;
- feasibility of reproducing per-series polygon coloring;
- support for the target platforms.

No dependencies are added to the SuelosAR project, and no code in the
SuelosAR project is touched. The isolated experimental project is
separate from SuelosAR.

**ETAPA 2 — Separar UI del motor**
Introduce an abstraction boundary between the GIS screen's UI/business
logic and the concrete rendering engine (flutter_map today), so the
engine becomes swappable behind an interface. This stage touches
`gis_map_screen.dart` and related UI files, but keeps flutter_map as the
only implementation behind the new interface — behavior must not change.

**ETAPA 3 — Implementación paralela**
Build an alternative engine implementation behind the interface from
Etapa 2, without wiring it up as the default. Both implementations exist
side by side; the app keeps shipping with flutter_map by default.

**ETAPA 4 — Comparación y migración de hit-testing/atributos**
Validate the alternative implementation against the current one:
rendering fidelity, hit-testing/selection behavior, attribute/metadata
handling, performance. Port hit-testing and attribute handling to the
new engine only once parity is demonstrated.

**ETAPA 5 — Corte**
Switch the default engine over, only after Etapa 4 validation is
complete and explicitly approved. Keep a rollback path until the new
engine has proven itself in production use.

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

Note: this rule is being revisited specifically for the rendering engine
under the staged GIS Engine Migration plan above. `gis_repository.dart`,
tile cache, PMTiles loading, MVT decoding, and the Docker pipeline remain
fully stable and protected regardless of migration stage.

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