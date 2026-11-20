// BUG-4919（反馈 wRNmmoL4lT）：「已移除的曲目」页正文顶端被页头盖住。
//
// 页头大字外壳（[FushiMastheadScaffold]）把页头高度经 `MediaQuery` 顶部 padding 注入
// 正文；正文留白（`musicBrowsePagePadding`）必须用脚手架之下的 context 量。旧写法在
// 脚手架之上量，少了页头高度，提示文字与第一行曲目被页头压住。
// `musicBrowseScaffold` 的正文改成构建器后，结构上拿不到脚手架之上的 context。

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart' show EventChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/apple_music/apple_music_native_bridge.dart'
    show kAppleMusicNativeEventChannel;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/music/music_track_list.dart'
    show MusicHiddenTracksPage;
import 'package:fushi/src/utils/components/fushi_masthead_scaffold.dart'
    show FushiMastheadHeader;
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_platform_services.dart';

MusicTracksCompanion _track(String uid) => MusicTracksCompanion.insert(
  trackUid: uid,
  path: '/music/$uid.flac',
  title: 'title-$uid',
  sourceId: const Value<int?>(null),
  fileMtimeAt: 1,
  fileSize: 1,
  addedAt: 1,
);

/// 让真 IO（内存库的 watch 查询）在真时钟里落地，再把帧推平。
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 3; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
  }
}

void main() {
  // 宿主是 macOS 14+ 时 Apple Music 走原生桥，flutter test 里没有插件：给事件通道一个
  // 不发事件的桩（同 music_sources_pages_test）。
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel(kAppleMusicNativeEventChannel),
          MockStreamHandler.inline(
            onListen: (Object? _, MockStreamHandlerEventSink __) {},
          ),
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel(kAppleMusicNativeEventChannel),
          null,
        );
  });

  testWidgets('已移除的曲目：提示与第一行曲目都排在页头下沿之下', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1200);
    addTearDown(tester.view.reset);

    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await tester.runAsync(() async {
      await prefs.loadFromDb();
      await db.writeMusicScanBatch(
        MusicScanBatchWrite(
          tracks: <MusicTracksCompanion>[_track('t1'), _track('t2')],
          albums: const <MusicAlbumsCompanion>[],
          artists: const <MusicArtistsCompanion>[],
          credits: const <MusicTrackCreditsCompanion>[],
        ),
      );
      await db.hideMusicTracks(<String>['t1', 't2'], at: 7);
    });
    final AppModel app = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(
        prefsRepo: prefs,
        databaseDirectory: Directory.systemTemp,
      )
      ..wireDatabaseForTesting(db);

    LocaleSettings.setLocale(AppLocale.en);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appProvider.overrideWith((Ref ref) => app)],
        child: TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(useMaterial3: true),
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: const MusicHiddenTracksPage(),
          ),
        ),
      ),
    );
    await _settle(tester);

    final double headerBottom = tester
        .getRect(find.byType(FushiMastheadHeader))
        .bottom;
    expect(headerBottom, greaterThan(0));
    expect(
      tester.getRect(find.text(t.music_hidden_tracks_hint)).top,
      greaterThanOrEqualTo(headerBottom),
      reason: '正文第一块（提示）不能被页头盖住',
    );
    expect(
      tester.getRect(find.byKey(const ValueKey<String>('music-hidden-t1'))).top,
      greaterThan(headerBottom),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
