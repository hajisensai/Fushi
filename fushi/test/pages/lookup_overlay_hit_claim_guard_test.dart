import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart'
    show lookupOverlayHitClaim;

import '../helpers/source_guard.dart' show maskComments;

/// BUG-2633 守卫：查词浮层的悬停探针 `MouseRegion(opaque: false)` 必须由
/// [lookupOverlayHitClaim] 在**外面**认领命中，否则整个查词 overlay entry 对命中测试
/// 透明——弹窗上滚滚轮，词典滚了、视频音量也跟着变（用户报「查词框滚轮穿透」）。
///
/// 三条各钉一半：
///   ① 几何事实（Flutter 语义）：`MouseRegion(opaque: false)` 的 `hitTest` 恒为 false，
///      包在它里面的 opaque 吸收层认领了命中也会被丢掉，根 Overlay 继续测下面的页面；
///   ② 修法有效：同一结构外面包 [lookupOverlayHitClaim] 后，页面 Listener 一个
///      PointerSignal 都收不到，而探针的 enter/exit 仍然工作（hover 语义未变）；
///   ③ 接线守卫：视频页两处探针（浮层内容 / barrier）都真的包了；
///   ④ 全树守卫：`lib/` 下**任何**非 opaque 的 MouseRegion 都得被认领壳包住——③ 只
///      钉现有这两处，别的宿主（阅读器 / 词典页 / texthooker / 网页视频）将来新加
///      一个探针不会被它拦住，而那正是 BUG-2633 的复发形态。
///
/// 用与真页面同形的最小复刻（真页面要起 AppModel/WebView，跑不动），事件用
/// [TestPointer] 的 hover + scroll 走真实 hit-test，与 video_wheel_volume_itest 同范式。
void main() {
  Future<int> pageSignalsWith(
    WidgetTester tester, {
    required Widget Function(Widget probe) wrapProbe,
    required List<PointerEnterEvent> enters,
  }) async {
    int pageSignals = 0;
    final OverlayEntry pageEntry = OverlayEntry(
      builder: (BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerSignal: (PointerSignalEvent _) => pageSignals++,
        child: const SizedBox.expand(),
      ),
    );
    // 浮层 entry：与 `_buildPopupOverlay` 同形——barrier + 一层弹窗，两处都套着
    // `opaque: false` 的悬停探针。
    Widget probe(Widget child) => MouseRegion(
          opaque: false,
          onEnter: enters.add,
          child: child,
        );
    final OverlayEntry popupEntry = OverlayEntry(
      builder: (BuildContext context) => Stack(
        children: <Widget>[
          Positioned.fill(
            child: wrapProbe(
              probe(
                Listener(
                  behavior: HitTestBehavior.translucent,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTapUp: (TapUpDetails _) {},
                    child: const ColoredBox(color: Colors.transparent),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 100,
            top: 100,
            width: 200,
            height: 120,
            child: wrapProbe(
              probe(
                // TODO-805 同款：弹窗矩形的 opaque 吸收层。
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: const ColoredBox(color: Colors.black),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Overlay(initialEntries: <OverlayEntry>[pageEntry, popupEntry]),
      ),
    );
    final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
    // 弹窗矩形内 + barrier 空白处各滚一次。
    for (final Offset at in const <Offset>[Offset(200, 160), Offset(40, 300)]) {
      await tester.sendEventToBinding(pointer.hover(at));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 40)));
      await tester.pump();
    }
    await tester.sendEventToBinding(pointer.removePointer());
    await tester.pump();
    return pageSignals;
  }

  testWidgets('① 裸 MouseRegion(opaque:false) 探针让页面收得到浮层上的滚轮（几何事实）',
      (WidgetTester tester) async {
    final List<PointerEnterEvent> enters = <PointerEnterEvent>[];
    final int leaked = await pageSignalsWith(
      tester,
      wrapProbe: (Widget probe) => probe,
      enters: enters,
    );
    expect(leaked, 2,
        reason: 'opaque:false 的 MouseRegion 把子树命中翻成 false，'
            '弹窗矩形与 barrier 上的滚轮都会穿到页面——这就是 BUG-2633 的机制');
  });

  testWidgets('② 探针外包 lookupOverlayHitClaim 后滚轮不再穿透，hover 探针照常工作',
      (WidgetTester tester) async {
    final List<PointerEnterEvent> enters = <PointerEnterEvent>[];
    final int leaked = await pageSignalsWith(
      tester,
      wrapProbe: (Widget probe) => lookupOverlayHitClaim(child: probe),
      enters: enters,
    );
    expect(leaked, 0, reason: '认领层在探针外面，浮层 entry 重新吞掉命中');
    expect(enters, isNotEmpty,
        reason: '探针仍是非 opaque 的 MouseRegion，进浮层时 enter 照常回报；'
            'hover 归属本身是变了的（barrier 会收到 exit），见 lookupOverlayHitClaim 的文档');
  });

  test('③ 视频页两处悬停探针都经 lookupOverlayHitClaim 认领命中', () {
    final String src = File(
      'lib/src/pages/implementations/video_fushi_page.dart',
    ).readAsStringSync();
    // 浮层内容探针：wrapContent → _wrapPopupHoverProbe。
    final int probe =
        src.indexOf('Widget _wrapPopupHoverProbe(Widget child) =>');
    expect(probe, greaterThan(-1), reason: '探针改名了？同步更新本守卫');
    final String probeBody = src.substring(probe, probe + 400);
    final int claimAt = probeBody.indexOf('lookupOverlayHitClaim(');
    final int regionAt = probeBody.indexOf('MouseRegion(');
    expect(claimAt, greaterThan(-1),
        reason: '_wrapPopupHoverProbe 必须用 lookupOverlayHitClaim 认领命中');
    expect(claimAt, lessThan(regionAt),
        reason: '认领层必须是 MouseRegion(opaque:false) 的祖先——放在里面会被探针翻成 false');
    // barrier 探针：Positioned.fill 里那层 MouseRegion(onExit: _handlePointerLeftLookupSurface)。
    final int exitAt = src.indexOf('_handlePointerLeftLookupSurface(),');
    expect(exitAt, greaterThan(-1), reason: 'barrier 探针改名了？同步更新本守卫');
    final String before = src.substring(exitAt - 700, exitAt);
    final int barrierClaim = before.lastIndexOf('lookupOverlayHitClaim(');
    final int barrierRegion = before.lastIndexOf('MouseRegion(');
    expect(barrierClaim, greaterThan(-1),
        reason:
            'barrier 外面的 MouseRegion(opaque:false) 也必须由 lookupOverlayHitClaim 包住');
    expect(barrierClaim, lessThan(barrierRegion), reason: '认领层要在 barrier 探针外面');
  });

  test('④ 查词浮层宿主里的非 opaque MouseRegion 一律要经认领壳', () {
    // ③ 只钉视频页现有那两处。BUG-2633 的复发形态是「某个宿主新加一个悬停探针」——
    // 那时整个 overlay entry 会再次对命中透明，而且照样只在真机滚轮上才看得见。
    //
    // 扫描面取「构造 LookupDismissBarrier 的文件」而不是整个 lib/：`opaque: false`
    // 在别处（控制条自动隐藏、字幕悬停、popover）是**正当**用法——那些 MouseRegion
    // 本来就该让命中穿过去。只有铺在查词 overlay entry 里的探针不能这么干。
    //
    // 判据全在 maskComments 之后的语料上跑：注释里提这个写法不算（本守卫与
    // lookupOverlayHitClaim 的文档都提了），注释里的认领壳也不算数。掩码保持偏移，
    // 所以行号与前文窗口仍然对得上原文。
    final RegExp probe = RegExp(r'MouseRegion\(\s*opaque:\s*false');
    final List<String> hosts = <String>[];
    final List<String> offenders = <String>[];
    for (final FileSystemEntity entity
        in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String code = maskComments(entity.readAsStringSync());
      if (!code.contains('LookupDismissBarrier(')) continue;
      hosts.add(entity.path);
      for (final RegExpMatch m in probe.allMatches(code)) {
        final int from = m.start - 260 < 0 ? 0 : m.start - 260;
        if (code.substring(from, m.start).contains('lookupOverlayHitClaim(')) {
          continue;
        }
        final int line = code
                .substring(0, m.start)
                .codeUnits
                .where((int c) => c == 10)
                .length +
            1;
        offenders.add('${entity.path}:$line');
      }
    }
    expect(hosts, isNotEmpty, reason: '一个查词浮层宿主都没扫到？本守卫的判据失效了');
    expect(offenders, isEmpty,
        reason: 'MouseRegion(opaque: false) 的 hitTest 恒为 false，会让它上面整棵子树'
            '认领的命中全部作废、事件穿到下面的页面（BUG-2633）。查词浮层里的探针要么'
            '用 lookupOverlayHitClaim 在外面认领命中，要么别用 opaque: false。'
            '命中泄漏点：$offenders');
  });
}
