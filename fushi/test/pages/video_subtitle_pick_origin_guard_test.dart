import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_subtitle_pick_origin.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// A subtitle pick made on the second-screen companion's video panel shows its
/// extraction progress on the panel; the player opens its settings sheet only
/// for picks made on the player side (sheet, shortcuts, remote, CLI).
///
/// The decision is [VideoSubtitlePickOrigin.opensPlayerSettings] (unit tests
/// below). media_kit cannot run the real video page headless, so the page's
/// wiring of the origin is checked on the source (same approach as
/// `video_subtitle_loading_overlay_guard_test.dart`).
void main() {
  group('VideoSubtitlePickOrigin.opensPlayerSettings', () {
    test('a player pick opens the sheet on the subtitle category', () {
      expect(
        VideoSubtitlePickOrigin.player.opensPlayerSettings(
          subtitlePanelOpen: false,
        ),
        isTrue,
      );
    });

    test(
      'a player pick with the subtitle category already open: no reopen',
      () {
        expect(
          VideoSubtitlePickOrigin.player.opensPlayerSettings(
            subtitlePanelOpen: true,
          ),
          isFalse,
        );
      },
    );

    test('a companion pick never opens the sheet', () {
      for (final bool open in <bool>[false, true]) {
        expect(
          VideoSubtitlePickOrigin.companion.opensPlayerSettings(
            subtitlePanelOpen: open,
          ),
          isFalse,
        );
      }
    });
  });

  group('video page wiring', () {
    late String src;
    setUpAll(() {
      src = maskComments(readVideoFushiSource());
    });

    String arrowBody(String signature) {
      final int start = src.indexOf(signature);
      expect(start, greaterThan(-1), reason: 'missing $signature');
      return src.substring(start, src.indexOf(');\n', start) + 2);
    }

    test('the loading state opens the sheet only through the origin', () {
      final String body = methodBody(
        src,
        'void _showSubtitleLoadingOverlay({required VideoSubtitlePickOrigin '
        'origin})',
      );
      final int gate = body.indexOf('origin.opensPlayerSettings(');
      final int open = body.indexOf(
        "_showPlayerSettings(initialCategory: 'subtitle')",
      );
      expect(gate, greaterThan(-1));
      expect(open, greaterThan(gate));
      expect(
        body.indexOf('_subtitleLoadingShown = true'),
        lessThan(gate),
        reason: 'the single progress state is set for every origin',
      );
    });

    test('the companion panel picks with the companion origin', () {
      final String body = arrowBody(
        'Future<void> selectSubtitle(String source) =>',
      );
      expect(body, contains('_remote._selectSubtitleFrom('));
      expect(body, contains('origin: VideoSubtitlePickOrigin.companion'));
      expect(
        RegExp(r'VideoSubtitlePickOrigin\.companion').allMatches(src).length,
        1,
        reason: 'only the companion adapter picks as the companion',
      );
    });

    test('remote control / CLI picks keep the player origin', () {
      final String body = arrowBody(
        'Future<void> selectSubtitle(String source, {required bool secondary}) =>',
      );
      expect(body, contains('_selectSubtitleFrom('));
      expect(body, contains('origin: VideoSubtitlePickOrigin.player'));
    });

    test('the origin reaches the local and the streamed-video paths', () {
      final String body = methodBody(src, 'Future<void> _selectSubtitleFrom(');
      expect(
        body,
        contains(
          '_state._selectSubtitleSource(controller, found, origin: origin)',
        ),
      );
      expect(body, contains('origin: origin,'));
      final String local = methodBody(
        src,
        'Future<bool> _selectSubtitleSource(',
      );
      expect(local, contains('_showSubtitleLoadingOverlay(origin: origin);'));
      final String streamed = methodBody(
        src,
        'Future<bool> _applyRemoteSubtitle(',
      );
      expect(
        streamed,
        contains('_showSubtitleLoadingOverlay(origin: origin);'),
      );
      final String embedded = methodBody(
        src,
        'Future<void> _applyRemoteEmbeddedSubtitle(',
      );
      expect(embedded, contains('origin: origin,'));
    });

    test('the companion frame reports the single loading state', () {
      expect(src, contains('subtitleLoading: _state._subtitleLoadingShown,'));
    });
  });
}
