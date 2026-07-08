import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/utils/misc/platform_utils.dart';

/// 查词弹窗 / 查词页布局默认值守卫：
///  - TODO-1352：取消查词页宽屏强制内容宽度上限；放宽弹窗最大宽度滑块上限；外部悬浮
///    查词窗宽度统一到用户的 popupMaxWidth（不再硬编码 480）。
///  - TODO-1354：音高读音条按 Niratan 改为行内单行（' | ' 分隔），不再 list-style 竖排。
///  - TODO-1357：桌面查词弹窗默认 2 列 + 默认展开 2 个词典；移动端窄屏默认 1；用户
///    显式设过一律遵从（三态）。
void main() {
  group('TODO-1352 查词页 / 弹窗宽度上限放宽', () {
    test('宽屏查词页取消强制内容宽度上限（dictionary → null 占满，仅留侧向留白）', () {
      // compact 一直是 full-bleed（返回 null）。
      expect(
        desktopContentMaxWidth(
            WindowSizeClass.compact, DesktopContentKind.dictionary),
        isNull,
      );
      // 关键：medium / expanded 宽屏此前锁 1040px，现改为 null（占满）。
      expect(
        desktopContentMaxWidth(
            WindowSizeClass.medium, DesktopContentKind.dictionary),
        isNull,
        reason: 'TODO-1352：查词页宽屏不应再被强制窄栏',
      );
      expect(
        desktopContentMaxWidth(
            WindowSizeClass.expanded, DesktopContentKind.dictionary),
        isNull,
        reason: 'TODO-1352：查词页宽屏应占满（null）',
      );
      // 书架 / 设置的上限不受牵连（仅动 dictionary）。
      expect(
        desktopContentMaxWidth(
            WindowSizeClass.expanded, DesktopContentKind.readerShelf),
        1280,
      );
      expect(
        desktopContentMaxWidth(
            WindowSizeClass.expanded, DesktopContentKind.settings),
        960,
      );
    });

    test('弹窗最大宽度滑块上限放宽到 2000', () {
      final String src = File(
        'lib/src/settings/settings_schema_lookup.dart',
      ).readAsStringSync();
      // 定位 popup_max_width 滑块的 max。
      final int idx = src.indexOf("id: 'lookup.popup_max_width'");
      expect(idx, greaterThan(-1));
      final String block = src.substring(idx, idx + 400);
      expect(block.contains('max: 2000'), isTrue,
          reason: 'TODO-1352：弹窗最大宽度上限应放宽到 2000');
      expect(block.contains('max: 1000'), isFalse,
          reason: 'TODO-1352：旧的 1000 强制上限应已移除');
    });

    test('外部悬浮查词窗宽度统一到 popupMaxWidth（不再硬编码 480）', () {
      final String src = File(
        'lib/src/pages/implementations/popup_dictionary_page.dart',
      ).readAsStringSync();
      expect(src.contains('appModel.popupMaxWidth'), isTrue,
          reason: 'TODO-1352：外部悬浮查词窗应读用户的 popupMaxWidth');
      expect(src.contains('maxCardWidth = 480'), isFalse,
          reason: 'TODO-1352：480 魔法数应已移除');
    });
  });

  group('TODO-1354 音高读音条行内化（对齐 Niratan）', () {
    final String css = File('assets/popup/popup.css').readAsStringSync();

    test('.pitch-entries 改为行内、不再 list-style circle 竖排', () {
      final RegExp rule =
          RegExp(r'\.pitch-entries\s*\{([^}]*)\}', multiLine: true);
      final RegExpMatch? m = rule.firstMatch(css);
      expect(m, isNotNull);
      final String body = m!.group(1)!;
      expect(body.contains('display: inline'), isTrue,
          reason: 'TODO-1354：音高读音条应行内呈现');
      expect(body.contains('list-style: circle'), isFalse,
          reason: 'TODO-1354：不应再用 circle 项目符号竖排（数字浮动根因）');
    });

    test('多条音高用暗淡 " | " 分隔（Niratan 观感）', () {
      expect(
        css.contains('.pitch-entries > li:not(:last-child)::after'),
        isTrue,
      );
      // 分隔符文本与暗淡度。
      final int idx =
          css.indexOf('.pitch-entries > li:not(:last-child)::after');
      final String block = css.substring(idx, idx + 160);
      expect(block.contains('content: " | "'), isTrue);
      expect(block.contains('opacity: 0.6'), isTrue);
    });
  });

  group('TODO-1357 桌面默认 2 列 + 2 词典（三态）', () {
    test('未设过：桌面默认 2、移动默认 1', () {
      expect(
        AppModel.resolvePopupDesktopDefault(
            hasExplicit: false, stored: 1, isDesktop: true),
        2,
      );
      expect(
        AppModel.resolvePopupDesktopDefault(
            hasExplicit: false, stored: 1, isDesktop: false),
        1,
      );
    });

    test('用户显式设过：一律遵从其值（不被平台默认覆盖）', () {
      expect(
        AppModel.resolvePopupDesktopDefault(
            hasExplicit: true, stored: 1, isDesktop: true),
        1,
        reason: 'TODO-1357：桌面上用户显式设 1 列必须尊重',
      );
      expect(
        AppModel.resolvePopupDesktopDefault(
            hasExplicit: true, stored: 4, isDesktop: false),
        4,
        reason: 'TODO-1357：移动端用户显式设 4 也尊重',
      );
      expect(
        AppModel.resolvePopupDesktopDefault(
            hasExplicit: true, stored: 3, isDesktop: true),
        3,
      );
    });
  });
}
