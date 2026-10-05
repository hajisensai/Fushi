// BUG-2953：视频页查词弹窗里右键「复制」，菜单跑到查词框后面。
//
// 根因：视频页 / 网页视频 / 首页词典 / texthooker 把查词浮层用 `overlay.insert` 手动挂进
// 根 Navigator 的 Overlay；之后 Navigator 每次 push 都 `overlay.rearrange(路由 entries)`，
// 而 `OverlayState.rearrange` 把不在列表里的旧 entry 排到末尾＝所有路由之上。弹窗里
// `showFushiMenu` / `PopupMenuButton` 推的菜单 route 于是画在浮层**之下**、点不到。
//
// 修法：浮层子树包进 [LookupOverlayNavigator]，菜单推进浮层自带的 Navigator、落在浮层
// 之上。本文件复刻真实层级（根 Overlay 手动 insert 的 entry + 全屏不透明弹窗盒），
// 用「点菜单项能不能选中」这一行为断言层级，并留一条不包装的对照组钉住根因。
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';

class _Probe {
  String? selected;
  int popupPrimaryTaps = 0;
  int pageTaps = 0;
  int popupBuilds = 0;
}

class _HostPage extends StatefulWidget {
  const _HostPage({
    required this.probe,
    required this.wrap,
    required this.pageFocus,
    required this.label,
  });

  final _Probe probe;
  final bool wrap;
  final FocusNode pageFocus;
  final ValueNotifier<String> label;

  @override
  State<_HostPage> createState() => _HostPageState();
}

class _HostPageState extends State<_HostPage> {
  OverlayEntry? _entry;

  @override
  void initState() {
    super.initState();
    widget.label.addListener(_onLabel);
    // 镜像 video_fushi_page._syncPopupOverlay：插到**根** Overlay，跨路由生存。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _entry != null) return;
      final OverlayState overlay = Overlay.of(context, rootOverlay: true);
      final OverlayEntry entry = OverlayEntry(builder: _buildPopupOverlay);
      _entry = entry;
      overlay.insert(entry);
    });
  }

  void _onLabel() => _entry?.markNeedsBuild();

  Future<void> _showMenu(
    BuildContext popupContext,
    Offset globalPosition,
  ) async {
    // 与 dictionary_popup_webview `_showWindowsContextMenu` 同一锚点算法与菜单 helper。
    final RenderBox overlayBox =
        Overlay.of(popupContext).context.findRenderObject()! as RenderBox;
    final Offset anchor = overlayBox.globalToLocal(globalPosition);
    final Size size = overlayBox.size;
    widget.probe.selected = await showFushiMenu<String>(
      context: popupContext,
      position: RelativeRect.fromLTRB(
        anchor.dx,
        anchor.dy,
        size.width - anchor.dx,
        size.height - anchor.dy,
      ),
      items: const <PopupMenuEntry<String>>[
        PopupMenuItem<String>(value: 'search', child: Text('SEARCH')),
        PopupMenuItem<String>(value: 'copy', child: Text('COPY')),
      ],
    );
  }

  // 镜像宿主 _buildPopupOverlay：中和器 + Stack，弹窗盒占据画面中央大块区域。
  Widget _buildPopupOverlay(BuildContext overlayContext) {
    final Widget content = FushiAppUiScaleNeutralizer(
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned(
            left: 100,
            top: 100,
            width: 500,
            height: 400,
            child: Builder(
              builder: (BuildContext popupContext) {
                widget.probe.popupBuilds++;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => widget.probe.popupPrimaryTaps++,
                  onSecondaryTapDown: (TapDownDetails d) =>
                      _showMenu(popupContext, d.globalPosition),
                  child: ColoredBox(
                    color: const Color(0xFF224466),
                    child: Text(widget.label.value),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
    return widget.wrap ? LookupOverlayNavigator(child: content) : content;
  }

  @override
  void dispose() {
    widget.label.removeListener(_onLabel);
    _entry?.remove();
    _entry?.dispose();
    _entry = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Focus(
      focusNode: widget.pageFocus,
      autofocus: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.probe.pageTaps++,
        child: const SizedBox.expand(
          child: ColoredBox(color: Color(0xFF000000)),
        ),
      ),
    ),
  );
}

Future<void> _pumpHost(
  WidgetTester tester, {
  required _Probe probe,
  required bool wrap,
  required FocusNode pageFocus,
  ValueNotifier<String>? label,
}) async {
  tester.view.physicalSize = const Size(1000, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (BuildContext context, Widget? child) =>
          FushiAppUiScale(scale: 1.25, child: child!),
      home: _HostPage(
        probe: probe,
        wrap: wrap,
        pageFocus: pageFocus,
        label: label ?? ValueNotifier<String>('popup'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _rightClick(WidgetTester tester, Offset at) async {
  final TestGesture gesture = await tester.startGesture(
    at,
    buttons: kSecondaryMouseButton,
    kind: PointerDeviceKind.mouse,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('BUG-2953: menu opened from the root-overlay popup is above it', (
    WidgetTester tester,
  ) async {
    final _Probe probe = _Probe();
    final FocusNode pageFocus = FocusNode(debugLabel: 'page');
    addTearDown(pageFocus.dispose);
    await _pumpHost(tester, probe: probe, wrap: true, pageFocus: pageFocus);

    await _rightClick(tester, const Offset(300, 300));
    expect(find.text('COPY'), findsOneWidget);

    // 层级断言：菜单项中心点的命中测试最先落到菜单项，而不是下面的弹窗盒。
    final Offset copyAt = tester.getCenter(find.text('COPY'));
    final HitTestResult hit = tester.hitTestOnBinding(copyAt);
    final RenderObject copyText = tester.renderObject(find.text('COPY'));
    final RenderObject popupBox = tester.renderObject(
      find.byWidgetPredicate(
        (Widget w) => w is ColoredBox && w.color == const Color(0xFF224466),
      ),
    );
    final List<Object> targets = hit.path
        .map((HitTestEntry e) => e.target)
        .toList();
    expect(targets, contains(copyText));
    expect(targets, isNot(contains(popupBox)), reason: '菜单必须挡住弹窗：命中链里不该出现弹窗盒');

    await tester.tapAt(copyAt);
    await tester.pumpAndSettle();
    expect(probe.selected, 'copy');
    expect(probe.popupPrimaryTaps, 0, reason: '点菜单项不能穿到弹窗上');
  });

  testWidgets('control: without the wrapper the menu sinks under the popup '
      '(Overlay.rearrange floats foreign entries above routes)', (
    WidgetTester tester,
  ) async {
    final _Probe probe = _Probe();
    final FocusNode pageFocus = FocusNode(debugLabel: 'page');
    addTearDown(pageFocus.dispose);
    await _pumpHost(tester, probe: probe, wrap: false, pageFocus: pageFocus);

    await _rightClick(tester, const Offset(300, 300));
    expect(find.text('COPY'), findsOneWidget);
    await tester.tapAt(
      tester.getCenter(find.text('COPY')),
      buttons: kPrimaryButton,
    );
    await tester.pumpAndSettle();
    // 菜单在弹窗之下：这一下落到弹窗盒上，菜单项选不中（这就是用户看到的现象）。
    expect(probe.popupPrimaryTaps, 1);
    expect(probe.selected, isNull);
  });

  testWidgets('wrapper keeps the overlay hit-transparent, focus untouched and '
      'propagates rebuilds', (WidgetTester tester) async {
    final _Probe probe = _Probe();
    final FocusNode pageFocus = FocusNode(debugLabel: 'page');
    addTearDown(pageFocus.dispose);
    final ValueNotifier<String> label = ValueNotifier<String>('first');
    addTearDown(label.dispose);
    await _pumpHost(
      tester,
      probe: probe,
      wrap: true,
      pageFocus: pageFocus,
      label: label,
    );

    // 挂上浮层不抢媒体页焦点（初始路由 requestFocus: false）。
    expect(pageFocus.hasPrimaryFocus, isTrue);

    // 弹窗盒之外：命中照旧穿到页面（导航层没有 modal barrier）。
    await tester.tapAt(const Offset(950, 750));
    await tester.pump();
    expect(probe.pageTaps, 1);
    expect(probe.popupPrimaryTaps, 0);

    // 宿主 markNeedsBuild 外层 entry → 初始路由里的子树跟着刷新。
    expect(find.text('first'), findsOneWidget);
    label.value = 'second';
    await tester.pump();
    expect(find.text('second'), findsOneWidget);
    expect(find.text('first'), findsNothing);

    // 菜单关掉后焦点回到页面（showFushiMenu 归还打开时的主焦点）。
    await _rightClick(tester, const Offset(300, 300));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('COPY'), findsNothing);
    expect(probe.selected, isNull);
    expect(pageFocus.hasPrimaryFocus, isTrue);
  });

  test('every root-overlay lookup host wraps its popup subtree', () {
    const List<String> hosts = <String>[
      'lib/src/pages/implementations/video_fushi_page.dart',
      'lib/src/pages/implementations/web_video_fushi_page.dart',
      'lib/src/pages/implementations/home_dictionary_page.dart',
      'lib/src/pages/implementations/texthooker_page.dart',
    ];
    for (final String path in hosts) {
      final String src = File(path).readAsStringSync();
      final int fn = src.indexOf(
        'Widget _buildPopupOverlay(BuildContext overlayContext) {',
      );
      expect(fn, isNonNegative, reason: '$path 缺 _buildPopupOverlay');
      final int wrap = src.indexOf('return LookupOverlayNavigator(', fn);
      final int neutralizer = src.indexOf('FushiAppUiScaleNeutralizer(', fn);
      expect(
        wrap,
        isNonNegative,
        reason: '$path 的根 Overlay 浮层必须包 LookupOverlayNavigator（BUG-2953）',
      );
      expect(
        wrap,
        lessThan(neutralizer),
        reason: '$path：导航层在中和器之外，菜单仍在缩放画布空间渲染',
      );
    }
  });
}
