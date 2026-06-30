import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-872 源码守卫：app 外查词窗的卡片定位分流。
///
/// 红线（用户需求②）——只有悬浮字幕条入口（带 anchorRect）才贴被查字旁定位，其它入口
/// （系统 PROCESS_TEXT / hibiki://lookup → anchorRect == null）必须保持原 [Alignment]
/// .topCenter 贴顶，零变化。Native Kotlin/Java + 全屏弹窗坐标系无法在 Dart host 跑真
/// 渲染，故在源码层钉死这条分流契约：
///   * 仍存在 anchorRect == null → Alignment.topCenter 分支；
///   * anchorRect 非空走 computeFloatingLyricPopupRect + Positioned；
///   * anchorRect 纳入 didUpdateWidget 的复用判定（常驻热页连续点不同字位置要更新）。
void main() {
  String read(String relative) => File(relative).readAsStringSync();

  group('TODO-872 popup card placement routing', () {
    test(
      'PopupDictionaryPage keeps topCenter for null anchor and only positions '
      'by glyph rect when an anchor is supplied',
      () {
        final String src =
            read('lib/src/pages/implementations/popup_dictionary_page.dart');

        expect(src, contains('final Rect? anchorRect;'),
            reason: 'anchorRect 是可空锚点字段（null = 非悬浮字幕入口）');

        final int methodStart = src.indexOf('_buildPositionedCard');
        expect(methodStart, isNonNegative,
            reason: '卡片定位收口在 _buildPositionedCard');
        final String method = src.substring(methodStart);

        expect(method, contains('if (anchor == null)'),
            reason: 'anchorRect 为 null 必须走默认贴顶分支');
        expect(method, contains('alignment: Alignment.topCenter'),
            reason: '默认分支必须保持原 topCenter 贴顶（零变化）');
        expect(method, contains('computeFloatingLyricPopupRect'),
            reason: '非空 anchor 必须用纯函数算贴字旁位置');
        expect(method, contains('Positioned('),
            reason: '非空 anchor 用 Positioned(left/top) 定位');
      },
    );

    test('anchorRect changes participate in the warm-page reuse decision', () {
      final String src =
          read('lib/src/pages/implementations/popup_dictionary_page.dart');

      final int didUpdateStart = src.indexOf('void didUpdateWidget');
      expect(didUpdateStart, isNonNegative);
      final int didUpdateEnd = src.indexOf('void dispose', didUpdateStart);
      expect(didUpdateEnd, greaterThan(didUpdateStart));
      final String didUpdate = src.substring(didUpdateStart, didUpdateEnd);

      expect(
        didUpdate,
        contains('oldWidget.anchorRect != widget.anchorRect'),
        reason: '同一常驻热页连续点不同字位置时，anchorRect 变化必须触发重定位',
      );
    });

    test(
      'popup_main converts the physical-px anchor to logical px and forwards '
      'it to PopupDictionaryPage',
      () {
        final String src = read('lib/popup_main.dart');

        expect(src, contains('Rect? _anchorRect'), reason: '宿主存当前锚点（可空）');
        expect(src, contains('_toLogicalRect('),
            reason: '原生侧物理像素必须 ÷ devicePixelRatio 换算成逻辑像素');
        expect(src, contains('devicePixelRatio'),
            reason: '换算必须用真实 devicePixelRatio');
        expect(src, contains('anchorRect: _anchorRect'),
            reason: '锚点必须透传给 PopupDictionaryPage');
      },
    );
  });
}
