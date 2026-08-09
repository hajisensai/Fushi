import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码级 guard（补 Phase B code review 的 MEDIUM 发现）。
///
/// [lookup_popup_resize_grip_test.dart] 用 test 里的 `_ResizeTestHost` 平行副本
/// 验证「grip 手势 → resolveDraggedLookupSize → setPopupMax*」这条链，但**守不住
/// 两个真实宿主到底有没有把把手接上**：若有人删掉 base_source_page._buildPopupLayer
/// 或 dictionary_page_mixin.buildNestedPopupLayer 里的 showResizeGrip/onResize*
/// 接线、或把 appUiScale 读错/删掉，行为测试仍全绿。
///
/// 本 guard 直接对两宿主源码断言接线令牌存在，捕获「接线被删」这一失败场景。
/// 令牌是宿主必须保留的最小接线契约；重命名回调可同步更新此清单。
void main() {
  const List<({String path, String name})> hosts =
      <({String path, String name})>[
    (
      path: 'lib/src/pages/base_source_page.dart',
      name: 'reader 家族宿主 (_buildPopupLayer)',
    ),
    (
      path: 'lib/src/pages/implementations/dictionary_page_mixin.dart',
      name: 'video/首页/texthooker 宿主 (buildNestedPopupLayer)',
    ),
  ];

  // 每个宿主都必须保留的最小接线令牌：开启把手 + 四个回调 + 缩放折算 + 落库真值。
  const List<String> requiredTokens = <String>[
    'showResizeGrip: true',
    'onResizeStart:',
    'onResizeUpdate:',
    'onResizeEnd:',
    'onResizeCancel:',
    'appUiScale', // 盒尺寸/折算必须按 UI 缩放换算
    'resolveDraggedLookupSize', // 拖拽尺寸用同源纯函数（唯一真值算法）
    'setPopupMaxWidth', // 落 app 内共享真值（非 overlay/extension 键）
    'setPopupMaxHeight',
  ];

  for (final ({String path, String name}) host in hosts) {
    test('${host.name} 保留弹窗拖拽 resize 接线', () {
      final File file = File(host.path);
      expect(file.existsSync(), isTrue, reason: '宿主文件应存在：${host.path}');
      final String src = file.readAsStringSync();
      for (final String token in requiredTokens) {
        expect(src.contains(token), isTrue,
            reason: '${host.name} 缺少 resize 接线令牌 `$token`——'
                '把手接线被删/改名会让 app 内弹窗拖拽静默失效');
      }
    });
  }
}
