import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 浮层统一（用户 2026-10-05「对话框和底部弹窗也统一成 m3e」）的反向锁：
/// `lib/` 下不得新增裸 Material / Cupertino 浮层入口。对话框一律走
/// `showAppDialog` + `FushiAlertDialog` / `FushiSimpleDialog` / `FushiDialog`
/// 或标准模板（`showFushiConfirmDialog` 等，见 fushi_m3e_overlays.dart）；
/// 底部弹层走 `adaptiveModalSheet`；菜单走 `showFushiMenu` /
/// `FushiPopupMenuButton` / `FushiOverflowMenu`。裸入口拿不到 M3E 的弹簧进出、
/// scrim、形状与 Apple 设计系统的分派。
///
/// 白名单只收两类：共享封装自身，以及确需保留的平台原生形态（Apple 设计系统的
/// CupertinoActionSheet）或仍在其它分支改造中的文件（标注了归属，迁完删行）。
void main() {
  /// 模式名 → 正则（左侧不能紧跟标识符字符或 `.`，所以 `FushiAlertDialog(`、
  /// `showFushiMenu(`、`widget.showDialog` 都不算）。
  final Map<String, RegExp> patterns = <String, RegExp>{
    'showDialog': RegExp(r'(?<![\w.$])showDialog\s*[<(]'),
    'showGeneralDialog': RegExp(r'(?<![\w.$])showGeneralDialog\s*[<(]'),
    'showCupertinoDialog': RegExp(r'(?<![\w.$])showCupertinoDialog\s*[<(]'),
    'showCupertinoModalPopup': RegExp(
      r'(?<![\w.$])showCupertinoModalPopup\s*[<(]',
    ),
    'showModalBottomSheet': RegExp(r'(?<![\w.$])showModalBottomSheet\s*[<(]'),
    'showBottomSheet': RegExp(r'(?<![\w.$])showBottomSheet\s*[<(]'),
    'showMenu': RegExp(r'(?<![\w.$])showMenu\s*[<(]'),
    'AlertDialog': RegExp(r'(?<![\w.$])AlertDialog(\.adaptive)?\s*\('),
    'SimpleDialog': RegExp(r'(?<![\w.$])SimpleDialog\s*\('),
    'Dialog': RegExp(r'(?<![\w.$])Dialog(\.fullscreen)?\s*\('),
    'PopupMenuButton': RegExp(r'(?<![\w.$])PopupMenuButton(<[^>()]*>)?\s*\('),
  };

  /// 相对 `lib/` 的路径（正斜杠）→ 允许出现的模式。
  const Map<String, Set<String>> allowlist = <String, Set<String>>{
    // 共享封装本体。
    'src/utils/misc/show_app_dialog.dart': <String>{'showCupertinoDialog'},
    'src/utils/adaptive/adaptive_widgets.dart': <String>{
      'showCupertinoModalPopup',
      'showGeneralDialog',
      'showModalBottomSheet',
    },
    'src/utils/components/glass/fushi_glass_overlays.dart': <String>{
      'AlertDialog',
      'SimpleDialog',
      'Dialog',
    },
    // FushiDialogFrame（共享对话框外壳）。
    'src/utils/components/fushi_material_components.dart': <String>{'Dialog'},
    // Apple 设计系统的原生 iOS action sheet（选择器）。
    'src/utils/components/settings_shared.dart': <String>{
      'showCupertinoModalPopup',
    },
    'src/profile/profile_selector.dart': <String>{'showCupertinoModalPopup'},
    // 阅读器侧板外壳（sh-reader-toolbar 分支在改，自绘侧滑路由）。
    'src/reader/reader_desktop_chrome.dart': <String>{'showGeneralDialog'},
    // 以下仍在其它分支的改造范围内，迁完删行。
    // sh-reader-toolbar：阅读器 chrome 溢出菜单。
    'src/pages/implementations/reader_fushi/chrome.part.dart': <String>{
      'PopupMenuButton',
    },
    // sh-first-lookup / sh-dict-mgmt-m3e：词典弹窗顶栏溢出菜单。
    'src/pages/implementations/dictionary_popup_layer.dart': <String>{
      'PopupMenuButton',
    },
  };

  test('lib/ 不新增裸对话框 / 底部弹层 / 菜单入口', () {
    final Directory lib = Directory('lib');
    expect(lib.existsSync(), isTrue, reason: '须在 fushi/ 下运行');
    final List<String> violations = <String>[];
    for (final FileSystemEntity entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('.g.dart')) continue;
      final String rel = entity.path
          .replaceAll(r'\', '/')
          .substring('lib/'.length);
      final Set<String> allowed = allowlist[rel] ?? const <String>{};
      final List<String> lines = entity.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        final String line = lines[i];
        final String trimmed = line.trimLeft();
        if (trimmed.startsWith('//')) continue;
        // 去掉行尾注释（不处理字符串里的 //，误报时改写法即可）。
        final int comment = line.indexOf('//');
        final String code = comment >= 0 ? line.substring(0, comment) : line;
        patterns.forEach((String name, RegExp re) {
          if (allowed.contains(name)) return;
          if (re.hasMatch(code)) {
            violations.add('$rel:${i + 1}: 裸 $name → ${line.trim()}');
          }
        });
      }
    }
    expect(
      violations,
      isEmpty,
      reason:
          '改用共享封装：showAppDialog + FushiAlertDialog / 标准模板 '
          '（showFushiConfirmDialog 等）、adaptiveModalSheet、showFushiMenu / '
          'FushiPopupMenuButton。确需保留时在本守卫白名单登记并写明原因。\n'
          '${violations.join('\n')}',
    );
  });

  test('白名单里的每个文件都还存在（迁完要删行，不留僵尸条目）', () {
    for (final String rel in allowlist.keys) {
      expect(File('lib/$rel').existsSync(), isTrue, reason: rel);
    }
  });
}
