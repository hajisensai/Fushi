import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_jump_panel.dart';
import 'package:fushi_audio/fushi_audio.dart';

import '../../helpers/source_guard.dart';

/// BUG-1907：字幕列表加「搜索（Ctrl+F 可快捷触发）和导出（导出收藏语句）」
/// （用户 2026-08-28）。
///
/// 两个要点各自都有坑：
/// * **搜索**必须走共享的 `matchesMediaSearch`，而不是裸 `toLowerCase().contains`
///   ——它统一做全角→半角、大写→小写、片假名→平假名的归一化。对日语字幕这是刚需，
///   而且 CLAUDE.md 的术语表把「用户可见搜索禁裸 contains」列为硬性口径。
/// * **Ctrl+F** 面板必须自己接一份：视频页那张整表快捷键装在 media_kit controls 的
///   `CallbackShortcuts` 上，只包住 controls 子树，而面板是它的**兄弟节点**，
///   焦点一进面板那张表就收不到任何按键。
AudioCue _cue(int i, int s, int e, String text) => AudioCue()
  ..bookKey = 'video/1'
  ..chapterHref = 'video://default'
  ..sentenceIndex = i
  ..textFragmentId = ''
  ..text = text
  ..startMs = s
  ..endMs = e
  ..audioFileIndex = 0;

Widget _wrap(Widget child) => TranslationProvider(
      child: MaterialApp(
        home: Scaffold(body: Stack(children: <Widget>[child])),
      ),
    );

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  VideoPlayerController seeded(WidgetTester tester) {
    final VideoPlayerController controller = VideoPlayerController();
    addTearDown(controller.dispose);
    controller.setCues(<AudioCue>[
      _cue(0, 0, 1000, 'ナレーションのフキダシ'),
      _cue(1, 2000, 3000, '登場人物の心理'),
      _cue(2, 4000, 5000, 'Hello world'),
    ]);
    return controller;
  }

  Widget panel(
    VideoPlayerController controller, {
    bool Function(AudioCue)? isFavorited,
    Future<void> Function(List<AudioCue>)? onExport,
    List<ShortcutActivator> searchActivators = const <ShortcutActivator>[],
    ValueListenable<int>? searchRequests,
  }) =>
      VideoSubtitleJumpPanel(
        controller: controller,
        onTapCue: (_) {},
        onClose: () {},
        onCopyCue: (_) {},
        onFavoriteCue: (_) async {},
        isCueFavorited: isFavorited ?? (_) => false,
        colorScheme: const ColorScheme.dark(),
        title: '字幕列表',
        emptyHint: 'empty',
        width: 420,
        onExportFavorites: onExport,
        searchActivators: searchActivators,
        searchRequests: searchRequests,
      );

  testWidgets('点搜索按钮展开输入框，输入即过滤列表', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_wrap(panel(seeded(tester))));
    await tester.pumpAndSettle();

    expect(find.text('ナレーションのフキダシ'), findsOneWidget);
    expect(find.byType(TextField), findsNothing,
        reason: '搜索框收起时不得占高度 —— 面板最窄 240px');

    await tester.tap(find.byTooltip(t.video_subtitle_list_search));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), '登場');
    await tester.pumpAndSettle();

    expect(find.text('登場人物の心理'), findsOneWidget);
    expect(find.text('ナレーションのフキダシ'), findsNothing);
    expect(find.text('Hello world'), findsNothing);
  });

  testWidgets('搜索走归一化匹配：片假名查得到、大小写无关（不是裸 contains）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_wrap(panel(seeded(tester))));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(t.video_subtitle_list_search));
    await tester.pumpAndSettle();

    // 平假名查片假名台词：裸 contains 做不到，matchesMediaSearch 会把两者归一。
    await tester.enterText(find.byType(TextField), 'なれーしょん');
    await tester.pumpAndSettle();
    expect(find.text('ナレーションのフキダシ'), findsOneWidget,
        reason: '平假名必须能命中片假名台词 —— 这正是不能用裸 contains 的原因');

    // 大小写无关。
    await tester.enterText(find.byType(TextField), 'HELLO');
    await tester.pumpAndSettle();
    expect(find.text('Hello world'), findsOneWidget);
  });

  testWidgets('搜不到时提示「没有匹配的台词」，而不是照搬空档文案', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_wrap(panel(seeded(tester))));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(t.video_subtitle_list_search));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'ZZZZ 不存在');
    await tester.pumpAndSettle();

    expect(find.text(t.video_subtitle_list_search_empty), findsOneWidget);
  });

  testWidgets('收起搜索会清掉搜索词（否则列表停在看不见输入框的过滤态）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_wrap(panel(seeded(tester))));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(t.video_subtitle_list_search));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '登場');
    await tester.pumpAndSettle();
    expect(find.text('Hello world'), findsNothing);

    await tester.tap(find.byTooltip(t.video_subtitle_list_search));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(find.text('Hello world'), findsOneWidget, reason: '收起搜索必须恢复全量列表');
  });

  testWidgets('面板自带 Ctrl+F：焦点在面板内也能打开搜索（整表快捷键够不到这里）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_wrap(panel(
      seeded(tester),
      searchActivators: const <ShortcutActivator>[
        SingleActivator(LogicalKeyboardKey.keyF, control: true),
      ],
    )));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);

    // 让焦点落进面板子树，再按 Ctrl+F。
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget,
        reason: '面板必须自带一份 activator —— 视频页整表只包 media_kit controls 子树');
  });

  testWidgets('页面层请求（整表快捷键）也能让面板展开搜索', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final ValueNotifier<int> requests = ValueNotifier<int>(0);
    addTearDown(requests.dispose);

    await tester
        .pumpWidget(_wrap(panel(seeded(tester), searchRequests: requests)));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);

    requests.value = requests.value + 1;
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('PR#1032 审查 B1：列表关着时发出的请求不能丢（面板下一帧才挂载）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final ValueNotifier<bool> visible = ValueNotifier<bool>(false);
    addTearDown(visible.dispose);
    final ValueNotifier<int> requests = ValueNotifier<int>(0);
    addTearDown(requests.dispose);
    final VideoPlayerController controller = seeded(tester);

    // 视频页 `_requestSubtitleListSearch` + `_toggleSubtitleJumpList` 的等价路径：
    // 列表没开就先开（开 = 面板会话开始 = 水位线归零），**同一个微任务里**接着 +1。
    // 真面板要等下一帧才由 ListenableBuilder 构造、initState 才 addListener，所以
    // 这次 +1 发生在「零监听者」的时刻——这正是唯一会坏的时序，也是用户报的主路径。
    void requestSearch() {
      if (!visible.value) {
        requests.value = 0;
        visible.value = true;
      }
      requests.value = requests.value + 1;
    }

    await tester.pumpWidget(_wrap(ValueListenableBuilder<bool>(
      valueListenable: visible,
      builder: (BuildContext _, bool open, __) => open
          ? panel(controller, searchRequests: requests)
          : const SizedBox.shrink(),
    )));
    await tester.pumpAndSettle();
    expect(find.byType(VideoSubtitleJumpPanel), findsNothing);

    requestSearch();
    await tester.pumpAndSettle();

    expect(find.byType(VideoSubtitleJumpPanel), findsOneWidget,
        reason: '请求必须同时把列表开出来');
    expect(find.byType(TextField), findsOneWidget,
        reason: '第一次 Ctrl+F 就该出搜索框；要按第二次说明请求被当边沿事件丢了');
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
      isTrue,
      reason: '展开搜索必须同时抢到焦点，否则用户还得再点一下输入框',
    );
  });

  testWidgets('PR#1032 审查 B1：重开列表不会因为上次的水位残留而自动进搜索态', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final ValueNotifier<bool> visible = ValueNotifier<bool>(false);
    addTearDown(visible.dispose);
    final ValueNotifier<int> requests = ValueNotifier<int>(0);
    addTearDown(requests.dispose);
    final VideoPlayerController controller = seeded(tester);

    await tester.pumpWidget(_wrap(ValueListenableBuilder<bool>(
      valueListenable: visible,
      builder: (BuildContext _, bool open, __) => open
          ? panel(controller, searchRequests: requests)
          : const SizedBox.shrink(),
    )));

    // 一次带搜索的打开。
    requests.value = 0;
    visible.value = true;
    requests.value = requests.value + 1;
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    // 关掉列表，再用「不带搜索」的普通打开（控制条字幕按钮）重开：水位线由打开分支
    // 归零，所以新面板不该自作主张进搜索态。
    visible.value = false;
    await tester.pumpAndSettle();
    requests.value = 0;
    visible.value = true;
    await tester.pumpAndSettle();

    expect(find.byType(VideoSubtitleJumpPanel), findsOneWidget);
    expect(find.byType(TextField), findsNothing,
        reason: '普通打开不该带搜索态——否则水位线基线没被归零');
  });

  group('PR#1032 审查 B1 页面侧水位线归零（守卫上面两条用例里的等价路径确实等价）', () {
    String subtitlePartSource() => File(
          'lib/src/pages/implementations/video_fushi/subtitle.part.dart',
        ).readAsStringSync().replaceAll('\r\n', '\n');

    test('_toggleSubtitleJumpList 的打开分支把 _subtitleSearchRequests 归零', () {
      final String src = subtitlePartSource();
      final int start = src.indexOf('void _toggleSubtitleJumpList() {');
      expect(start, isNonNegative, reason: '方法被改名了，守卫要跟着改');
      final int elseAt = src.indexOf('} else {', start);
      expect(elseAt, isNonNegative);
      final String openBranch = src.substring(start, elseAt);
      expect(
        containsCodeLine(openBranch, '_subtitleSearchRequests.value = 0;'),
        isTrue,
        reason: '面板会话开始必须把搜索请求水位线归零（基线 0），否则重开列表会带着'
            '上一次的水位直接进搜索态；注释里写着这句不算实现',
      );
    });

    test('_requestSubtitleListSearch 仍是「先开列表再 +1」（水位线语义的前提）', () {
      final String src = subtitlePartSource();
      final int start = src.indexOf('void _requestSubtitleListSearch() {');
      expect(start, isNonNegative);
      final String body = src.substring(start, src.indexOf('\n  }', start));
      expect(containsCodeLine(body, '_toggleSubtitleJumpList();'), isTrue);
      expect(
        containsCodeLine(
          body,
          '_subtitleSearchRequests.value = _subtitleSearchRequests.value + 1;',
        ),
        isTrue,
      );
    });
  });

  testWidgets('收藏档出现导出按钮，交出的是收藏句（不受搜索词影响）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    List<AudioCue>? exported;
    final VideoPlayerController controller = seeded(tester);
    await tester.pumpWidget(_wrap(panel(
      controller,
      // 前两句已收藏。
      isFavorited: (AudioCue cue) => cue.text != 'Hello world',
      onExport: (List<AudioCue> cues) async => exported = cues,
    )));
    await tester.pumpAndSettle();

    // 全部档不显示导出按钮（它导的是收藏档的内容）。
    expect(
        find.byTooltip(t.video_subtitle_list_export_favorites), findsNothing);

    // 切到收藏档。
    await tester.tap(find.text(t.video_subtitle_filter_favorites));
    await tester.pumpAndSettle();
    expect(
        find.byTooltip(t.video_subtitle_list_export_favorites), findsOneWidget);

    // 搜索缩小到一条，导出仍应给出全部收藏句 —— 搜索着导出只导搜索结果是个陷阱。
    await tester.tap(find.byTooltip(t.video_subtitle_list_search));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '登場');
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip(t.video_subtitle_list_export_favorites));
    await tester.pumpAndSettle();

    expect(exported, isNotNull);
    expect(
      exported!.map((AudioCue c) => c.text).toList(),
      <String>['ナレーションのフキダシ', '登場人物の心理'],
      reason: '导出口径是「收藏档实际渲染的那批」，与当前搜索词无关',
    );
  });

  testWidgets('没有收藏句时导出按钮禁用', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    bool called = false;
    await tester.pumpWidget(_wrap(panel(
      seeded(tester),
      isFavorited: (_) => false,
      onExport: (_) async => called = true,
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.video_subtitle_filter_favorites));
    await tester.pumpAndSettle();

    // IconButton 把 Tooltip 建在**自己内部**，所以 byTooltip 命中的是后代而非祖先；
    // 直接按图标定位按钮本体。
    final IconButton button = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.share_outlined),
    );
    expect(button.onPressed, isNull);
    expect(called, isFalse);
  });
}
