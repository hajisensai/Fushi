// MD3 悬浮底栏「长按拎起选中指示器、拖到目标模块松手」（2026-10-10 用户：
// 「底部栏可以做成长按拖动然后可以有个拖动动画结束拖动然后到达对应模块吗」）。
//
// 钉住：长按拖到另一项松手 → 走 onDragSelect（不走 onTap）；拖回原位 / 拖出
// 胶囊 → 取消；短按仍是普通点击；减弱动态效果下照样能拖选（只是指示器不跟手）。
//
// 设 `FUSHI_PREVIEW=1` 时顺带写两张真实像素截图（拎起、拖动中途），输出目录
// `FUSHI_PREVIEW_OUT`，缺省 `../.claude/preview/module_swipe`（不入库）。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/fushi_icon_fonts.dart';

const String _fontFamily = 'PreviewCJK';

bool get _preview => Platform.environment['FUSHI_PREVIEW'] == '1';

String get _outDir =>
    Platform.environment['FUSHI_PREVIEW_OUT'] ??
    '${Directory.current.path}/../.claude/preview/module_swipe';

final GlobalKey _shotKey = GlobalKey();

List<AdaptiveNavItem> _items() => <AdaptiveNavItem>[
  AdaptiveNavItem(icon: FushiIcons.home, label: '首页'),
  AdaptiveNavItem(icon: FushiIcons.books, label: '书架'),
  AdaptiveNavItem(icon: FushiIcons.manga, label: '漫画'),
  AdaptiveNavItem(icon: FushiIcons.video, label: '视频'),
];

class _Recorder {
  final List<int> taps = <int>[];
  final List<int> drags = <int>[];
}

Future<_Recorder> _pumpBar(
  WidgetTester tester, {
  bool reduceMotion = false,
}) async {
  const double dpr = 2.5;
  tester.view.physicalSize = const Size(400, 300) * dpr;
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.reset);
  if (_preview) {
    await tester.runAsync(() async {
      await loadFushiIconFonts();
      final File font = File(r'C:\Windows\Fonts\NotoSansSC-VF.ttf');
      if (font.existsSync()) {
        final FontLoader loader = FontLoader(_fontFamily)
          ..addFont(
            Future<ByteData>.value(
              ByteData.sublistView(await font.readAsBytes()),
            ),
          );
        await loader.load();
      }
    });
  }
  final _Recorder recorder = _Recorder();
  int current = 0;
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: _preview ? _fontFamily : null,
      ),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: RepaintBoundary(key: _shotKey, child: child),
      ),
      home: FushiFocusRoot(
        child: StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) => Scaffold(
            body: const SizedBox.expand(),
            bottomNavigationBar: Builder(
              builder: (BuildContext context) => adaptiveBottomBar(
                context: context,
                currentIndex: current,
                onTap: (int i) {
                  recorder.taps.add(i);
                  setState(() => current = i);
                },
                onDragSelect: (int i) {
                  recorder.drags.add(i);
                  setState(() => current = i);
                },
                items: _items(),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return recorder;
}

Offset _center(WidgetTester tester, String label) =>
    tester.getCenter(find.text(label).hitTestable());

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_preview) return;
  final RenderRepaintBoundary boundary =
      _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  for (int i = 0; i < 20 && boundary.debugNeedsPaint; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.runAsync(() async {
    final ui.Image image = await boundary.toImage(
      pixelRatio: tester.view.devicePixelRatio,
    );
    final ByteData? bytes = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    image.dispose();
    final File out = File('$_outDir/$name.png');
    out.parent.createSync(recursive: true);
    await out.writeAsBytes(bytes!.buffer.asUint8List());
  });
}

/// 按住 [from] 等过系统长按阈值，再分几步挪到 [to]。
Future<TestGesture> _longPressAndDrag(
  WidgetTester tester,
  Offset from,
  Offset to, {
  String? liftShot,
  String? midShot,
}) async {
  final TestGesture gesture = await tester.startGesture(from);
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 200));
  if (liftShot != null) await _capture(tester, liftShot);
  const int steps = 8;
  for (int i = 1; i <= steps; i++) {
    await gesture.moveTo(Offset.lerp(from, to, i / steps)!);
    await tester.pump(const Duration(milliseconds: 16));
    if (i == steps ~/ 2 && midShot != null) {
      // 让被罩住那一项的图标换色过渡走完再拍。
      await tester.pump(const Duration(milliseconds: 250));
      await _capture(tester, midShot);
    }
  }
  return gesture;
}

void main() {
  testWidgets('长按拖到另一项松手：切到那一项，走 onDragSelect 而不是 onTap', (
    WidgetTester tester,
  ) async {
    final _Recorder recorder = await _pumpBar(tester);
    final TestGesture gesture = await _longPressAndDrag(
      tester,
      _center(tester, '首页'),
      _center(tester, '漫画'),
      liftShot: '07_bar_drag_lifted',
      midShot: '08_bar_drag_mid',
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(recorder.drags, <int>[2]);
    expect(recorder.taps, isEmpty, reason: '长按拖选不是一次点击');
  });

  testWidgets('拖回原位松手：取消，不切换', (WidgetTester tester) async {
    final _Recorder recorder = await _pumpBar(tester);
    final Offset home = _center(tester, '首页');
    final TestGesture gesture = await _longPressAndDrag(
      tester,
      home,
      _center(tester, '视频'),
    );
    for (int i = 1; i <= 8; i++) {
      await gesture.moveTo(Offset.lerp(_center(tester, '视频'), home, i / 8)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(recorder.drags, isEmpty);
    expect(recorder.taps, isEmpty);
  });

  testWidgets('拖出胶囊再松手：取消，不切换', (WidgetTester tester) async {
    final _Recorder recorder = await _pumpBar(tester);
    final Offset from = _center(tester, '首页');
    final TestGesture gesture = await _longPressAndDrag(
      tester,
      from,
      _center(tester, '漫画'),
    );
    await gesture.moveTo(_center(tester, '漫画') - const Offset(0, 160));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(recorder.drags, isEmpty);
    expect(recorder.taps, isEmpty);
  });

  testWidgets('短按仍是普通点击', (WidgetTester tester) async {
    final _Recorder recorder = await _pumpBar(tester);
    await tester.tapAt(_center(tester, '视频'));
    await tester.pumpAndSettle();
    expect(recorder.taps, <int>[3]);
    expect(recorder.drags, isEmpty);
  });

  testWidgets('减弱动态效果：指示器不跟手，但松手后照样直接切到目标', (WidgetTester tester) async {
    final _Recorder recorder = await _pumpBar(tester, reduceMotion: true);
    final TestGesture gesture = await _longPressAndDrag(
      tester,
      _center(tester, '首页'),
      _center(tester, '视频'),
    );
    await gesture.up();
    // 减弱动态效果下没有弹簧：一帧就落定。
    await tester.pump();
    expect(recorder.drags, <int>[3]);
    expect(recorder.taps, isEmpty);
  });

  testWidgets('拖选手势不进无障碍树：读屏长按动作不会把用户甩到最左一项', (WidgetTester tester) async {
    // 长按识别器默认会给语义树挂一个 longPress 动作，它用 Offset.zero 回放
    // start/end：读屏用户双击按住 → 松手点落在胶囊最左 → 静默切到第一项。
    final SemanticsHandle handle = tester.ensureSemantics();
    final _Recorder recorder = await _pumpBar(tester);
    final List<SemanticsNode> withLongPress = <SemanticsNode>[];
    void visit(SemanticsNode node) {
      if (node.getSemanticsData().hasAction(SemanticsAction.longPress)) {
        withLongPress.add(node);
      }
      node.visitChildren((SemanticsNode child) {
        visit(child);
        return true;
      });
    }

    visit(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
    expect(withLongPress, isEmpty);
    expect(recorder.drags, isEmpty);
    handle.dispose();
  });
}
