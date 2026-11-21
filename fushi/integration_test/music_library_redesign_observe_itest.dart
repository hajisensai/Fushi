import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/generate_test_image.dart';
import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 音乐曲库重设计（2026-11-21）的真像素证据：隔离库里落几张专辑（两张带盘面扫描
/// 图、几张只有封面、一张标题很长），进音乐页抓一帧专辑墙。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('音乐专辑墙：与书架 / 漫画同一套色块文字区，盘面图专辑唱片从封套滑出', (
    WidgetTester tester,
  ) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    await tester.pump(const Duration(seconds: 2));
    final AppModel appModel = await readyAppModel(tester);

    final Directory root = Directory(
      p.join(Directory.systemTemp.path, 'fushi_music_redesign_observe'),
    );
    if (root.existsSync()) root.deleteSync(recursive: true);
    const TestImageGenerator gen = TestImageGenerator();
    const List<(String, String, bool)> albums = <(String, String, bool)>[
      ('Blast!', 'TRUE', true),
      ('Here, the world!', 'sumimi', true),
      ('K-ON!! ORIGINAL SOUND TRACK Vol.1', '百石元', false),
      ('SAKURA? SONG ALBUM SAKURA＊SAKU -桜＊作-', 'SAKURA', false),
      ('Re:結束バンド', '結束バンド', false),
      ('Fly Me to the Star', 'スタァライト九九組', false),
      ('SAKURA♪SONG 01', 'Trident', false),
    ];
    final List<MusicTracksCompanion> tracks = <MusicTracksCompanion>[];
    final List<MusicAlbumsCompanion> rows = <MusicAlbumsCompanion>[];
    for (int i = 0; i < albums.length; i++) {
      final (String title, String artist, bool disc) = albums[i];
      final Directory dir = Directory(p.join(root.path, 'album$i'))
        ..createSync(recursive: true);
      final String cover = p.join(dir.path, 'cover.png');
      File(
        cover,
      ).writeAsBytesSync(gen.pngBytes(width: 400, height: 400, seed: i + 1));
      if (disc) {
        File(
          p.join(dir.path, 'disc.png'),
        ).writeAsBytesSync(gen.pngBytes(width: 400, height: 400, seed: 40 + i));
      }
      final String uid = 'obs-album-$i';
      rows.add(
        MusicAlbumsCompanion.insert(
          albumUid: uid,
          title: title,
          albumArtistCredit: Value<String?>(artist),
          releaseDate: const Value<String?>('2025'),
          coverPath: Value<String?>(cover),
          addedAt: 1,
          updatedAt: 1,
        ),
      );
      for (int n = 1; n <= 3; n++) {
        final String path = p.join(dir.path, '0$n.flac');
        File(path).writeAsBytesSync(<int>[0]);
        tracks.add(
          MusicTracksCompanion.insert(
            trackUid: 'obs-$i-$n',
            path: path,
            title: '$title #$n',
            albumUid: Value<String?>(uid),
            artistCredit: Value<String?>(artist),
            codec: const Value<String?>('flac'),
            isLossless: const Value<bool>(true),
            sampleRate: const Value<int?>(44100),
            bitDepth: const Value<int?>(16),
            durationMs: const Value<int?>(200000),
            trackNo: Value<int?>(n),
            fileMtimeAt: 1,
            fileSize: 1,
            addedAt: 1,
          ),
        );
      }
    }
    await appModel.database.writeMusicScanBatch(
      MusicScanBatchWrite(
        tracks: tracks,
        albums: rows,
        artists: const <MusicArtistsCompanion>[],
        credits: const <MusicTrackCreditsCompanion>[],
      ),
    );

    HomePage.debugSelectTab?.call(HomeTab.music);
    for (int i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    final ObserveShot shot = await captureFlutterFrame(tester, '01-albums');
    expect(shot.saved, isTrue);
    root.deleteSync(recursive: true);
  });
}
