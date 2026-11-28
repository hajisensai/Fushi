import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../helpers/source_guard.dart';

// 外观只有两套：MD3（auto / material）与玻璃（Apple），唯一判据是
// `isGlassDesign` / `glassMaterialOf`，与宿主平台无关。隐藏的 Cupertino / macOS
// 设计系统删掉后，「按设计系统枚举选第三套外观」从类型上写不出来；剩下还能
// 绕开判据、按**平台**分出第三套外观的写法只有两类，这里用只减不增的棘轮
// 卡住（数量必须与允许表**相等**：多了即红，少了也红——把表改小）：
//
// 1. SDK 自带的平台分派入口：`X.adaptive(`、`showAdaptiveDialog`、
//    `showAdaptiveAboutDialog`、`AdaptiveTextSelectionToolbar`、`Icons.adaptive`。
//    它们按 `ThemeData.platform` 在 iOS / macOS 上换成 Cupertino 外观 / 路由。
// 2. 手写的平台分派：同一条语句里既判平台（`Platform.isIOS|isMacOS`、
//    `TargetPlatform.iOS|macOS`、`defaultTargetPlatform`）又构造 `Cupertino*`
//    控件 / 调 `showCupertino*`。
//
// 允许表里的每一处都是存量，理由写在表上；它们不是「可以照着再写一处」的先例。

/// 第 1 类：SDK 平台分派入口。`Fushi*` 自己的 `.adaptive` 命名构造器不算（它们
/// 内部若直通 SDK `.adaptive(`，会在那一行被数到）。
final RegExp _sdkDispatch = RegExp(
  r'(?<![\w.])(?!Fushi)[A-Z]\w*(?:<[^<>()]*>)?\.adaptive\('
  r'|\bshowAdaptive(?:About)?Dialog\b'
  r'|(?<!\w)AdaptiveTextSelectionToolbar\b'
  r'|\bIcons\.adaptive\b',
);

const String _platformPredicate =
    r'(?:\bPlatform\.is(?:IOS|MacOS)\b'
    r'|\bTargetPlatform\.(?:iOS|macOS)\b'
    r'|\bdefaultTargetPlatform\b)';
const String _cupertinoUse =
    r'(?:\bCupertino[A-Z]\w*(?:\.\w+)?\s*(?:<[^<>()]*>)?\('
    r'|\bshowCupertino\w*\s*(?:<[^<>()]*>)?\()';

/// 第 2 类：平台判断与 Cupertino 构造落在同一条语句里（两种先后顺序）。
final RegExp _platformCupertino = RegExp(
  '$_platformPredicate[^;]{0,400}?$_cupertinoUse'
  '|$_cupertinoUse[^;]{0,400}?$_platformPredicate',
);

/// 第 1 类存量。
const Map<String, int> _allowedSdkDispatch = <String, int>{
  // 进度环包装层的原生回落：墨水屏 / year2023 / 外部 controller / 非 M3 时
  // `FushiCircularProgressIndicator.adaptive` 仍交给 SDK 平台分派。
  'lib/src/utils/components/glass/fushi_glass_feedback.dart': 1,
  // 日志上传隐私同意框用 `showAdaptiveDialog`：iOS / macOS 上是 Cupertino 的
  // 对话框路由与转场。改成 showAppDialog 会改用户可见行为，待拍板。
  'lib/src/utils/misc/log_uploader.dart': 1,
  // 文本选择工具条（长按 / 右键菜单）沿用 SDK 的平台原生工具条。
  'lib/src/pages/implementations/feedback/feedback_compose_page.dart': 1,
  'lib/src/utils/components/fushi_material_components.dart': 1,
  'lib/src/utils/components/glass/fushi_glass_inputs.dart': 1,
};

/// 第 2 类存量。
const Map<String, int> _allowedPlatformCupertino = <String, int>{
  // 文本选择手柄 / 工具条：iOS 上套 CupertinoTheme 给手柄着色；玻璃工具条按
  // 桌面 / 移动选 CupertinoDesktopTextSelectionToolbar 或
  // CupertinoTextSelectionToolbar（形态差异，不是第三套外观）。
  'lib/src/utils/components/fushi_text_selection_controls.dart': 3,
};

/// 单个文件的违规清单。先整文件词法遮掉注释与字符串内容，再在遮后的全文上
/// 计数——不逐行过滤，注释 / 字符串里的同名文本不算。
List<String> platformDispatchOffenders(String path, String source) {
  final String code = maskCommentsAndStrings(source);
  final List<String> offenders = <String>[];
  final int sdk = _sdkDispatch.allMatches(code).length;
  final int allowedSdk = _allowedSdkDispatch[path] ?? 0;
  if (sdk != allowedSdk) {
    offenders.add(
      '$path: $sdk SDK platform-dispatch call(s), expected $allowedSdk'
      '${sdk > allowedSdk ? ' — 外观只按 isGlassDesign 分，不用 SDK 的平台分派' : ' — 减了就把允许表一起改小'}',
    );
  }
  final int manual = _platformCupertino.allMatches(code).length;
  final int allowedManual = _allowedPlatformCupertino[path] ?? 0;
  if (manual != allowedManual) {
    offenders.add(
      '$path: $manual platform-selected Cupertino construction(s), expected '
      '$allowedManual'
      '${manual > allowedManual ? ' — Cupertino 控件只在 isGlassDesign 分支里出现，不按平台选' : ' — 减了就把允许表一起改小'}',
    );
  }
  return offenders;
}

void main() {
  test('lib 里按平台分出第三套外观的写法只减不增', () {
    final List<String> offenders = <String>[];
    final Set<String> seen = <String>{};
    for (final FileSystemEntity entity in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('.g.dart')) continue;
      final String path = entity.path.replaceAll(r'\', '/');
      final String source = entity.readAsStringSync();
      // 快路径：两类写法都离不开这三个词之一，免掉无关文件的整文件词法扫描。
      if (!source.contains('daptive') && !source.contains('Cupertino')) {
        continue;
      }
      seen.add(path);
      offenders.addAll(platformDispatchOffenders(path, source));
    }
    for (final String path in <String>{
      ..._allowedSdkDispatch.keys,
      ..._allowedPlatformCupertino.keys,
    }) {
      expect(seen, contains(path), reason: '允许表里的 $path 没扫到，表过期了');
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  group('守卫自检', () {
    const String page = 'lib/src/pages/some_page.dart';

    test('注释和字符串里的同名文本不算', () {
      const String source = '''
Widget build(BuildContext context) {
  /* Switch.adaptive( */
  // Slider.adaptive(  showAdaptiveDialog(
  const String note = 'Platform.isIOS ? CupertinoSwitch() : Switch()';
  return const SizedBox();
}
''';
      expect(platformDispatchOffenders(page, source), isEmpty);
    });

    test('任何 SDK 类的 .adaptive( 都算，不限于列举过的那几个', () {
      for (final String source in <String>[
        'final Widget w = Switch.adaptive(value: v, onChanged: f);',
        'final Widget w = Radio<int>.adaptive(value: 1);',
        'final Widget w = Icon(Icons.adaptive.share);',
        'final Widget w = RefreshIndicator.adaptive(onRefresh: f, child: c);',
      ]) {
        expect(
          platformDispatchOffenders(page, source),
          isNotEmpty,
          reason: source,
        );
      }
    });

    test('SDK 的自适应对话框 / 工具条入口算', () {
      for (final String source in <String>[
        'final bool? ok = await showAdaptiveDialog<bool>(context: c, builder: b);',
        'showAdaptiveAboutDialog(context: c);',
        'return AdaptiveTextSelectionToolbar.editableText(editableTextState: s);',
      ]) {
        expect(
          platformDispatchOffenders(page, source),
          isNotEmpty,
          reason: source,
        );
      }
    });

    test('手写的平台 → Cupertino 分派算（三元、if、switch，两种先后顺序）', () {
      for (final String source in <String>[
        'final Widget w = Platform.isIOS ? CupertinoSwitch(value: v) : Switch(value: v);',
        '''
Widget build(BuildContext context) {
  if (Theme.of(context).platform == TargetPlatform.iOS) {
    return CupertinoSwitch(value: v, onChanged: f);
  }
  return Switch(value: v, onChanged: f);
}
''',
        '''
Widget build(BuildContext context) {
  switch (defaultTargetPlatform) {
    case TargetPlatform.macOS:
      return CupertinoButton.filled(onPressed: f, child: c);
    default:
      return FilledButton(onPressed: f, child: c);
  }
}
''',
        'final Widget w = wrap(CupertinoSwitch(value: v), on: Platform.isMacOS);',
        'final Future<void> r = Platform.isIOS ? showCupertinoDialog<void>(context: c, builder: b) : n;',
      ]) {
        expect(
          platformDispatchOffenders(page, source),
          isNotEmpty,
          reason: source,
        );
      }
    });

    test('Fushi 包装层自己的 .adaptive 构造器、玻璃分支里的 Cupertino 控件不算', () {
      const String source = '''
Widget build(BuildContext context) {
  if (isGlassDesign(context)) {
    return CupertinoSwitch(value: v, onChanged: f);
  }
  return const FushiCircularProgressIndicator.adaptive(strokeWidth: 2);
}

bool get desktop => Platform.isMacOS;
''';
      expect(platformDispatchOffenders(page, source), isEmpty);
    });

    test('允许表里的文件多写一处也红', () {
      const String source = '''
final Widget a = CircularProgressIndicator.adaptive();
final Widget b = Switch.adaptive(value: v, onChanged: f);
''';
      expect(
        platformDispatchOffenders(
          'lib/src/utils/components/glass/fushi_glass_feedback.dart',
          source,
        ),
        isNotEmpty,
      );
    });

    test('允许表里的文件删掉存量后也红，逼着把表改小', () {
      expect(
        platformDispatchOffenders(
          'lib/src/utils/misc/log_uploader.dart',
          'void f() {}',
        ),
        isNotEmpty,
      );
    });
  });
}
