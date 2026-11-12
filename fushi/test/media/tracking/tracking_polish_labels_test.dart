import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/tracking/page/tracking_page_rows.dart';
import 'package:fushi/src/media/tracking/page/tracking_row_facts.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_labels.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:material_ui/material_ui.dart';

/// T1 F11 c / F13 / F20: labels a user of any site sees.
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  test('T1 F20: a finished volume reads as finished in Fushi, not as the '
      'series finished', () {
    MediaTrackingActivityRow row({required bool completed}) =>
        MediaTrackingActivityRow(
          id: 1,
          provider: 'mangabaka',
          mediaType: 'book',
          mediaKey: 'k',
          mediaTitle: 'Ajin 02',
          kind: 'manga',
          progressMode: 'volume',
          progress: 2,
          completed: completed,
          ok: true,
          createdAt: 0,
        );
    final String finished = trackingActivitySentLabel(row(completed: true));
    expect(finished, contains('2'));
    expect(finished, endsWith('finished in Fushi'));
    expect(
      trackingActivitySentLabel(row(completed: false)),
      isNot(contains('finished')),
    );
  });

  test('a game is named, not shown as its raw value', () {
    expect(trackingPluginKindLabel(TrackingKind.game), t.media_tracking_game);
    expect(t.media_tracking_game, isNot('game'));
  });

  testWidgets('an ignored media server season says "Whole season"', (
    WidgetTester tester,
  ) async {
    Future<void> pumpRow(String type) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TrackingIgnoredRow(
            row: MediaTrackingIgnoredRow(
              id: 1,
              mediaType: type,
              mediaKey: 'k',
              mediaTitle: 'As Promised S1',
              kind: 'anime',
              createdAt: 0,
            ),
            names: (
              title: 'As Promised',
              rawName: 'As Promised S1',
              rowKind: TrackingRowKind.video,
            ),
            index: 0,
            count: 1,
            onTrackAgain: () {},
          ),
        ),
      ),
    );
    await pumpRow(TrackingMediaType.remoteSeries.value);
    await tester.pump(const Duration(seconds: 1));
    expect(
      find.textContaining(t.media_tracking_ignore_whole_season),
      findsOneWidget,
    );
    expect(
      find.textContaining(t.media_tracking_ignore_whole_series),
      findsNothing,
    );
    await pumpRow(TrackingMediaType.videoCollection.value);
    await tester.pump(const Duration(seconds: 1));
    expect(
      find.textContaining(t.media_tracking_ignore_whole_series),
      findsOneWidget,
    );
  });
}
