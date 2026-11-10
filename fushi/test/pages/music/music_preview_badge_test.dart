// Apple Music 试听标记（反馈 okvRZINcQU）：未接整曲时曲目只是约 30 秒的预览片段——
// 来源 / 播放项打「试听」标记，播放进度以媒体实际长度为准，不再拿整首时长画进度条。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_session.dart'
    show musicMediaSessionDuration;
import 'package:fushi/src/media/music/server/music_servers.dart';
import 'package:fushi/src/pages/implementations/music/music_preview_badge.dart';
import 'package:fushi_engine/media/music/apple_music/apple_music_catalog_client.dart';
import 'package:fushi_engine/media/music/apple_music/apple_music_token_source.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

http.Response _json(Object body) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

/// 搜索回一首既有试听、又可整曲串流的歌（整首 200 秒）。
AppleMusicCatalogClient _catalog({required bool fullTracks}) =>
    AppleMusicCatalogClient(
      tokens: AppleMusicTokenSource(
        client: MockClient(
          (http.Request r) async =>
              _json(<String, Object?>{'token': 'tok', 'expiresAt': 1 << 50}),
        ),
      ),
      storefront: 'jp',
      fullTracks: fullTracks,
      client: MockClient(
        (http.Request r) async => _json(<String, Object?>{
          'results': <String, Object?>{
            'songs': <String, Object?>{
              'data': <Object?>[
                <String, Object?>{
                  'id': '1',
                  'type': 'songs',
                  'attributes': <String, Object?>{
                    'name': 'Song',
                    'artistName': 'YOASOBI',
                    'durationInMillis': 200000,
                    'previews': <Object?>[
                      <String, Object?>{'url': 'https://audio.example/1.m4a'},
                    ],
                    'playParams': <String, Object?>{'id': '1', 'kind': 'song'},
                  },
                },
              ],
            },
          },
        }),
      ),
    );

/// 不是 Apple Music 的服务器（其余成员测试里不会被调用）。
class _OtherServer implements MusicServerBrowser {
  @override
  MusicServerKind get kind => MusicServerKind.subsonic;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('判据', () {
    test('只有未接整曲的 Apple Music catalog 算「只能试听」', () {
      expect(musicServerPreviewOnly(_catalog(fullTracks: false)), isTrue);
      expect(musicServerPreviewOnly(_catalog(fullTracks: true)), isFalse);
      expect(musicServerPreviewOnly(_OtherServer()), isFalse);
    });

    test('试听流 → 播放项打 isPreview，播放时长不用整首的 200 秒', () async {
      final AppleMusicCatalogClient catalog = _catalog(fullTracks: false);
      final MusicServerTrack track = (await catalog.search('x')).tracks.single;
      final MusicServerStream stream = catalog.streamFor(track);
      expect(stream.isPreview, isTrue);
      final MusicPlayItem item = musicServerPlayItem(catalog, track);
      expect(item.isPreview, isTrue);
      expect(item.path, 'https://audio.example/1.m4a');
      // 曲目元数据照旧是整首（歌词匹配 / 加入曲库按它），只是不拿来画进度条。
      expect(item.durationMs, 200000);
      expect(item.playbackDuration, isNull);
    });

    test('整曲（MusicKit）不打试听标记，播放时长就是整首', () async {
      final AppleMusicCatalogClient catalog = _catalog(fullTracks: true);
      final MusicServerTrack track = (await catalog.search('x')).tracks.single;
      final MusicPlayItem item = musicServerPlayItem(catalog, track);
      expect(item.isPreview, isFalse);
      expect(item.playbackDuration, const Duration(seconds: 200));
    });
    test('系统媒体卡片的时长：试听用媒体实际长度，普通曲目照旧用曲目时长', () {
      const MusicPlayItem preview = MusicPlayItem(
        trackUid: 'p',
        path: 'https://audio.example/p.m4a',
        title: 'p',
        durationMs: 200000,
        isPreview: true,
      );
      expect(
        musicMediaSessionDuration(preview, null),
        isNull,
        reason: '媒体还没报长度前不画 0:30 / 3:20 的进度条',
      );
      expect(
        musicMediaSessionDuration(preview, const Duration(seconds: 30)),
        const Duration(seconds: 30),
      );
      const MusicPlayItem full = MusicPlayItem(
        trackUid: 'f',
        path: '/m/f.flac',
        title: 'f',
        durationMs: 200000,
      );
      expect(
        musicMediaSessionDuration(full, const Duration(seconds: 199)),
        const Duration(seconds: 200),
      );
    });
  });

  group('角标', () {
    testWidgets('MusicPreviewBadge 显示「试听」并带完整读屏说明', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: MusicPreviewBadge())),
        ),
      );
      expect(find.text('Preview'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Preview clip only, not the full track'),
        findsOneWidget,
      );
      semantics.dispose();
    });

    testWidgets('MusicPreviewBadgeSwitcher 随 visible 显隐，不显示时不占位', (
      WidgetTester tester,
    ) async {
      Future<void> pump(bool visible) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(child: MusicPreviewBadgeSwitcher(visible: visible)),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await pump(false);
      expect(find.text('Preview'), findsNothing);
      expect(tester.getSize(find.byType(MusicPreviewBadgeSwitcher)), Size.zero);
      await pump(true);
      expect(find.text('Preview'), findsOneWidget);
      await pump(false);
      expect(find.text('Preview'), findsNothing);
    });
  });
}
