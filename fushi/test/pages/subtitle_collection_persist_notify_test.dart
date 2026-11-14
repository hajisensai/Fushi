import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/subtitle_collection_panel.dart';
import 'package:fushi/src/pages/implementations/subtitle_workbench_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/glass_unwrap.dart';

/// BUG-4496：「整个合集」批量下载只写存储，播放页内存里的字幕列表不会自己变。
/// 面板必须在每集持久化之后回调，播放页（工作台的订阅方）据此把当前集的新字幕
/// 登记并应用；这里钉面板侧回调、工作台合并规则与播放页接线三层。
const String _srt = '1\n00:00:01,000 --> 00:00:02,000\nこんにちは\n\n';

class _Cand extends VideoSubtitleCandidate {
  _Cand()
    : super(
        providerId: 'fake',
        remoteId: 'Source:Show - 01.ja.srt',
        fileName: 'Show - 01.ja.srt',
        language: 'ja',
        providerPriority: 1,
        episode: 1,
        collectionId: 'Source',
        collectionLabel: 'Source',
      );
}

class _Provider implements VideoSubtitleProvider {
  @override
  String get id => 'fake';
  @override
  int get priority => 1;
  @override
  bool get allowsFreeProbeDownload => true;
  @override
  void close() {}
  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) async => ProviderBatchResult<VideoSubtitleCandidate>.success(
    <VideoSubtitleCandidate>[_Cand()],
  );
  @override
  Future<VideoSubtitleDownload> download(
    VideoSubtitleCandidate candidate,
  ) async => VideoSubtitleDownload(
    bytes: Uint8List.fromList(utf8.encode(_srt)),
    fileName: candidate.fileName,
    language: 'ja',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late Directory tempDir;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    tempDir = await Directory.systemTemp.createTemp('subtitle_persist_');
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  testWidgets('BUG-4496 批量下载每集持久化后回调 (bookUid, 路径)，DB 与回调同一路径', (
    WidgetTester tester,
  ) async {
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('video/show-01'),
        title: const Value<String>('Show - 01'),
        videoPath: Value<String>('${tempDir.path}/Show - 01.mkv'),
      ),
    );
    final VideoBookRepository repo = VideoBookRepository(db);
    final VideoBookRow member = (await repo.getByBookUid('video/show-01'))!;
    final int collectionId = await db.createMediaCollection(
      'Show',
      collectionType: 'collection',
    );
    await db.setMediaCollectionAnilistId(collectionId, 21);
    final MediaCollectionRow collection = (await db.getMediaCollectionById(
      collectionId,
    ))!;
    final VideoSubtitleRegistry registry = VideoSubtitleRegistry(
      <VideoSubtitleProvider>[_Provider()],
    );
    final List<(String, String)> persisted = <(String, String)>[];

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SubtitleCollectionPanel(
              database: db,
              collection: collection,
              members: <VideoBookRow>[member],
              subtitleRegistry: () async => registry,
              initialApiKey: 'test-key',
              onApiKeyChanged: (_) async {},
              saveDirectory: tempDir.path,
              onRemoteSubtitlePersist: (_, __) async {},
              onSubtitlePersisted: (String uid, String path) =>
                  persisted.add((uid, path)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder download = glassUnwrap<FilledButton>(
      find.byKey(const ValueKey<String>('subtitle-collection-download-all')),
    );
    expect(tester.widget<FilledButton>(download).onPressed, isNotNull);
    await tester.tap(download);
    // 落盘与解析 cue 是真文件 IO，在 runAsync 里让它们跑完。
    for (int i = 0; i < 50 && persisted.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(persisted, hasLength(1));
    expect(persisted.single.$1, 'video/show-01');
    final VideoBookRow? saved = await repo.getByBookUid('video/show-01');
    expect(saved?.subtitleSource, persisted.single.$2);
    expect(File(persisted.single.$2).existsSync(), isTrue);
  });

  group('workbenchPathsToApply', () {
    test('只有合集批量落到当前集：应用它', () {
      expect(
        workbenchPathsToApply(
          episodePaths: null,
          collectionPathForCurrent: '/s/ep1.srt',
        ),
        <String>['/s/ep1.srt'],
      );
    });

    test('本集下载优先应用，合集那条只登记；重复路径不重复', () {
      expect(
        workbenchPathsToApply(
          episodePaths: <String>['/s/a.srt', '/s/b.srt'],
          collectionPathForCurrent: '/s/ep1.srt',
        ),
        <String>['/s/a.srt', '/s/b.srt', '/s/ep1.srt'],
      );
      expect(
        workbenchPathsToApply(
          episodePaths: <String>['/s/ep1.srt'],
          collectionPathForCurrent: '/s/ep1.srt',
        ),
        <String>['/s/ep1.srt'],
      );
    });

    test('都没有：空列表', () {
      expect(
        workbenchPathsToApply(
          episodePaths: null,
          collectionPathForCurrent: null,
        ),
        isEmpty,
      );
    });
  });

  test('播放页订阅合集批量回调并在关闭工作台后应用当前集字幕', () {
    final String src = File(
      'lib/src/pages/implementations/video_fushi/subtitle.part.dart',
    ).readAsStringSync();
    final int open = src.indexOf('SubtitleWorkbenchPage.open(');
    expect(open, isNonNegative);
    final String body = src.substring(open, open + 1600);
    expect(body, contains('onCollectionSubtitlePersisted:'));
    expect(body, contains('bookUid == workbenchBookUid'));
    expect(body, contains('workbenchPathsToApply('));
    expect(body, contains('_applyDownloadedSubtitles(controller, toApply)'));
    final String workbench = File(
      'lib/src/pages/implementations/subtitle_workbench_page.dart',
    ).readAsStringSync();
    expect(
      workbench,
      contains('onSubtitlePersisted: widget.onCollectionSubtitlePersisted'),
    );
  });
}
