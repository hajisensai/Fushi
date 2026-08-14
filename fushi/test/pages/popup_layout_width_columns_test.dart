import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// 查词弹窗 / 查词页布局默认值守卫：
///  - TODO-1352：取消查词页宽屏强制内容宽度上限；放宽弹窗最大宽度滑块上限；外部悬浮
///    查词窗宽度统一到用户的 popupMaxWidth（不再硬编码 480）。
///  - TODO-1354：音高读音条按 Niratan 改为行内单行（' | ' 分隔），不再 list-style 竖排。
///  - TODO-1357 / BUG-806：查词弹窗「最多列数」默认 3（桌面 + 移动，自动填充、视口收敛
///    兜底）；「自动展开词典数」默认跟随列数（= popupDictionaryColumns，第一行铺满即展开）；
///    用户显式设过一律遵从（三态）。
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
      // UI v2（2026-07-12 用户拍板）：书架/视频库上限同样取消（媒体墙布局占满）。
      expect(
        desktopContentMaxWidth(
            WindowSizeClass.expanded, DesktopContentKind.readerShelf),
        isNull,
        reason: '书架/视频库宽屏应占满（用户实报莫名宽度上限）',
      );
      // 设置页同样取消上限（用户实报「设置页有莫名奇妙的宽度限制」）。
      expect(
        desktopContentMaxWidth(
            WindowSizeClass.expanded, DesktopContentKind.settings),
        isNull,
        reason: '设置正文宽屏应占满，不再被 960 锁窄',
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

  group('TODO-1354 查词卡钉死 LTR（RTL UI 语言下 headword 不再被甩到右）', () {
    // 根因：宿主 WebView 把 Flutter 环境 Directionality（用户 UI 语言选阿拉伯语
    // strings_ar 时为 RTL）作为 layoutDirection 传进平台视图，文档根默认方向变 rtl，
    // 令 .entry-header flex 行翻转、headword 被甩到最右。作者层 direction:ltr 覆盖 UA
    // 的 [dir=rtl] 继承，把整卡钉死 LTR（与 Niratan 一致，例句 padding-left 缩进也回正）。
    final String css = File('assets/popup/popup.css').readAsStringSync();

    test('popup.css 的 html,body 块声明 direction: ltr', () {
      final RegExp rule =
          RegExp(r'html,\s*body\s*\{([\s\S]*?)\}', multiLine: true);
      final RegExpMatch? m = rule.firstMatch(css);
      expect(m, isNotNull, reason: '应能定位 html, body 规则块');
      final String body = m!.group(1)!;
      expect(body.contains('direction: ltr'), isTrue,
          reason: 'TODO-1354/BUG-673：查词卡必须钉死 LTR，'
              '否则 RTL UI 语言下 headword 被 flex 行翻转甩到右侧');
    });

    test('阿拉伯语 i18n 存在（RTL 触发条件的真实性佐证）', () {
      // 若某天移除阿拉伯语，本 RTL 触发路径的前提就变了；此断言让根因链保持可追溯。
      expect(File('lib/i18n/strings_ar.i18n.json').existsSync(), isTrue,
          reason: 'strings_ar 是本 bug 的 RTL 触发来源（用户 UI 语言可选阿拉伯语）');
    });
  });

  group('TODO-1357/BUG-806 列数默认 3 + 展开数跟随列数（三态）', () {
    test('resolvePopupDesktopDefault 未传 desktopDefault 时的基线默认：桌面 2、移动 1', () {
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

    test('desktopDefault / mobileDefault 参数覆盖平台默认（列数用它抬到 3）', () {
      // 列数用 desktopDefault: 3（放宽最多列数，靠视口收敛兜底），移动仍 1。
      expect(
        AppModel.resolvePopupDesktopDefault(
            hasExplicit: false, stored: 1, isDesktop: true, desktopDefault: 3),
        3,
        reason: '「最多列数」桌面默认放宽到 3',
      );
      expect(
        AppModel.resolvePopupDesktopDefault(
            hasExplicit: false, stored: 1, isDesktop: false, desktopDefault: 3),
        1,
        reason: '移动端仍默认 1（mobileDefault 未改）',
      );
      // 显式设过时 desktopDefault 不参与（尊重用户）。
      expect(
        AppModel.resolvePopupDesktopDefault(
            hasExplicit: true, stored: 2, isDesktop: true, desktopDefault: 3),
        2,
        reason: '用户显式设过时忽略平台默认',
      );
    });

    // BUG-1271：「自动展开默认跟随列数」的**意图**没变（第一行铺满即展开），变的是
    // 它在哪一层实现。这个偏好的单位在 TODO-845 之后是「行」，popup.js 的
    // autoExpandCount 已经在乘有效列数了；Dart 侧再返回列数，就成了 cols 行 × cols 列
    // = cols² 本（出厂列数 3 → 9 本，列数 4 → 16 本）。单位是行，「第一行铺满」只能是 1，
    // 乘法交给 popup.js 那一处唯一的 rows × cols。故本守卫从「默认 = 列数」改为
    // 「默认 = 1 行」，并显式禁止把 popupDictionaryColumns 塞回行数槽位。
    test(
        '源码守卫：popupDictionaryColumns 桌面 + 移动默认都传 3；'
        '自动展开数默认 1 行（本数由 popup.js 的 rows × cols 跟随列数）', () {
      final String src =
          File('lib/src/models/app_model.dart').readAsStringSync();
      // 列数 getter 必须显式把桌面 + 移动默认都抬到 3（宽屏手机也能多列，窄屏视口收敛兜底）。
      final int colAt = src.indexOf('int get popupDictionaryColumns =>');
      expect(colAt, isNonNegative);
      final int colEnd = src.indexOf(');', colAt);
      expect(colEnd, greaterThan(colAt));
      final String colBody = src.substring(colAt, colEnd);
      expect(colBody.contains('desktopDefault: 3'), isTrue,
          reason: '「最多列数」桌面默认必须是 3');
      expect(colBody.contains('mobileDefault: 3'), isTrue,
          reason: '「最多列数」移动默认也放宽到 3（宽屏手机多列、窄屏自动收回）');
      // 自动展开 getter：未显式设过时默认 1 **行**（BUG-1271）。
      final int expAt = src.indexOf('int get popupAutoExpandDictionaries =>');
      expect(expAt, isNonNegative);
      final int expEnd = src.indexOf(';', expAt);
      expect(expEnd, greaterThan(expAt));
      final String expBody = src.substring(expAt, expEnd);
      expect(expBody.contains('hasExplicitPopupAutoExpandDictionaries'), isTrue,
          reason: '显式设过一律遵从存储值');
      expect(RegExp(r':\s*1\s*$').hasMatch(expBody.trimRight()), isTrue,
          reason: 'BUG-1271：单位是「行」，默认必须是 1 行（第一行铺满）；'
              '本数跟随列数由 popup.js 的 autoExpandCount = rows × cols 负责');
      expect(expBody.contains('popupDictionaryColumns'), isFalse,
          reason: 'BUG-1271：把列数塞进行数槽位 → cols 行 × cols 列 = cols² 本，'
              '出厂列数 3 时默认展开从意图的 3 本膨胀成 9 本');
      expect(expBody.contains('resolvePopupDesktopDefault'), isFalse,
          reason: '自动展开数不走平台 2/1 默认');
    });
  });
}
