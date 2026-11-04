import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/platform/home_widgets/home_widget_link.dart';
import 'package:fushi/src/platform/source_url_channel.dart';

void main() {
  group('HomeWidgetLink.tryParse', () {
    test('recognises every widget link and round-trips its url', () {
      const List<HomeWidgetLink> links = <HomeWidgetLink>[
        HomeWidgetReviewLink(),
        HomeWidgetStatsLink(),
        HomeWidgetCameraLookupLink(),
        HomeWidgetClipboardLookupLink(),
        HomeWidgetResumeAudiobookLink(),
      ];
      for (final HomeWidgetLink link in links) {
        final HomeWidgetLink? parsed = HomeWidgetLink.tryParse(link.url);
        expect(parsed, isNotNull, reason: link.url);
        expect(parsed!.runtimeType, link.runtimeType, reason: link.url);
        expect(parsed.url, link.url);
      }
    });

    test('continue keys survive encoding, including / and |', () {
      for (final String key in <String>[
        'book:reader_fushi/42',
        'video:5c1f-uid',
        'game:7',
        'server:audiobookshelf|srv-1|item 9',
      ]) {
        final String url = HomeWidgetContinueLink(key).url;
        final HomeWidgetLink? parsed = HomeWidgetLink.tryParse(url);
        expect(parsed, isA<HomeWidgetContinueLink>(), reason: url);
        expect((parsed! as HomeWidgetContinueLink).key, key);
      }
    });

    test('leaves links it does not own to the other handlers', () {
      for (final String? url in <String?>[
        null,
        '',
        'https://srs/review',
        'fushi://shortcut/lookup',
        'fushi://lookup?word=猫',
        'fushi://source/install?url=x',
        'fushi://srs',
        'fushi://srs/review/extra',
        'fushi://stats/today',
        'fushi://continue',
        'fushi://widget/unknown',
      ]) {
        expect(HomeWidgetLink.tryParse(url), isNull, reason: url);
      }
    });
  });

  test('macOS url channel forwards every host the widgets use', () {
    for (final String url in <String>[
      const HomeWidgetReviewLink().url,
      const HomeWidgetStatsLink().url,
      const HomeWidgetContinueLink('book:1').url,
      const HomeWidgetCameraLookupLink().url,
      'fushi://shortcut/lookup',
    ]) {
      expect(SourceUrlChannel.isRoutedUrl(url), isTrue, reason: url);
    }
    expect(SourceUrlChannel.isRoutedUrl('fushi://somethingelse'), isFalse);
  });
}
