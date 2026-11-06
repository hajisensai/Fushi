import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/app_video_subtitle_service.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_glossary_page.dart';
import 'package:fushi/src/media/video/video_playback_remote.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:material_ui/material_ui.dart';

import '../../../helpers/fake_video_subtitle.dart';

void main() {
  late FushiDatabase db;
  late MemoryGlossaryStore store;
  late FakeVideoSubtitleSettings settings;

  const SubtitleWorkContext work = SubtitleWorkContext(
    workKey: 'collection:9',
    title: 'K-ON',
    originalTitle: 'けいおん!',
  );
  const AppVideoSubtitleTarget target = AppVideoSubtitleTarget(
    title: 'K-ON',
    work: work,
    episodes: <AppVideoSubtitleEpisode>[],
    collectionId: 9,
  );

  setUpAll(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDownAll(() => db.close());
  setUp(() {
    settings = FakeVideoSubtitleSettings();
    store = MemoryGlossaryStore()
      ..rows[work.workKey] = const SubtitleGlossary(
        entries: <SubtitleGlossaryEntry>[
          SubtitleGlossaryEntry(ja: '唯', reading: 'ゆい', kind: '人名'),
          SubtitleGlossaryEntry(ja: '澪', reading: 'みお', kind: '人名'),
        ],
        sourceFingerprint: 'fp',
        generatedAt: 1,
      );
  });

  AppVideoSubtitleService service() => AppVideoSubtitleService(
    database: db,
    settings: settings,
    glossaryStore: store,
    jobRegistry: VideoRemoteJobRegistry(),
    jobsRoot: () async => Directory.systemTemp,
    mossPort: const ReadyModels(),
    asrModelPort: const ReadyModels(),
    nowMs: () => 777,
  );

  Future<void> pumpPage(
    WidgetTester tester, {
    List<SubtitleGlossaryEntry>? candidate,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: VideoSubtitleGlossaryPage(
          service: service(),
          target: target,
          candidate: candidate,
          openAiSettings: (BuildContext _) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<SubtitleGlossaryEntry> saved() => store.rows[work.workKey]!.entries;

  testWidgets('添加：新条目落库并标 userEdited，误写按逗号拆开；原条目不标', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester);
    expect(find.text('唯'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('video-subtitle-glossary-add')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('video-subtitle-glossary-field-ja')),
      'ムギ',
    );
    await tester.enterText(
      find.byKey(
        const ValueKey<String>('video-subtitle-glossary-field-misrecognitions'),
      ),
      '麦, 紬、麦',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('video-subtitle-glossary-save')),
    );
    await tester.pumpAndSettle();

    expect(saved().map((SubtitleGlossaryEntry e) => e.ja), <String>[
      '唯',
      '澪',
      'ムギ',
    ]);
    expect(saved().last.userEdited, isTrue);
    expect(saved().last.misrecognitions, <String>['麦', '紬']);
    expect(saved().first.userEdited, isFalse);
    expect(store.rows[work.workKey]!.userEditedAt, 777);
    expect(store.rows[work.workKey]!.sourceFingerprint, 'fp');
    expect(find.text('ムギ'), findsOneWidget);
  });

  testWidgets('编辑：改读音落库并标 userEdited；重名被拦下不落库', (WidgetTester tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('澪'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('video-subtitle-glossary-field-ja')),
      '唯',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('video-subtitle-glossary-save')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('video-subtitle-glossary-save')),
      findsOneWidget,
      reason: '重名：对话框不关',
    );
    expect(saved()[1].ja, '澪');

    await tester.enterText(
      find.byKey(const ValueKey<String>('video-subtitle-glossary-field-ja')),
      '澪',
    );
    await tester.enterText(
      find.byKey(
        const ValueKey<String>('video-subtitle-glossary-field-reading'),
      ),
      'みおちゃん',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('video-subtitle-glossary-save')),
    );
    await tester.pumpAndSettle();
    expect(saved()[1].reading, 'みおちゃん');
    expect(saved()[1].userEdited, isTrue);
    expect(saved()[0].userEdited, isFalse);
  });

  testWidgets('删除：确认后从表里去掉', (WidgetTester tester) async {
    await pumpPage(tester);
    await tester.tap(
      find.descendant(
        of: find.byKey(
          const ValueKey<String>('video-subtitle-glossary-entry-0'),
        ),
        matching: find.byTooltip('Entry actions'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete entry').last);
    await tester.pumpAndSettle();
    // 确认框的确认按钮文案同为「Delete entry」。
    await tester.tap(find.text('Delete entry').last);
    await tester.pumpAndSettle();
    expect(saved().map((SubtitleGlossaryEntry e) => e.ja), <String>['澪']);
  });

  testWidgets('候选表：先显示未保存的候选，点「原样采用」才落库', (WidgetTester tester) async {
    store.rows.clear();
    await pumpPage(
      tester,
      candidate: const <SubtitleGlossaryEntry>[
        SubtitleGlossaryEntry(ja: 'レヴィ', kind: '人名'),
      ],
    );
    expect(
      find.byKey(const ValueKey<String>('video-subtitle-glossary-candidate')),
      findsOneWidget,
    );
    expect(store.rows, isEmpty);
    await tester.tap(
      find.byKey(
        const ValueKey<String>('video-subtitle-glossary-accept-candidate'),
      ),
    );
    await tester.pumpAndSettle();
    expect(saved().single.ja, 'レヴィ');
    expect(saved().single.userEdited, isTrue);
    expect(store.rows[work.workKey]!.sourceFingerprint, isNotEmpty);
    expect(
      find.byKey(const ValueKey<String>('video-subtitle-glossary-candidate')),
      findsNothing,
    );
  });

  testWidgets('重新生成：没指派提供商只提示，不发请求', (WidgetTester tester) async {
    await pumpPage(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('video-subtitle-glossary-regenerate')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('video-subtitle-glossary-notice')),
      findsOneWidget,
    );
    expect(
      find.text('No AI provider is assigned to "Subtitle proofreading"'),
      findsOneWidget,
    );
  });
}
