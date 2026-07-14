// spec 2026-07-10 剪贴板独立弹窗 — Task 1：剪贴板查词去向枚举的存储 roundtrip
// 与「未知/空值回退 main」契约（存量用户升级后行为零变化的地基）。

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/preferences_repository.dart';

void main() {
  group('DesktopClipboardDestination.fromStorage', () {
    test('roundtrip 三值', () {
      for (final DesktopClipboardDestination d
          in DesktopClipboardDestination.values) {
        expect(DesktopClipboardDestination.fromStorage(d.storageValue), d);
      }
    });

    test('未知/空值回退 panel（用户拍板：默认独立窗口而非主窗口）', () {
      expect(
        DesktopClipboardDestination.fromStorage(''),
        DesktopClipboardDestination.panel,
      );
      expect(
        DesktopClipboardDestination.fromStorage('bogus'),
        DesktopClipboardDestination.panel,
      );
    });

    test('storageValue 稳定（持久化契约，改字符串=破坏存量偏好）', () {
      expect(DesktopClipboardDestination.main.storageValue, 'main');
      expect(DesktopClipboardDestination.panel.storageValue, 'panel');
      expect(DesktopClipboardDestination.transient.storageValue, 'transient');
      expect(DesktopClipboardDestination.textWindow.storageValue, 'textWindow');
    });
  });
}
