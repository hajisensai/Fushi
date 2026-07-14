// spec 2026-07-10 §4 — 去向路由纯函数全矩阵（3 origin × 3 destination × 2
// overlayAvailable = 18 例）。互斥分区契约：任一输入组合恰好落一个消费面。

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/lookup/desktop_lookup_router.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';

void main() {
  DesktopLookupConsumer resolve(
    DesktopLookupOrigin origin,
    DesktopClipboardDestination destination,
    bool overlayAvailable,
  ) =>
      resolveDesktopLookupConsumer(
        origin: origin,
        destination: destination,
        overlayAvailable: overlayAvailable,
      );

  test('explicit 恒 mainTab（悬浮字幕回落路径），与去向/覆盖窗无关', () {
    for (final DesktopClipboardDestination d
        in DesktopClipboardDestination.values) {
      for (final bool available in <bool>[true, false]) {
        expect(
          resolve(DesktopLookupOrigin.explicit, d, available),
          DesktopLookupConsumer.mainTab,
        );
      }
    }
  });

  test('覆盖窗不可用时 clipboard/hotkey 全部退回 mainTab（请求不丢）', () {
    for (final DesktopLookupOrigin o in <DesktopLookupOrigin>[
      DesktopLookupOrigin.clipboard,
      DesktopLookupOrigin.hotkey,
    ]) {
      for (final DesktopClipboardDestination d
          in DesktopClipboardDestination.values) {
        expect(resolve(o, d, false), DesktopLookupConsumer.mainTab);
      }
    }
  });

  test('覆盖窗可用时 clipboard/hotkey 按去向分区', () {
    for (final DesktopLookupOrigin o in <DesktopLookupOrigin>[
      DesktopLookupOrigin.clipboard,
      DesktopLookupOrigin.hotkey,
    ]) {
      expect(resolve(o, DesktopClipboardDestination.main, true),
          DesktopLookupConsumer.mainTab);
      expect(resolve(o, DesktopClipboardDestination.panel, true),
          DesktopLookupConsumer.panel);
      expect(resolve(o, DesktopClipboardDestination.transient, true),
          DesktopLookupConsumer.transient);
      expect(resolve(o, DesktopClipboardDestination.textWindow, true),
          DesktopLookupConsumer.textWindow);
    }
  });

  test('每个 destination 恰好映射一个非 mainTab 消费面（新增 textWindow 覆盖）', () {
    // 覆盖窗可用 + clipboard origin 下，四个去向各落唯一消费面，互不重叠。
    final Set<DesktopLookupConsumer> seen = <DesktopLookupConsumer>{};
    for (final DesktopClipboardDestination d
        in DesktopClipboardDestination.values) {
      seen.add(resolve(DesktopLookupOrigin.clipboard, d, true));
    }
    expect(seen, <DesktopLookupConsumer>{
      DesktopLookupConsumer.mainTab,
      DesktopLookupConsumer.panel,
      DesktopLookupConsumer.transient,
      DesktopLookupConsumer.textWindow,
    });
  });
}
