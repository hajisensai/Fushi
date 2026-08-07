import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi/media.dart';
import 'package:fushi/pages.dart';
import 'package:fushi_core/fushi_core.dart';

class _TestMediaSource extends MediaSource {
  _TestMediaSource()
      : super(
          uniqueKey: 'test_source',
          sourceName: 'Test Source',
          description: 'Test source',
          mediaType: ReaderMediaType.instance,
          icon: Icons.article,
          implementsSearch: false,
          implementsHistory: false,
        );

  @override
  double get aspectRatio => 1;

  @override
  BasePage buildHistoryPage({Widget? navigation}) {
    return const _TestPage();
  }

  @override
  Widget buildLaunchPage({MediaItem? item, Bookmark? initialBookmarkJump}) {
    return const SizedBox.shrink();
  }
}

class _TestPage extends BasePage {
  const _TestPage();

  @override
  BasePageState createState() => _TestPageState();
}

class _TestPageState extends BasePageState {
  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}

void main() {
  test('reading a missing default preference does not write through to DB',
      () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    MediaSource.setDatabase(db);
    final _TestMediaSource source = _TestMediaSource();
    await source.initialise();

    expect(
      source.getPreference<int>(key: 'example_default', defaultValue: 7),
      7,
    );

    final Map<String, String> prefs = await db.getAllPrefs();
    expect(
      prefs.containsKey('src:test_source:example_default'),
      isFalse,
      reason: 'a synchronous preference read must not start an unawaitable '
          'database write that can race with source shutdown or test cleanup',
    );
  });

  test('setPreference still writes explicit user changes to DB', () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    MediaSource.setDatabase(db);
    final _TestMediaSource source = _TestMediaSource();
    await source.initialise();

    await source.setPreference<int>(key: 'example_default', value: 9);

    final Map<String, String> prefs = await db.getAllPrefs();
    expect(prefs['src:test_source:example_default'], 'i:9');
  });
}
