# PMTiles LOD performance profile

Profile date: 2026-06-29

Source: `docker/input/Suelos_BA_50mil_V2.shp` (2,274 validated features)

The same Docker image and `tippecanoe-decode` binary were used for both
archives. Each workload was warmed once and executed three times; the table
reports the median. Decode times are a repeatable pipeline proxy, not Flutter
frame timings.

| Workload | Metric | Previous | LOD | Change |
| --- | --- | ---: | ---: | ---: |
| Archive | File size | 218.84 MiB | 187.21 MiB | -14.5% |
| Startup, z6 5x5 | Decode time | 7,729.2 ms | 694.5 ms | -91.0% |
| Startup, z6 5x5 | Features/tile | 351.4 | 86.5 | -75.4% |
| Startup, z6 5x5 | Vertices/tile | 208,884.8 | 2,970.0 | -98.6% |
| Pan, new z6 column | Decode time | 1,539.1 ms | 79.5 ms | -94.8% |
| Pan, new z6 column | Features/tile | 699.0 | 90.0 | -87.1% |
| Pan, new z6 column | Vertices/tile | 381,561.0 | 1,277.0 | -99.7% |
| Zoom z8, 3x3 | Decode time | 2,303.4 ms | 490.0 ms | -78.7% |
| Zoom z8, 3x3 | Vertices/tile | 216,775.8 | 26,833.8 | -87.6% |
| Zoom z10, 3x3 | Decode time | 549.1 ms | 291.7 ms | -46.9% |
| Zoom z10, 3x3 | Vertices/tile | 40,192.6 | 8,204.4 | -79.6% |
| Zoom z12, 3x3 | Features/tile | 9.1 | 9.1 | 0.0% |
| Zoom z12, 3x3 | Vertices/tile | 2,386.1 | 2,386.3 | 0.0% |
| Zoom z14, 3x3 | Features/tile | 3.2 | 3.2 | 0.0% |
| Zoom z14, 3x3 | Vertices/tile | 188.7 | 208.0 | +10.2% |

At z8 the LOD archive retains 10% more features than the previous archive
while reducing vertices by 87.6%. The earlier global tile-size fallback had
discarded more features; tier-specific simplification now keeps them within the
medium-LOD budget.

At z12 feature density and geometry are effectively unchanged. At z14 the LOD
archive retains the same features and 10.2% more vertices because maximum zoom
uses unsimplified source geometry.

## Medium-to-high transition profile

Profile date: 2026-06-29

This comparison uses the previous three-tier LOD archive as the baseline and
the four-tier archive as the candidate.

| Zoom | Metric | Previous | Four-tier LOD | Change |
| --- | --- | ---: | ---: | ---: |
| z8 | Decode time | 505.4 ms | 343.1 ms | -32.1% |
| z8 | Features/tile | 108.8 | 54.6 | -49.8% |
| z8 | Vertices/tile | 26,833.8 | 12,263.6 | -54.3% |
| z9 | Decode time | 449.0 ms | 333.4 ms | -25.8% |
| z9 | Features/tile | 66.6 | 35.1 | -47.2% |
| z9 | Vertices/tile | 21,629.6 | 10,709.0 | -50.5% |
| z10 | Decode time | 305.6 ms | 301.4 ms | -1.4% |
| z10 | Features/tile | 28.1 | 28.1 | 0.0% |
| z10 | Vertices/tile | 8,204.4 | 8,204.4 | 0.0% |
| z11 | Decode time | 281.1 ms | 276.4 ms | -1.7% |
| z11 | Features/tile | 15.8 | 15.8 | 0.0% |
| z11 | Vertices/tile | 4,854.9 | 4,854.9 | 0.0% |
| z12 | Decode time | 269.4 ms | 252.7 ms | -6.2% |
| z13 | Features/tile | 5.9 | 5.9 | 0.0% |
| z14 | Features/tile | 3.2 | 3.2 | 0.0% |
| z14 | Vertices/tile | 208.0 | 208.0 | 0.0% |

The archive size changed from 187.21 MiB to 185.66 MiB (-0.8%). Density
reduction is confined to z8-z9. The intermediate tier keeps feature density
unchanged, and the high tier contains unsimplified source geometry.
