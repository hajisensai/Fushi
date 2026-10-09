// 视频播放器「视频设置」面板重设计的效果图渲染器（反馈 nGxUGtYot9 / JsICLVdq0i /
// anuYVUChGs / GbN9MoKDCQ）。
//
// 不是回归测试：用真实的生产组件（VideoTranslucentSidePanel / VideoQuickSettingsSheet /
// SettingsSectionJumpBar / VideoSubtitleJumpPanel）与主题工厂在离屏光栅里画出手机竖屏、
// 手机横屏、桌面三种形态，写成 PNG 供 PR 对比。
//
// 默认 skip；设 `FUSHI_DESIGN_PREVIEW_OUT=<输出目录>` 才运行（与 redesign_preview_test
// 同一约定）。中文字体探测 `FUSHI_PREVIEW_CJK_FONT` / Windows 等线 / 黑体。
@Tags(<String>['design-preview'])
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/video/video_quick_settings_host.dart';
import 'package:fushi/src/media/video/video_quick_settings_sheet.dart';
import 'package:fushi/src/media/video/video_side_panel.dart';
import 'package:fushi/src/media/video/video_subtitle_sync_row.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart'
    show readerSideSheetWidth;
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/settings/settings_kit.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fushi_icon_fonts.dart';
import '../helpers/video_quick_settings_harness.dart';

final String? _outDir = Platform.environment['FUSHI_DESIGN_PREVIEW_OUT'];

/// 文件名前缀：改前跑一次 `before`、改后跑一次 `after`。
final String _phase = Platform.environment['FUSHI_PREVIEW_PHASE'] ?? 'after';

const String _latinFamily = 'FushiPreview';
const String _cjkFamily = 'FushiPreviewCJK';

class _Form {
  const _Form(this.name, this.size, this.platform);

  final String name;
  final Size size;
  final TargetPlatform platform;

  bool get touch => platform == TargetPlatform.android;
}

const List<_Form> _forms = <_Form>[
  _Form('phone_portrait', Size(384, 853), TargetPlatform.android),
  _Form('phone_landscape', Size(853, 384), TargetPlatform.android),
  _Form('desktop', Size(1280, 800), TargetPlatform.windows),
];

void main() {
  if (_outDir == null || _outDir!.isEmpty) {
    test(
      'video settings preview（未设 FUSHI_DESIGN_PREVIEW_OUT，跳过）',
      () {},
      skip: 'set FUSHI_DESIGN_PREVIEW_OUT to render previews',
    );
    return;
  }
  final Directory out = Directory(_outDir!)..createSync(recursive: true);

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    await _loadFonts();
    await loadFushiIconFonts();
  });

  for (final _Form form in _forms) {
    for (final String category in <String>['subtitle', 'playback']) {
      testWidgets('${form.name} $category', (WidgetTester tester) async {
        final VideoSheetHarness harness =
            await tester.runAsync(VideoSheetHarness.create)
                as VideoSheetHarness;
        addTearDown(() => tester.runAsync(harness.dispose));
        await _capture(
          tester,
          File('${out.path}/${_phase}_${form.name}_$category.png'),
          form: form,
          child: _PlayerScene(
            form: form,
            panel: Builder(
              builder: (BuildContext context) =>
                  _settingsPanel(context, harness, form, category),
            ),
          ),
        );
      });
    }
  }

  if (_phase != 'before') {
    for (final _Form form in _forms) {
      testWidgets('${form.name} delay float bar', (WidgetTester tester) async {
        await _capture(
          tester,
          File('${out.path}/${_phase}_${form.name}_delay_bar.png'),
          form: form,
          child: _PlayerScene(
            form: form,
            panel: _delayBar(
              buildTestVideoHost(
                state: TestVideoHostState(delayMs: -2000),
                isTouchControls: form.touch,
                onAutoAlign: () async => null,
                onSnapDelayToCue: ({required bool next}) => null,
              ),
            ),
          ),
        );
      });
    }
  }

  testWidgets('settings jump bar follows active section', (
    WidgetTester tester,
  ) async {
    const List<(String, String)> sections = <(String, String)>[
      ('hdr', 'HDR'),
      ('picture', '画面'),
      ('color', '色彩'),
      ('subtitle', '字幕'),
      ('subtitle_behavior', '字幕行为与来源'),
      ('audio', '音频'),
      ('advanced', '高级'),
    ];
    final ValueNotifier<String> active = ValueNotifier<String>('hdr');
    await _capture(
      tester,
      File('${out.path}/${_phase}_settings_jump_bar.png'),
      form: const _Form('jump_bar', Size(384, 120), TargetPlatform.android),
      brightness: Brightness.dark,
      settle: () async {
        active.value = 'audio';
        await tester.pumpAndSettle();
      },
      child: Material(
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 24),
            child: ValueListenableBuilder<String>(
              valueListenable: active,
              builder: (BuildContext context, String id, Widget? _) =>
                  SettingsSectionJumpBar(
                    sections: sections,
                    activeId: id,
                    onSelected: (String next) => active.value = next,
                  ),
            ),
          ),
        ),
      ),
    );
  });
}

/// 与视频页 `_buildVideoSidePanelContent` 同形：设置侧栏外壳 + schema 面板，套界面缩放。
Widget _settingsPanel(
  BuildContext context,
  VideoSheetHarness harness,
  _Form form,
  String category,
) {
  final VideoQuickSettingsHost host = buildTestVideoHost(
    isTouchControls: form.touch,
    onAutoAlign: () async => null,
    onSnapDelayToCue: ({required bool next}) => null,
    onEnterSubtitleDelayBar: () {},
  );
  final Widget sheet = ProviderScope(
    child: Consumer(
      builder: (BuildContext context, WidgetRef ref, Widget? _) =>
          VideoQuickSettingsSheet(
            appModel: harness.appModel,
            ref: ref,
            host: host,
            initialCategory: category,
          ),
    ),
  );
  if (_phase == 'before') {
    return VideoTranslucentSidePanel(
      title: t.video_settings_title,
      icon: FushiIcons.settings,
      width: fushiQuickSettingsPanelWidth(MediaQuery.sizeOf(context).width),
      child: sheet,
    );
  }
  // 与视频页 `_buildVideoSidePanelContent` / `_videoSidePanelWidth` 同形。
  final Size window = MediaQuery.sizeOf(context);
  return VideoTranslucentSidePanel(
    icon: FushiIcons.settings,
    width: videoQuickSettingsCompact(window)
        ? readerSideSheetWidth(window.width)
        : fushiQuickSettingsPanelWidth(window.width),
    bottomSheetWhenCompact: true,
    opaque: true,
    onClose: () {},
    child: sheet,
  );
}

/// 与视频页 layout.part `_buildSubtitleDelayBar` 同形的浮条调轴浮层。
Widget _delayBar(VideoQuickSettingsHost host) {
  return SafeArea(
    child: Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: VideoFloatingPanelSurface(
            opaque: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: VideoSubtitleSyncRow(
                host: host,
                floatBar: true,
                onDone: () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// 一帧「正在播放」的画面：16:9 画面（竖屏居中）+ 底部一行字幕，面板叠在上面。
class _PlayerScene extends StatelessWidget {
  const _PlayerScene({required this.form, required this.panel});

  final _Form form;
  final Widget panel;

  @override
  Widget build(BuildContext context) {
    final Size size = form.size;
    final double videoHeight = size.width * 9 / 16 > size.height
        ? size.height
        : size.width * 9 / 16;
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Center(
            child: SizedBox(
              width: size.width,
              height: videoHeight,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[Color(0xFF3B2A20), Color(0xFFB0602A)],
                  ),
                ),
                child: Align(
                  alignment: const Alignment(0, 0.82),
                  child: Text(
                    '（槙生）シナモンが死んでなきゃいける',
                    style: TextStyle(
                      fontFamily: _cjkFamily,
                      fontSize: form.touch ? 18 : 30,
                      color: Colors.white,
                      shadows: const <Shadow>[
                        Shadow(blurRadius: 4, color: Colors.black),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          panel,
        ],
      ),
    );
  }
}

// ───────────────────────────── 基础设施 ─────────────────────────────

Future<void> _loadFonts() async {
  final String? flutterRoot = _flutterRoot();
  final FontLoader latinLoader = FontLoader(_latinFamily);
  if (flutterRoot != null) {
    for (final String w in <String>['Regular', 'Medium', 'Bold']) {
      final String path =
          '$flutterRoot/bin/cache/artifacts/material_fonts/Roboto-$w.ttf';
      if (File(path).existsSync()) latinLoader.addFont(_bytes(path));
    }
  }
  await latinLoader.load();
  final String? cjk = _findCjkFont();
  if (cjk != null) {
    await (FontLoader(_cjkFamily)..addFont(_bytes(cjk))).load();
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
  for (int i = 0; i < 6; i++) {
    if (File('${dir.path}/bin/flutter').existsSync()) return dir.path;
    dir = dir.parent;
  }
  return null;
}

String? _findCjkFont() {
  final List<String> candidates = <String>[
    if (Platform.environment['FUSHI_PREVIEW_CJK_FONT'] case final String p) p,
    r'C:\Windows\Fonts\Deng.ttf',
    r'C:\Windows\Fonts\simhei.ttf',
    '/System/Library/Fonts/Supplemental/Songti.ttc',
  ];
  for (final String path in candidates) {
    if (File(path).existsSync()) return path;
  }
  return null;
}

ThemeData _theme(Brightness brightness, TargetPlatform platform) {
  final ThemeData base = buildFushiThemeData(
    scheme: buildFushiColorScheme(
      seedColor: kFushiDefaultSeed,
      brightness: brightness,
    ),
    textTheme: FushiTypeScale.buildTextTheme(
      const TextStyle(
        fontFamily: _latinFamily,
        fontFamilyFallback: <String>[_cjkFamily],
      ),
    ),
  );
  return base.copyWith(platform: platform);
}

Future<void> _capture(
  WidgetTester tester,
  File file, {
  required _Form form,
  required Widget child,
  Brightness brightness = Brightness.light,
  Future<void> Function()? settle,
  double dpr = 2,
}) async {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = form.size * dpr;
  addTearDown(tester.view.reset);
  const Key key = ValueKey<String>('preview-boundary');
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      // app 本体是浅色主题（群反馈截图），面板是否跟着变白就在这张图上看。
      theme: _theme(brightness, form.platform),
      home: RepaintBoundary(
        key: key,
        child: FushiFocusRoot(child: Scaffold(body: child)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (settle != null) await settle();
  await tester.pumpAndSettle();
  final RenderRepaintBoundary boundary = tester
      .renderObject<RenderRepaintBoundary>(find.byKey(key));
  final ui.Image image = (await tester.runAsync(
    () => boundary.toImage(pixelRatio: dpr),
  ))!;
  final ByteData? data = await tester.runAsync<ByteData?>(
    () => image.toByteData(format: ui.ImageByteFormat.png),
  );
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(data!.buffer.asUint8List());
}
