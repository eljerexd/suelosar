import 'package:flutter_test/flutter_test.dart';
import 'package:suelosar/gis/map_coverage.dart';

/// Regression test for the province boundary/shadow visibility bug: the
/// on-demand download banner's boundary highlight was gated by the exact
/// same single-anchor-point check used to position/show its download card
/// (`_ProvincePmtilesBanner.isCoverageVisible`, checking only whether one
/// fixed point -- Rafaela for Santa Fe, Bolívar for Buenos Aires -- projects
/// inside the screen). That meant the outline only appeared once that one
/// point happened to be on screen (e.g. after panning towards it), even
/// though the province itself could already be substantially visible.
///
/// The fix (`_ProvincePmtilesBanner._isProvinceBoundsVisible`) instead
/// checks whether the camera's visible geographic area overlaps the
/// province's real bounds ([MapCoverage.bounds]) at all -- exactly the same
/// rectangle-overlap test [GeoBounds.intersects] already uses elsewhere in
/// this codebase (`MultiCoverageRepository`'s own tile routing). Both
/// methods are private to `gis_map_screen.dart` and can't be called
/// directly from a test in a different library, so this instead proves the
/// geometric contract they're built on, against each province's real,
/// production bounds: a viewport that does NOT contain the anchor point can
/// still genuinely overlap the province (so the boundary must be able to
/// show without the anchor point being on screen), and a viewport that
/// contains the anchor point trivially always overlaps too.
void main() {
  group('province boundary visibility must not depend on a single anchor point', () {
    test('Buenos Aires: a viewport overlapping only the province\'s edge, '
        'far from its anchor point (Bolívar), still counts as visible', () {
      final bounds = MapCoverage.buenosAires.bounds;
      const bolivar = (lat: -36.2333, lon: -61.1167);

      // A narrow viewport hugging the province's own northeastern corner --
      // nowhere near Bolívar, which sits well to the southwest of it.
      final farCornerViewport = GeoBounds(
        minLatitude: bounds.maxLatitude - 0.5,
        maxLatitude: bounds.maxLatitude + 0.5,
        minLongitude: bounds.maxLongitude - 0.5,
        maxLongitude: bounds.maxLongitude + 0.5,
      );

      expect(
        farCornerViewport.containsPoint(bolivar.lat, bolivar.lon),
        isFalse,
        reason: 'this viewport must not contain the anchor point, or the '
            'test proves nothing new',
      );
      expect(
        farCornerViewport.intersects(bounds),
        isTrue,
        reason: 'the province genuinely overlaps this viewport, so its '
            'boundary must be able to render even though the anchor point '
            'is off-screen',
      );
    });

    test('Santa Fe: a viewport overlapping only the province\'s edge, far '
        'from its anchor point (Rafaela), still counts as visible', () {
      final bounds = MapCoverage.santaFe.bounds;
      const rafaela = (lat: -31.2503, lon: -61.4867);

      final farCornerViewport = GeoBounds(
        minLatitude: bounds.minLatitude - 0.5,
        maxLatitude: bounds.minLatitude + 0.5,
        minLongitude: bounds.minLongitude - 0.5,
        maxLongitude: bounds.minLongitude + 0.5,
      );

      expect(
        farCornerViewport.containsPoint(rafaela.lat, rafaela.lon),
        isFalse,
        reason: 'this viewport must not contain the anchor point, or the '
            'test proves nothing new',
      );
      expect(
        farCornerViewport.intersects(bounds),
        isTrue,
        reason: 'the province genuinely overlaps this viewport, so its '
            'boundary must be able to render even though the anchor point '
            'is off-screen',
      );
    });

    test('zooming out (a larger viewport around the same center) never '
        'stops a currently-visible province from overlapping', () {
      for (final coverage in [MapCoverage.buenosAires, MapCoverage.santaFe]) {
        final bounds = coverage.bounds;
        final centerLat = (bounds.minLatitude + bounds.maxLatitude) / 2;
        final centerLon = (bounds.minLongitude + bounds.maxLongitude) / 2;

        // A small viewport centered on the province (clearly overlapping),
        // then progressively larger ones simulating zooming out -- every
        // one of them must still overlap, since a bigger viewport around a
        // point that was already inside the province can only ever contain
        // more of it, never less.
        for (final halfSpan in [0.5, 2.0, 8.0, 32.0, 128.0]) {
          final viewport = GeoBounds(
            minLatitude: centerLat - halfSpan,
            maxLatitude: centerLat + halfSpan,
            minLongitude: centerLon - halfSpan,
            maxLongitude: centerLon + halfSpan,
          );
          expect(
            viewport.intersects(bounds),
            isTrue,
            reason:
                '${coverage.id}: a ${halfSpan * 2}°-wide viewport centered '
                'inside the province must still overlap it -- zooming out '
                'must never hide an already-visible province\'s boundary',
          );
        }
      }
    });

    test('a viewport genuinely far from both provinces does not overlap '
        '(the boundary correctly disappears once truly off-screen)', () {
      // Somewhere in the middle of the Pacific -- nowhere near either
      // province's real extent.
      const farAway = GeoBounds(
        minLatitude: 10,
        maxLatitude: 12,
        minLongitude: -150,
        maxLongitude: -148,
      );
      expect(farAway.intersects(MapCoverage.buenosAires.bounds), isFalse);
      expect(farAway.intersects(MapCoverage.santaFe.bounds), isFalse);
    });
  });
}
