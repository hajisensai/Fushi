import 'dart:io' show File, Platform;

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/drag_drop/drop_surface_scope.dart';
import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart';
import 'package:fushi/src/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/pages/implementations/media_library_shell.dart';
import 'package:fushi/src/pages/implementations/video_library_shell.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// 拖放「谁接这一次 OS drop」的**端到端**守卫（BUG-1752 复审）。
///
/// 与 drop_surface_routing_test.dart 的区别：那边是手写 isActive: () => false 之后
/// 直接调 [DropSurfaceScope.activeFor]，绕开了 [FushiFileDropTarget]，所以把门本身
/// 删掉照样全绿。这里 pump 出真实结构（Offstage 保活的隐藏子视图里挂着真的 drop
/// target），并从 desktop_drop 平台通道灌进真实的 entered / performOperation 事件，
/// 走完整条链路：全局广播 -> paintBounds 命中 -> 门 -> onDrop。
///
/// 复现的用户症状：停在视频 tab 的「发现」子页拖一个文件夹进窗口，隐藏的
/// HomeVideoPage 仍以全屏 paintBounds 命中，直接往 media_sources 插一条常驻扫描根
/// 并跑全量扫描 —— 用户明明在别的子页，只看到一个绿 toast。
bool get _desktopHost =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

const MethodChannel _dropChannel = MethodChannel('desktop_drop');
const StandardMethodCodec _codec = StandardMethodCodec();

/// 从平台侧灌一次真实拖放：先 entered（DropTarget 靠它把自己从 idle 变成 enter，
/// 否则 performOperation 会被它的状态机丢弃），再 performOperation。
Future<void> _performOsDrop(
  WidgetTester tester, {
  Offset at = const Offset(400, 300),
  List<String> paths = const <String>[r'C:\anime\S01'],
}) async {
  final TestDefaultBinaryMessenger messenger =
      tester.binding.defaultBinaryMessenger;
  await messenger.handlePlatformMessage(
    _dropChannel.name,
    _codec.encodeMethodCall(MethodCall('entered', <double>[at.dx, at.dy])),
    (ByteData? _) {},
  );
  await messenger.handlePlatformMessage(
    _dropChannel.name,
    _codec.encodeMethodCall(MethodCall('performOperation', paths)),
    (ByteData? _) {},
  );
  await tester.pump();
}

/// 让逻辑尺寸恰好是 800x600 且不缩放：desktop_drop 在 Windows 上按
/// devicePixelRatio 换算命中点，测试默认 dpr=3 会把落点缩到 (133,100)。
void _pinViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Widget _leaf(String label, List<String> sink) => FushiFileDropTarget(
      debugLabel: label,
      onDrop: (List<String> paths, Offset position) => sink.add(label),
      child: const SizedBox.expand(),
    );

class _NoopScrapeRunner implements VideoSourceScrapeRunner {
  @override
  Future<SourceScrapeReport> scrapeSource(
    SourceLibraryRow source, {
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
    VideoSourceScrapeConfirmationCallback? onConfirmation,
    VideoSourceScrapeBatchContext? batchContext,
  }) async {
    return SourceScrapeReport(sourceIds: <int>[source.id]);
  }
}

void main() {
  group('FushiFileDropTarget 只让看得见的表面接拖放', () {
    testWidgets('隐藏的保活子树不接，可见的接', (WidgetTester tester) async {
      _pinViewport(tester);
      final List<String> dropped = <String>[];
      Widget shell({required bool videoVisible}) => MaterialApp(
            home: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                Offstage(
                  offstage: !videoVisible,
                  child: DropSurfaceScope(
                    isActive: () => videoVisible,
                    child: _leaf('video', dropped),
                  ),
                ),
                Offstage(
                  offstage: videoVisible,
                  child: DropSurfaceScope(
                    isActive: () => !videoVisible,
                    child: _leaf('books', dropped),
                  ),
                ),
              ],
            ),
          );

      await tester.pumpWidget(shell(videoVisible: true));
      await _performOsDrop(tester);
      expect(dropped, <String>['video'],
          reason: '隐藏的书架必须一声不吭 —— Offstage 只关 Flutter 的 hitTest，'
              'desktop_drop 照样全局广播且隐藏子树仍是全屏 paintBounds');

      dropped.clear();
      await tester.pumpWidget(shell(videoVisible: false));
      await tester.pump();
      await _performOsDrop(tester);
      expect(dropped, <String>['books']);
    });

    testWidgets('没有作用域的落点照旧接（对话框 / 播放页行为不变）', (WidgetTester tester) async {
      _pinViewport(tester);
      final List<String> dropped = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Stack(
          fit: StackFit.expand,
          children: <Widget>[_leaf('dialog', dropped)],
        ),
      ));
      await _performOsDrop(tester);
      expect(dropped, <String>['dialog']);
    });

    testWidgets('enabled:false 的落点不接', (WidgetTester tester) async {
      _pinViewport(tester);
      final List<String> dropped = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            FushiFileDropTarget(
              enabled: false,
              debugLabel: 'off',
              onDrop: (List<String> paths, Offset position) =>
                  dropped.add('off'),
              child: const SizedBox.expand(),
            ),
          ],
        ),
      ));
      await _performOsDrop(tester);
      expect(dropped, isEmpty);
    });
  }, skip: !_desktopHost);

  group('MediaLibraryShell：同一个 tab 内部的隐藏子视图也不接', () {
    setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

    testWidgets('切到发现视图后，隐藏的书架不再抢走文件夹', (WidgetTester tester) async {
      _pinViewport(tester);
      final List<String> dropped = <String>[];
      MediaLibraryViewSpec spec(MediaLibraryViewKind kind, String label) =>
          MediaLibraryViewSpec(
            kind: kind,
            label: label,
            builder: (BuildContext context, Widget navigation) => Column(
              children: <Widget>[
                navigation,
                Expanded(child: _leaf(label, dropped)),
              ],
            ),
          );

      await tester.pumpWidget(TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: MediaLibraryShell(
              focusIdPrefix: 'drop-gate-shell',
              views: <MediaLibraryViewSpec>[
                spec(MediaLibraryViewKind.library, 'library'),
                spec(MediaLibraryViewKind.discover, 'discover'),
              ],
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await _performOsDrop(tester);
      expect(dropped, <String>['library']);

      dropped.clear();
      tester
          .widget<FushiSegmentedStrip<MediaLibraryViewKind>>(
            find.byType(FushiSegmentedStrip<MediaLibraryViewKind>),
          )
          .onChanged(MediaLibraryViewKind.discover);
      await tester.pumpAndSettle();

      await _performOsDrop(tester);
      expect(dropped, <String>['discover'],
          reason: '被保活的书架仍在树里、仍是全屏 paintBounds，只有内层作用域挡得住它');
    });
  }, skip: !_desktopHost);

  group('VideoLibraryShell：停在发现子页时本地库不接', () {
    late FushiDatabase database;
    late VideoSourceScrapeTaskController scrapeController;
    late ChangeNotifier refreshSignal;

    setUp(() {
      LocaleSettings.setLocale(AppLocale.zhCn);
      database = FushiDatabase.forTesting(NativeDatabase.memory());
      scrapeController = VideoSourceScrapeTaskController(_NoopScrapeRunner());
      refreshSignal = ChangeNotifier();
    });

    tearDown(() async {
      scrapeController.dispose();
      refreshSignal.dispose();
      await database.close();
    });

    testWidgets('切到发现分区后拖入文件夹，本地库不得登记扫描根', (WidgetTester tester) async {
      _pinViewport(tester);
      final List<String> dropped = <String>[];
      await tester.pumpWidget(TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: VideoLibraryShell(
              repository: VideoBookRepository(database),
              libraryRefreshSignal: refreshSignal,
              scrapeTaskController: scrapeController,
              onScrapeAll: () async {},
              onScrapeSource: (_) async {},
              onVideoScanCompleted: (_, __) async {},
              onOpenScrapeTasks: () {},
              onLibraryChanged: () {},
              localLibraryPageBuilder: (_, Widget navigation, __) => Column(
                children: <Widget>[
                  navigation,
                  Expanded(child: _leaf('local', dropped)),
                ],
              ),
              discoveryPageBuilder: (_, Widget navigation) => Column(
                children: <Widget>[
                  navigation,
                  Expanded(child: _leaf('discover', dropped)),
                ],
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await _performOsDrop(tester);
      expect(dropped, <String>['local'], reason: '停在本地库时本地库当然要接');

      dropped.clear();
      tester
          .widget<FushiSegmentedStrip<VideoLibrarySection>>(
            find.byType(FushiSegmentedStrip<VideoLibrarySection>),
          )
          .onChanged(VideoLibrarySection.discover);
      await tester.pumpAndSettle();

      await _performOsDrop(tester);
      expect(dropped, <String>['discover'],
          reason: '用户停在发现子页，隐藏的 HomeVideoPage 不许把文件夹登记成常驻扫描根');
    });
  }, skip: !_desktopHost);

  group('HomeGamePage：IndexedStack 急切构建全部子区，包裹必须是结构性的', () {
    // 游戏页七个子区各带真依赖（GalHookSessionController / 诊断页 / 在线发现），
    // 在 widget 测试里 pump 不出来，故这一条守的是**结构**：子区表按 GameSection
    // 建、按 GameSection.values 展开，包裹只有一处，新增子区不可能漏掉。
    test('子区按 GameSection.values 展开且逐个套上 DropSurfaceScope', () {
      final String src =
          File('lib/src/pages/implementations/home_game_page.dart')
              .readAsStringSync();
      // 断言字面量：'for (final GameSection section in GameSection.values)'
      expect(
          src.contains('for (final GameSection section in GameSection.values)'),
          isTrue,
          reason: 'IndexedStack 的 children 必须由枚举展开，'
              '否则「索引==枚举序」和「每个子区都被包裹」都只是口头约定');
      // 断言字面量：'isActive: () => _section == section,'
      expect(src.contains('isActive: () => _section == section,'), isTrue,
          reason: '判据必须与 index: _section.index 同源，且在 drop 落地那一刻求值');
      // 断言字面量：'child: sections[section]!,'
      expect(src.contains('child: sections[section]!,'), isTrue,
          reason: '子区内容只能从 GameSection 建的表里取，不许再往 children 里塞裸 widget');
    });
  });
}
