// 新手引导的真实像素预览：首页 hero 与页头进度条的相对位置、「全局查词」那步的
// 热键键帽，以及 macOS 上快捷键的显示形态（⌃ ⌥ ⇧ ⌘）。
//
// 不是断言型测试：只有设了 `FUSHI_PREVIEW_OUT=<输出目录>` 才真跑（加载系统字体、
// 写 PNG）；文件名后缀由 `FUSHI_PREVIEW_SUFFIX` 给（before / after）。
//
//   FUSHI_PREVIEW_OUT=../.claude/preview/onboarding FUSHI_PREVIEW_SUFFIX=after \
//     flutter test --no-pub test/onboarding/onboarding_pixel_preview_test.dart
@Tags(<String>['preview'])
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/onboarding_wizard_page.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/shortcut_labels.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi/src/shortcuts/visual/keyboard_layout_view.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

final String? _outDir = Platform.environment['FUSHI_PREVIEW_OUT'];
String get _suffix => Platform.environment['FUSHI_PREVIEW_SUFFIX'] ?? 'shot';

const String _latinFamily = 'FushiPreview';
const String _cjkFamily = 'FushiPreviewCJK';

void main() {
  if (_outDir == null || _outDir!.isEmpty) {
    test(
      'onboarding preview（未设 FUSHI_PREVIEW_OUT，跳过）',
      () {},
      skip: 'set FUSHI_PREVIEW_OUT to render previews',
    );
    return;
  }
  final Directory out = Directory(_outDir!)..createSync(recursive: true);

  setUpAll(_loadFonts);

  testWidgets('welcome hero vs progress bar', (WidgetTester tester) async {
    await _capture(
      tester,
      File('${out.path}/onboarding_welcome_$_suffix.png'),
      child: _wizardFrame(
        current: 0,
        step: const OnboardingStepView(
          icon: FushiIcons.home,
          title: '欢迎使用 Fushi',
          body: '先选界面语言和明暗主题，剩下的交给后面几步。',
        ),
      ),
    );
  });

  testWidgets('global lookup keycaps on macOS', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final InputBinding binding = ShortcutDefaults.forPlatform(
        TargetPlatform.macOS,
      )[ShortcutAction.globalExternalLookup]!.keyboardBindings.first;
      await _capture(
        tester,
        File('${out.path}/onboarding_global_lookup_macos_$_suffix.png'),
        size: const Size(720, 900),
        child: _wizardFrame(
          current: 7,
          step: OnboardingOperationTutorialView(
            icon: FushiIcons.keyboard,
            title: '全局查词',
            body: '在其他应用里选中文字，不用切窗口就能查词。',
            items: <OnboardingTutorialItem>[
              const OnboardingTutorialItem(
                icon: FushiIcons.textFields,
                title: '选中文字',
                description: '在任意应用里拖选一个词，保持选中。',
              ),
              OnboardingTutorialItem(
                icon: FushiIcons.keyboard,
                title: '按下快捷键',
                description: 'Fushi 抓取选区，在鼠标旁打开查词卡片。',
                extra: OnboardingHotkeyKeycaps(binding: binding),
              ),
              const OnboardingTutorialItem(
                icon: FushiIcons.settings,
                title: '改快捷键',
                description: '设置 → 快捷键 → 全局（应用外）。',
              ),
            ],
          ),
        ),
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.macOS,
    TargetPlatform.windows,
  ]) {
    testWidgets('keyboard layout view (${platform.name})', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        final FushiShortcutRegistry registry = FushiShortcutRegistry()
          ..loadDefaults(platform);
        await _capture(
          tester,
          File('${out.path}/keyboard_layout_${platform.name}_$_suffix.png'),
          size: const Size(1000, 340),
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: KeyboardLayoutView(
                registry: registry,
                scope: ShortcutScope.reader,
              ),
            ),
          ),
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('shortcut labels on macOS', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final Map<ShortcutAction, ShortcutBindingSet> mac =
          ShortcutDefaults.forPlatform(TargetPlatform.macOS);
      await _capture(
        tester,
        File('${out.path}/shortcut_labels_macos_$_suffix.png'),
        child: _ShortcutLabelScene(bindings: mac),
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

/// 与 [OnboardingWizardPage.build] 同构的骨架：浮动页头 + 进度条，正文是真页用的
/// [OnboardingWizardBody]。
Widget _wizardFrame({required int current, required Widget step}) {
  return FushiPageScaffold(
    automaticallyImplyLeading: false,
    headerCompact: true,
    leading: FushiIconButton(
      tooltip: 'Back',
      icon: FushiIcons.back,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(
        minWidth: kMinInteractiveDimension,
        minHeight: kMinInteractiveDimension,
      ),
      onTap: () {},
    ),
    title: '新手引导',
    headerBottom: OnboardingProgressBar(current: current, total: 9),
    body: OnboardingWizardBody(
      stepKey: current,
      forward: true,
      step: step,
      navigationBar: OnboardingNavigationBar(
        onSkip: () {},
        onBack: current > 0 ? () {} : null,
        onNext: () {},
        isLast: false,
      ),
    ),
  );
}

/// 设置页快捷键列表 / tooltip / 菜单后缀在 macOS 上的显示形态。
class _ShortcutLabelScene extends StatelessWidget {
  const _ShortcutLabelScene({required this.bindings});

  final Map<ShortcutAction, ShortcutBindingSet> bindings;

  static const List<ShortcutAction> _actions = <ShortcutAction>[
    ShortcutAction.globalExternalLookup,
    ShortcutAction.globalExternalOpenLookupPage,
    ShortcutAction.audiobookPlayPause,
    ShortcutAction.globalToggleFullscreen,
    ShortcutAction.popupNextEntry,
  ];

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Scaffold(
      body: Padding(
        padding: EdgeInsets.all(tokens.spacing.page),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('macOS · 快捷键显示', style: text.titleLarge),
            SizedBox(height: tokens.spacing.card),
            for (final ShortcutAction action in _actions) ...<Widget>[
              Row(
                children: <Widget>[
                  SizedBox(
                    width: 220,
                    child: Text(action.label, style: text.bodyLarge),
                  ),
                  for (final InputBinding b
                      in bindings[action]!.keyboardBindings)
                    Padding(
                      padding: EdgeInsets.only(right: tokens.spacing.gap / 2),
                      child: FushiTagChip(
                        label: b.displayLabel,
                        tone: FushiTagChipTone.surface,
                      ),
                    ),
                  for (final WheelBinding w in bindings[action]!.wheelBindings)
                    FushiTagChip(
                      label: w.label,
                      tone: FushiTagChipTone.surface,
                    ),
                  const Spacer(),
                  Text(
                    tooltipWithShortcutHint(
                      action.label,
                      bindings[action]!.keyboardBindings,
                      keyboardHints: true,
                    ),
                    style: text.bodyMedium,
                  ),
                ],
              ),
              SizedBox(height: tokens.spacing.gap),
            ],
          ],
        ),
      ),
    );
  }
}

// ───────────────────────────── 基础设施 ─────────────────────────────

Future<void> _loadFonts() async {
  final String? flutterRoot = _flutterRoot();
  final FontLoader latin = FontLoader(_latinFamily);
  if (flutterRoot != null) {
    for (final String w in <String>['Regular', 'Medium', 'Bold']) {
      final String path =
          '$flutterRoot/bin/cache/artifacts/material_fonts/Roboto-$w.ttf';
      if (File(path).existsSync()) latin.addFont(_bytes(path));
    }
  }
  await latin.load();
  for (final String path in <String>[
    r'C:\Windows\Fonts\NotoSansSC-VF.ttf',
    r'C:\Windows\Fonts\NotoSansJP-Regular.otf',
    '/System/Library/Fonts/PingFang.ttc',
  ]) {
    if (!File(path).existsSync()) continue;
    await (FontLoader(_cjkFamily)..addFont(_bytes(path))).load();
    break;
  }
  // ⌃⌥⇧⌘ 在 CJK 字体里不一定有字形：再挂一份带这些符号的系统字体兜底。
  for (final String path in <String>[
    r'C:\Windows\Fonts\seguisym.ttf',
    '/System/Library/Fonts/Apple Symbols.ttf',
  ]) {
    if (!File(path).existsSync()) continue;
    await (FontLoader('FushiPreviewSymbols')..addFont(_bytes(path))).load();
    break;
  }
  for (final (String family, String path) in <(String, String)>[
    ('FushiSymbols', 'assets/icon_fonts/FushiSymbolsRounded.ttf'),
    ('FushiSymbolsFilled', 'assets/icon_fonts/FushiSymbolsRoundedFilled.ttf'),
  ]) {
    if (File(path).existsSync()) {
      await (FontLoader(family)..addFont(_bytes(path))).load();
    }
  }
  if (flutterRoot != null) {
    final String icons =
        '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
    if (File(icons).existsSync()) {
      await (FontLoader('MaterialIcons')..addFont(_bytes(icons))).load();
    }
  }
}

Future<ByteData> _bytes(String path) async =>
    ByteData.sublistView(File(path).readAsBytesSync());

String? _flutterRoot() {
  final String? env = Platform.environment['FLUTTER_ROOT'];
  if (env != null && Directory(env).existsSync()) return env;
  Directory dir = File(Platform.resolvedExecutable).parent;
  for (int i = 0; i < 7; i++) {
    if (File('${dir.path}/bin/flutter').existsSync()) return dir.path;
    dir = dir.parent;
  }
  return null;
}

ThemeData _theme() {
  final ThemeData base = buildFushiThemeData(
    scheme: buildFushiColorScheme(
      seedColor: kFushiDefaultSeed,
      brightness: Brightness.dark,
    ),
    textTheme: FushiTypeScale.buildTextTheme(
      const TextStyle(
        fontFamily: _latinFamily,
        fontFamilyFallback: <String>[_cjkFamily, 'FushiPreviewSymbols'],
      ),
    ),
  );
  return base.copyWith(platform: TargetPlatform.windows);
}

Future<void> _capture(
  WidgetTester tester,
  File file, {
  required Widget child,
  Size size = const Size(720, 480),
  double dpr = 2,
}) async {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = size * dpr;
  addTearDown(tester.view.reset);
  const Key key = ValueKey<String>('preview-boundary');
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme(),
      // 与真 app 一样：桌面自绘标题行把 32px 顶部 padding 交给整棵 Navigator。
      builder: (BuildContext context, Widget? app) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(padding: const EdgeInsets.only(top: 32)),
        child: app!,
      ),
      home: RepaintBoundary(
        key: key,
        child: FushiFocusRoot(child: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
  // 页头高度经 post-frame 回报再 setState：多走几帧让让位高度落定。
  for (int i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
  final RenderRepaintBoundary boundary = tester
      .renderObject<RenderRepaintBoundary>(find.byKey(key));
  final ui.Image image = (await tester.runAsync(
    () => boundary.toImage(pixelRatio: dpr),
  ))!;
  final ByteData? data = await tester.runAsync<ByteData?>(
    () => image.toByteData(format: ui.ImageByteFormat.png),
  );
  image.dispose();
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(data!.buffer.asUint8List());
}
