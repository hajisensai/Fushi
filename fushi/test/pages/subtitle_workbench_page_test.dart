import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/download/video_subtitle_registry.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/pages/implementations/subtitle_workbench_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 全屏字幕工作台：作用域开关只在「本集 + 合集」都有时出现；默认落本集；切换换面板。
class _Host implements SubtitleWorkbenchHost {
  _Host(this.database);

  @override
  final FushiDatabase database;
  @override
  VideoSubtitleRegistry? get subtitleRegistry =>
      VideoSubtitleRegistry(const <VideoSubtitleProvider>[]);
  @override
  String get jimakuApiKey => '';
  @override
  Future<void> setJimakuApiKey(String key) async {}
  @override
  Future<http.Client> createHttpClient() async =>
      MockClient((_) async => http.Response('', 404));
  @override
  String? preferredLanguageFor(String seriesKey) => null;
  @override
  Future<void> setPreferredLanguage(String seriesKey, String langCode) async {}
  @override
  String? get defaultContentLanguage => null;
  @override
  Future<void> persistRemoteSubtitle(String bookUid, String path) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late Directory tempDir;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    tempDir = await Directory.systemTemp.createTemp('subtitle_workbench_');
  });

  tearDown(() async {
    await db.close();
    await tempDir.delete(recursive: true);
  });

  Future<SubtitleCollectionSpec> seedCollection() async {
    await db.upsertVideoBook(
      const VideoBooksCompanion(
        bookUid: Value<String>('video/show-01'),
        title: Value<String>('Show - 01'),
        videoPath: Value<String>('C:/video/Show - 01.mkv'),
      ),
    );
    final VideoBookRow member = (await VideoBookRepository(
      db,
    ).getByBookUid('video/show-01'))!;
    final int id = await db.createMediaCollection(
      'Show',
      collectionType: 'collection',
    );
    return SubtitleCollectionSpec(
      collection: (await db.getMediaCollectionById(id))!,
      members: <VideoBookRow>[member],
    );
  }

  const SubtitleEpisodeSearchSpec episode = SubtitleEpisodeSearchSpec(
    initialQuery: 'Show',
    seriesKey: 'show',
  );

  Widget wrap(Widget page) =>
      TranslationProvider(child: MaterialApp(home: page));

  testWidgets('有合集上下文：默认本集，作用域开关切到整个合集', (WidgetTester tester) async {
    final SubtitleCollectionSpec collection = await seedCollection();
    await tester.pumpWidget(
      wrap(
        SubtitleWorkbenchPage(
          host: _Host(db),
          saveDirectory: tempDir.path,
          episode: episode,
          collection: collection,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.video_subtitle_workbench_title), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('subtitle-workbench-scope')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('subtitle-workbench-episode')),
      findsOneWidget,
    );
    await tester.tap(find.text(t.video_subtitle_scope_collection));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('subtitle-workbench-collection')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('subtitle-workbench-episode')),
      findsNothing,
    );
  });

  testWidgets('只有本集：没有作用域开关', (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(
        SubtitleWorkbenchPage(
          host: _Host(db),
          saveDirectory: tempDir.path,
          episode: episode,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('subtitle-workbench-scope')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('subtitle-workbench-episode')),
      findsOneWidget,
    );
  });

  testWidgets('只有合集（库页入口）：直接落合集面板', (WidgetTester tester) async {
    final SubtitleCollectionSpec collection = await seedCollection();
    await tester.pumpWidget(
      wrap(
        SubtitleWorkbenchPage(
          host: _Host(db),
          saveDirectory: tempDir.path,
          collection: collection,
          initialScope: SubtitleWorkbenchScope.collection,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('subtitle-workbench-scope')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('subtitle-workbench-collection')),
      findsOneWidget,
    );
  });
}
