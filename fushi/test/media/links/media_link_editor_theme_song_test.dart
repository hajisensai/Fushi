import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/links/media_link_editor_dialog.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

/// 连接编辑器的主题曲分支（作品图谱 L2）：选「主题曲」+ 目标「曲目」才出角色 / 集数，
/// 写入的连接方向固定「音乐 → 视频」并带 role / episode_range；两端不是音乐 + 视频时
/// 给提示、候选不可点。
void main() {
  late FushiDatabase db;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    await db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: 'ep1',
        title: '第一集',
        videoPath: '/nonexistent/ep1.mkv',
      ),
    );
    await db.writeMusicScanBatch(
      MusicScanBatchWrite(
        tracks: <MusicTracksCompanion>[
          MusicTracksCompanion.insert(
            trackUid: 'op',
            path: '/nonexistent/op.flac',
            title: '夜明けの窓',
            albumUid: const Value<String?>('al'),
            fileMtimeAt: 1,
            fileSize: 1,
            addedAt: 1,
          ),
        ],
        albums: <MusicAlbumsCompanion>[
          MusicAlbumsCompanion.insert(
            albumUid: 'al',
            title: 'OP 单曲',
            addedAt: 1,
            updatedAt: 1,
          ),
        ],
        artists: const <MusicArtistsCompanion>[],
        credits: const <MusicTrackCreditsCompanion>[],
      ),
    );
  });

  tearDown(() => db.close());

  Future<void> pump(WidgetTester tester) async {
    // 对话框内容（分段 + 角色 + 集数 + 候选）在默认 800×600 里放不下，候选会落在可视区外。
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(
                      body: MediaLinkEditorDialog(
                        database: db,
                        self: (kind: MediaLinkKind.videoEpisode, key: 'ep1'),
                      ),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('视频 ↔ 曲目：选角色与集数，写入「音乐 → 视频」的主题曲连接', (WidgetTester tester) async {
    await pump(tester);
    await tester.tap(find.text('主题曲'));
    await tester.pumpAndSettle();
    // 默认目标种类是书：两端不是音乐 + 视频。
    expect(
      find.byKey(const ValueKey<String>('media-link-theme-song-incompatible')),
      findsOneWidget,
    );
    await tester.tap(find.text('曲目'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('media-link-theme-song-incompatible')),
      findsNothing,
    );
    await tester.tap(find.text('ED'));
    await tester.enterText(
      find.byKey(const ValueKey<String>('media-link-theme-song-episodes')),
      '1-12',
    );
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('夜明けの窓 · OP 单曲'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('夜明けの窓 · OP 单曲'));
    await tester.pumpAndSettle();

    final List<MediaLinkRow> links = await db.allMediaLinks();
    expect(links, hasLength(1));
    final MediaLinkRow link = links.single;
    expect(link.relation, MediaLinkRelation.themeSong.dbValue);
    expect(link.fromKind, MediaLinkKind.musicTrack.dbValue);
    expect(link.fromKey, 'op');
    expect(link.toKind, MediaLinkKind.videoEpisode.dbValue);
    expect(link.toKey, 'ep1');
    expect(link.role, 'ed');
    expect(link.episodeRange, '1-12');
    expect(link.isUserConfirmed, isTrue);
  });

  testWidgets('集数写成解析不了的文本按「全部」存', (WidgetTester tester) async {
    await pump(tester);
    await tester.tap(find.text('主题曲'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('曲目'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('media-link-theme-song-episodes')),
      '前半',
    );
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('夜明けの窓 · OP 单曲'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('夜明けの窓 · OP 单曲'));
    await tester.pumpAndSettle();
    final MediaLinkRow link = (await db.allMediaLinks()).single;
    expect(link.role, 'op');
    expect(link.episodeRange, isNull);
  });
}
