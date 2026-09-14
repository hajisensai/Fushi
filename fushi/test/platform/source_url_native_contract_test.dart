import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

void main() {
  test(
    'Android routes source links to the existing singleTask main activity',
    () {
      final XmlDocument manifest = XmlDocument.parse(
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
      );
      final XmlElement main = manifest
          .findAllElements('activity')
          .singleWhere(
            (XmlElement node) =>
                node.getAttribute('android:name') == '.MainActivity',
          );
      expect(main.getAttribute('android:launchMode'), 'singleTask');
      expect(
        main
            .findElements('meta-data')
            .singleWhere(
              (XmlElement node) =>
                  node.getAttribute('android:name') ==
                  'flutter_deeplinking_enabled',
            )
            .getAttribute('android:value'),
        'false',
      );
      final XmlElement sourceFilter = main
          .findElements('intent-filter')
          .singleWhere(
            (XmlElement filter) => filter
                .findElements('data')
                .any(
                  (XmlElement data) =>
                      data.getAttribute('android:scheme') == 'fushi' &&
                      data.getAttribute('android:host') == 'source',
                ),
          );
      expect(
        sourceFilter.findElements('action').single.getAttribute('android:name'),
        'android.intent.action.VIEW',
      );
      expect(
        sourceFilter
            .findElements('category')
            .map((XmlElement node) => node.getAttribute('android:name')),
        containsAll(<String>[
          'android.intent.category.DEFAULT',
          'android.intent.category.BROWSABLE',
        ]),
      );
    },
  );

  test(
    'macOS registers the scheme and queues links until one listener is ready',
    () {
      final String plist = File('macos/Runner/Info.plist').readAsStringSync();
      XmlDocument.parse(plist);
      expect(plist, contains('<key>CFBundleURLSchemes</key>'));
      expect(plist, contains('<string>fushi</string>'));
      final String delegate = File(
        'macos/Runner/AppDelegate.swift',
      ).readAsStringSync();
      expect(delegate, contains('open urls: [URL]'));
      expect(delegate, contains('app.fushi.reader/source_urls/stream'));
      expect(delegate, contains('sourceUrlChannel.setStreamHandler(self)'));
      expect(
        delegate,
        contains('pendingSourceUrls.append(url.absoluteString)'),
      );
      expect(delegate, contains('let pending = pendingSourceUrls'));
      expect(delegate, contains('pendingSourceUrls.removeAll()'));
      expect(
        delegate,
        contains('super.application(application, open: remainingUrls)'),
      );
      expect(delegate, contains('sourceUrlEventSink = nil'));
    },
  );

  test(
    'iOS keeps its shared callback channel for cold and warm source links',
    () {
      final String plist = File('ios/Runner/Info.plist').readAsStringSync();
      XmlDocument.parse(plist);
      // 只有一处声明（BUG-2456 那条）；同名 key 出现两次 plist 会取哪条由 CFPropertyList
      // 决定，守卫不能靠缩进猜位置。
      expect(
        RegExp(
          r'<key>FlutterDeepLinkingEnabled</key>\s*<false\s*/>',
        ).allMatches(plist).length,
        1,
      );
      final String delegate = File(
        'ios/Runner/AppDelegate.swift',
      ).readAsStringSync();
      final String scene = File(
        'ios/Runner/SceneDelegate.swift',
      ).readAsStringSync();
      expect(delegate, contains('app.fushi.reader/url_events/stream'));
      expect(delegate, contains('func deliverUrl(_ url: String)'));
      expect(scene, contains('connectionOptions.urlContexts'));
      expect(
        scene,
        contains('openURLContexts URLContexts: Set<UIOpenURLContext>'),
      );
      expect(scene, contains('?.deliverUrl(url.absoluteString)'));
      expect(
        delegate,
        isNot(contains('source_urls/stream')),
        reason: 'A second iOS consumer could steal AnkiMobile callbacks.',
      );
    },
  );

  test('Android source lookup validates the UUID and fails closed (BUG-2527)',
      () {
    final String handler = File(
      'android/app/src/main/java/app/fushi/reader/AnkiChannelHandler.java',
    ).readAsStringSync();
    expect(handler, contains('case "findNotesBySourceId":'));
    expect(handler, contains('sourceId.matches(SOURCE_ID_PATTERN)'));
    expect(
      handler,
      contains(
        r'"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"',
      ),
    );
    // The redundant marker tag is gone: no tag query, no tag emission.
    expect(handler, isNot(contains('fushi_source_')));
    expect(handler, isNot(contains('findNotesBySourceMarker')));
    final int start = handler.indexOf(
      'private List<Long> findNotesBySourceId(',
    );
    expect(start, greaterThan(-1));
    final String body = handler.substring(
      start,
      handler.indexOf('private boolean openNote(', start),
    );
    expect(
      body,
      contains('target.rebase(FlashCardsContract.Note.CONTENT_URI)'),
    );
    // Same query literal as CardSourceLink.searchQueryForSourceId.
    expect(body, contains('"sourceId=" + sourceId'));
    expect(body, contains('getColumnIndexOrThrow'));
    expect(body, contains('if (cursor == null)'));
    expect(body, contains('throw new IllegalStateException'));
  });
}
