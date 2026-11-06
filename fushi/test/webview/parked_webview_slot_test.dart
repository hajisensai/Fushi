import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/webview/parked_webview_slot.dart';
import 'package:material_ui/material_ui.dart';

/// BUG-3913：歌词 WebView 在「覆盖层 ↔ 屏外停放」之间搬家时必须是同一个实例。
///
/// Windows 上每新建一个 WebView 都留下一份不归还的显存，阅读器因此改成整页存活期间
/// 复用歌词 WebView：退出歌词模式时把它（按同一个 GlobalKey）停到 [ParkedWebViewSlot]，
/// 再进入时搬回覆盖层。这里用一个记录生命周期的探针代替 WebView，按阅读器的真实
/// 结构（主 Stack 同一个孩子位；覆盖层里 WebView 在 LayoutBuilder 下的
/// Positioned.fromRect 里）来回切换，钉住：State 只建一次、从不 dispose；停放时不绘制、
/// 不吃点击、拿不到焦点、动画暂停、尺寸保持。
class _Lifecycle {
  int inits = 0;
  int disposes = 0;
  final List<State<StatefulWidget>> states = <State<StatefulWidget>>[];
}

class _Probe extends StatefulWidget {
  const _Probe({super.key, required this.lifecycle, required this.onTap});

  final _Lifecycle lifecycle;
  final VoidCallback onTap;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  final FocusNode focusNode = FocusNode(debugLabel: 'probe');
  bool tickersEnabled = true;
  Size? laidOutSize;

  @override
  void initState() {
    super.initState();
    widget.lifecycle.inits++;
    widget.lifecycle.states.add(this);
  }

  @override
  void dispose() {
    widget.lifecycle.disposes++;
    focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    tickersEnabled = TickerMode.valuesOf(context).enabled;
    return Focus(
      focusNode: focusNode,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            laidOutSize = constraints.biggest;
            return const SizedBox.expand();
          },
        ),
      ),
    );
  }
}

const Rect _overlayRect = Rect.fromLTWH(400, 100, 300, 500);

class _Host extends StatelessWidget {
  const _Host({
    required this.active,
    required this.retained,
    required this.parkedSize,
    required this.probe,
  });

  final bool active;
  final bool retained;
  final Size? parkedSize;
  final Widget probe;

  @override
  Widget build(BuildContext context) {
    final Widget slot;
    if (active) {
      // 与阅读器的歌词覆盖层同构：Stack 孩子位上的 Positioned.fill →
      // LayoutBuilder → Stack → Positioned.fromRect(WebView)。
      slot = Positioned.fill(
        child: RepaintBoundary(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              return Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  Positioned.fromRect(rect: _overlayRect, child: probe),
                ],
              );
            },
          ),
        ),
      );
    } else if (retained) {
      slot = ParkedWebViewSlot(size: parkedSize, child: probe);
    } else {
      slot = const SizedBox.shrink();
    }
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: <Widget>[
          const Positioned.fill(child: ColoredBox(color: Color(0xFF000000))),
          slot,
        ],
      ),
    );
  }
}

void main() {
  testWidgets('进出覆盖层多轮：同一个 State，从不 dispose、从不重建', (WidgetTester tester) async {
    final _Lifecycle lifecycle = _Lifecycle();
    final GlobalKey key = GlobalKey(debugLabel: 'lyrics_webview');
    Widget host({required bool active}) => _Host(
      active: active,
      retained: true,
      parkedSize: _overlayRect.size,
      probe: _Probe(key: key, lifecycle: lifecycle, onTap: () {}),
    );

    await tester.pumpWidget(host(active: true));
    final State<StatefulWidget> first = lifecycle.states.single;
    for (int round = 0; round < 5; round++) {
      await tester.pumpWidget(host(active: false));
      await tester.pumpWidget(host(active: true));
    }
    expect(lifecycle.inits, 1, reason: '每进出一轮新建一次 = 每轮一份原生 WebView');
    expect(lifecycle.disposes, 0);
    expect(identical(key.currentState, first), isTrue);
  });

  testWidgets('停放：不绘制、不吃点击、拿不到焦点、动画暂停、尺寸保持', (WidgetTester tester) async {
    final _Lifecycle lifecycle = _Lifecycle();
    final GlobalKey key = GlobalKey(debugLabel: 'lyrics_webview');
    int taps = 0;
    Widget host({required bool active}) => _Host(
      active: active,
      retained: true,
      parkedSize: _overlayRect.size,
      probe: _Probe(key: key, lifecycle: lifecycle, onTap: () => taps++),
    );

    await tester.pumpWidget(host(active: true));
    final _ProbeState state = key.currentState! as _ProbeState;
    expect(state.tickersEnabled, isTrue);
    await tester.tapAt(_overlayRect.center);
    expect(taps, 1, reason: '在场时正常收点击（对照）');

    await tester.pumpWidget(host(active: false));
    expect(identical(key.currentState, state), isTrue);
    expect(find.byKey(key), findsNothing, reason: 'Offstage：默认 finder 看不到');
    expect(find.byKey(key, skipOffstage: false), findsOneWidget);
    expect(state.tickersEnabled, isFalse, reason: '停放期间动画暂停');
    expect(
      state.laidOutSize,
      _overlayRect.size,
      reason: '停放尺寸与离开覆盖层时一致：Windows 侧不因停放重新下发尺寸',
    );

    // 停放位在左上角 (0,0)-(300,500)：点进去也不能落到 WebView 上。
    await tester.tapAt(const Offset(150, 250));
    expect(taps, 1, reason: '停放的 WebView 不参与命中测试');

    state.focusNode.requestFocus();
    await tester.pump();
    expect(state.focusNode.hasFocus, isFalse, reason: '停放的 WebView 不能抢键盘焦点');

    await tester.pumpWidget(host(active: true));
    expect(state.tickersEnabled, isTrue);
    expect(state.laidOutSize, _overlayRect.size);
    await tester.tapAt(_overlayRect.center);
    expect(taps, 2, reason: '搬回覆盖层后照常收点击');
  });

  testWidgets('量不到尺寸时铺满父级', (WidgetTester tester) async {
    final _Lifecycle lifecycle = _Lifecycle();
    final GlobalKey key = GlobalKey(debugLabel: 'lyrics_webview');
    await tester.pumpWidget(
      _Host(
        active: false,
        retained: true,
        parkedSize: null,
        probe: _Probe(key: key, lifecycle: lifecycle, onTap: () {}),
      ),
    );
    final _ProbeState state = key.currentState! as _ProbeState;
    expect(
      state.laidOutSize,
      tester.view.physicalSize / tester.view.devicePixelRatio,
    );
  });

  testWidgets('未挂上过（retained=false）：零尺寸占位，不创建实例', (WidgetTester tester) async {
    final _Lifecycle lifecycle = _Lifecycle();
    final GlobalKey key = GlobalKey(debugLabel: 'lyrics_webview');
    await tester.pumpWidget(
      _Host(
        active: false,
        retained: false,
        parkedSize: null,
        probe: _Probe(key: key, lifecycle: lifecycle, onTap: () {}),
      ),
    );
    expect(lifecycle.inits, 0);
    expect(find.byKey(key, skipOffstage: false), findsNothing);
  });
}
