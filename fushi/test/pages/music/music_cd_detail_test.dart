import 'dart:convert' show base64Decode;
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/music/music_cd_detail.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

MusicTrackRow _row(
  String uid,
  String path, {
  int? disc,
  int? no,
  int ms = 60000,
}) => MusicTrackRow(
  trackUid: uid,
  path: path,
  title: 'Song $uid',
  discNo: disc,
  trackNo: no,
  durationMs: ms,
  codec: 'flac',
  isLossless: true,
  sampleRate: 44100,
  bitDepth: 16,
  fileMtimeAt: 1,
  fileSize: 1,
  hasEmbeddedCover: false,
  addedAt: 1,
);

/// 1×1 透明 PNG（盘面图要是真图，解码失败会报图片异常）。
const String _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

MusicAlbumRow _album() => const MusicAlbumRow(
  albumUid: 'al',
  title: 'Here, the world!',
  albumArtistCredit: 'sumimi',
  releaseDate: '2025-04-02',
  addedAt: 1,
  updatedAt: 1,
);

Future<void> _pumpPanel(
  WidgetTester tester,
  List<MusicTrackRow> tracks, {
  required Size size,
  VoidCallback? onOpenAlbumPage,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  LocaleSettings.setLocale(AppLocale.en);
  final Directory tmp = Directory.systemTemp.createTempSync('fushi_cd_');
  addTearDown(() => tmp.deleteSync(recursive: true));
  final String disc = p.join(tmp.path, 'disc.png');
  File(disc).writeAsBytesSync(base64Decode(_onePixelPng));
  await tester.pumpWidget(
    ProviderScope(
      child: TranslationProvider(
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          // 减少动态效果：唱片不转、编排直接落位，pumpAndSettle 能停。
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: Scaffold(
            body: MusicCdDetailPanel(
              animation: kAlwaysCompleteAnimation,
              origin: null,
              openCurve: Curves.linear,
              closeCurve: Curves.linear,
              album: _album(),
              tracks: tracks,
              embeddedCoverPath: null,
              discArtPath: disc,
              onOpenAlbumPage: onOpenAlbumPage ?? () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('面板目标矩形：桌面居中留边、窄窗全屏', () {
    expect(
      musicCdDetailPanelRect(const Size(1400, 900)),
      const Rect.fromLTWH(120, 80, 1160, 740),
    );
    expect(
      musicCdDetailPanelRect(const Size(1000, 700)),
      const Rect.fromLTWH(24, 24, 952, 652),
    );
    expect(
      musicCdDetailPanelRect(const Size(400, 800)),
      Offset.zero & const Size(400, 800),
    );
  });

  testWidgets('抬头 · 标题 · 艺人 · 信息胶囊；多碟按 DISC 分组', (WidgetTester tester) async {
    final String root = p.join(p.current, 'lib_root', 'Album');
    await _pumpPanel(tester, <MusicTrackRow>[
      _row('a', p.join(root, 'CD1', '01.flac'), disc: 1, no: 1),
      _row('b', p.join(root, 'CD1', '02.flac'), disc: 1, no: 2),
      _row('c', p.join(root, 'CD2', '01.flac'), disc: 2, no: 1),
    ], size: const Size(1400, 900));

    expect(find.text(t.music_cd_kicker), findsOneWidget);
    expect(find.text('Here, the world!'), findsWidgets);
    expect(find.text('sumimi'), findsOneWidget);
    expect(find.text('2025'), findsOneWidget);
    expect(find.text(t.music_tracks_count(count: 3)), findsOneWidget);
    expect(
      find.text(t.music_queue_duration_minutes(minutes: 3)),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('music-cd-disc-0-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('music-cd-disc-0-2')),
      findsOneWidget,
    );
    expect(find.text('Song a'), findsOneWidget);
    expect(find.text('Song c'), findsOneWidget);
    // 只有一个版本：不画版本分组头。
    expect(
      find.byKey(const ValueKey<String>('music-cd-version-0')),
      findsNothing,
    );
  });

  testWidgets('同一专辑两个目录按版本分开列', (WidgetTester tester) async {
    final String base = p.join(p.current, 'lib_root');
    await _pumpPanel(tester, <MusicTrackRow>[
      _row('f1', p.join(base, 'Album [FLAC]', '01.flac'), disc: 1, no: 1),
      _row('m1', p.join(base, 'Album [MP3]', '01.mp3'), disc: 1, no: 1),
      _row('m2', p.join(base, 'Album [MP3]', '02.mp3'), disc: 1, no: 2),
    ], size: const Size(1400, 900));

    expect(find.text(t.music_cd_versions_count(count: 2)), findsOneWidget);
    expect(
      find.text(t.music_cd_version_heading(n: 1, label: 'Album [FLAC]')),
      findsOneWidget,
    );
    expect(
      find.text(t.music_cd_version_heading(n: 2, label: 'Album [MP3]')),
      findsOneWidget,
    );
  });

  testWidgets('窄窗全屏照样排出轨道表与关闭钮', (WidgetTester tester) async {
    final String root = p.join(p.current, 'lib_root', 'Album');
    await _pumpPanel(tester, <MusicTrackRow>[
      _row('a', p.join(root, '01.flac'), no: 1),
    ], size: const Size(400, 800));
    expect(find.text('Song a'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('music-cd-close')),
      findsOneWidget,
    );
  });
}
