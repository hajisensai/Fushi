// B1 字幕搜索重做：版本卡列表 widget + 对话框版本视图集成。
// 锁住四条契约：① 聚类后一版本一卡；② 指定集数点卡直接命中该集文件；
// ③ 解析不出唯一文件时点卡展开文件行；④ 对话框默认版本视图、可切文件视图。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/subtitle/subtitle_version_groups.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi/src/pages/implementations/jimaku_subtitle_dialog.dart';
import 'package:fushi/src/pages/implementations/subtitle_version_group_list.dart';
import 'package:fushi/utils.dart';

class _FakeCandidate extends VideoSubtitleCandidate {
  _FakeCandidate({
    required super.remoteId,
    required super.fileName,
    super.providerId = 'jimaku',
    super.language = 'ja',
    super.providerPriority = 100,
    super.episode,
    super.fileSize,
    super.collectionId,
    super.collectionLabel,
  });
}

List<VideoSubtitleCandidate> _seasonPack() => <VideoSubtitleCandidate>[
      for (int ep = 1; ep <= 3; ep++)
        _FakeCandidate(
          remoteId: '9:[SubsPlease] Show - 0$ep.ass',
          fileName: '[SubsPlease] Show - 0$ep.ass',
          episode: ep,
          fileSize: 30000 + ep,
          collectionId: '9',
          collectionLabel: 'Show (2026)',
        ),
      _FakeCandidate(
        remoteId: '9:[MoeSubs] Show - 01.srt',
        fileName: '[MoeSubs] Show - 01.srt',
        language: 'zh',
        episode: 1,
        collectionId: '9',
        collectionLabel: 'Show (2026)',
      ),
    ];

void main() {
  Future<void> pumpList(
    WidgetTester tester, {
    required List<SubtitleVersionGroup> groups,
    int? requestedEpisode,
    required void Function(VideoSubtitleCandidate) onPick,
  }) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: SubtitleVersionGroupList(
            groups: groups,
            requestedEpisode: requestedEpisode,
            busyIdentityKey: null,
            onPickCandidate: onPick,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('一版本一卡：ass 与 srt 两组各渲染一张卡', (WidgetTester tester) async {
    final List<SubtitleVersionGroup> groups =
        buildSubtitleVersionGroups(_seasonPack());
    await pumpList(tester, groups: groups, onPick: (_) {});
    expect(find.byType(FushiCard), findsNWidgets(2));
    expect(find.textContaining('Show (2026) › ASS'), findsOneWidget);
    expect(find.textContaining('SubsPlease'), findsWidgets);
  });

  testWidgets('指定集数点卡 → 直接选中该集文件', (WidgetTester tester) async {
    final List<SubtitleVersionGroup> groups =
        buildSubtitleVersionGroups(_seasonPack());
    VideoSubtitleCandidate? picked;
    await pumpList(
      tester,
      groups: groups,
      requestedEpisode: 2,
      onPick: (VideoSubtitleCandidate candidate) => picked = candidate,
    );
    final SubtitleVersionGroup assGroup = groups
        .firstWhere((SubtitleVersionGroup group) => group.container == 'ass');
    await tester.tap(
      find.byKey(ValueKey<String>('subtitle-version-${assGroup.key}')),
    );
    await tester.pumpAndSettle();
    expect(picked, isNotNull);
    expect(picked!.episode, 2, reason: '集数框写 2，点卡就该拿第 2 集');
  });

  testWidgets('无法解析唯一文件 → 点卡展开文件行，点行选中', (WidgetTester tester) async {
    final List<SubtitleVersionGroup> groups =
        buildSubtitleVersionGroups(_seasonPack());
    VideoSubtitleCandidate? picked;
    await pumpList(
      tester,
      groups: groups,
      // 不指定集数 + 组内多文件 → 点卡应展开而不是瞎选。
      onPick: (VideoSubtitleCandidate candidate) => picked = candidate,
    );
    final SubtitleVersionGroup assGroup = groups
        .firstWhere((SubtitleVersionGroup group) => group.container == 'ass');
    await tester.tap(
      find.byKey(ValueKey<String>('subtitle-version-${assGroup.key}')),
    );
    await tester.pumpAndSettle();
    expect(picked, isNull);
    final Finder fileRow = find.byKey(
      ValueKey<String>(
        'subtitle-file-${assGroup.members[1].identityKey}',
      ),
    );
    expect(fileRow, findsOneWidget, reason: '展开后逐文件可选');
    await tester.tap(fileRow);
    await tester.pumpAndSettle();
    expect(picked!.episode, 2);
  });

  testWidgets('对话框：带来源候选默认版本视图，可切回文件视图', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final List<JimakuCandidate> seeded = <JimakuCandidate>[
      for (final VideoSubtitleCandidate source in _seasonPack())
        JimakuCandidate(
          entryName: source.collectionLabel ?? '',
          name: source.fileName,
          language: source.language,
          source: source,
        ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(builder: (BuildContext ctx) {
            return ElevatedButton(
              onPressed: () => showDialog<String>(
                context: ctx,
                builder: (_) => JimakuSubtitleDialog(
                  initialQuery: 'Show',
                  initialApiKey: 'TEST_KEY',
                  onApiKeyChanged: (_) async {},
                  saveDirectory: '/tmp/jimaku',
                  debugInitialCandidates: seeded,
                ),
              ),
              child: const Text('open'),
            );
          }),
        ),
      ),
    );
    await tester.tap(find.text('open'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.byType(SubtitleVersionGroupList), findsOneWidget,
        reason: '带真实来源的候选默认走版本卡视图');
    expect(find.byType(JimakuCandidateList), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('jimaku-file-view-toggle')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(JimakuCandidateList), findsOneWidget,
        reason: '文件视图开关切回旧平铺列表');
  });
}
