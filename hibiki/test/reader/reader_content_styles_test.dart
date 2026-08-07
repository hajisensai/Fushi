import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/media/sources/reader_hibiki_source.dart';

import '../helpers/source_guard.dart';

Future<ReaderSettings> _defaultSettings() async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final ReaderSettings settings = ReaderSettings(db);
  await settings.refreshFromDb();
  return settings;
}

void main() {
  group('ReaderContentStyles.styleTag', () {
    test('wraps css in style tag', () async {
      final ReaderSettings settings = await _defaultSettings();
      final String tag = ReaderContentStyles.styleTag(settings: settings);
      expect(tag, startsWith('<style>'));
      expect(tag, endsWith('</style>'));
    });
  });

  group('ReaderContentStyles.css with default settings', () {
    late String css;

    setUp(() async {
      final ReaderSettings settings = await _defaultSettings();
      css = ReaderContentStyles.css(settings: settings);
    });

    test('contains body selector', () {
      expect(css, contains('body'));
    });

    test('sets writing-mode to vertical-rl by default', () {
      expect(css, contains('vertical-rl'));
    });

    test('sets font-size from default (22)', () {
      expect(css, contains('22px'));
    });

    test('sets line-height from default (1.65)', () {
      expect(css, contains('1.65'));
    });

    test('contains image sizing constraints', () {
      expect(css, contains('img'));
    });

    test('contains furigana rt rule', () {
      expect(css, contains('rt'));
    });

    test('contains light theme background by default', () {
      expect(css, contains('#fff'));
    });

    test('BUG-765 续：下发选区手柄主题色变量 --fushi-sel-handle', () {
      // 移动端自绘选区起/止手柄用 var(--fushi-sel-handle) 上色，须由本 CSS 从主题
      // linkColor 下发，主题切换重注入时手柄自动跟随。
      expect(css, contains('--fushi-sel-handle:'),
          reason: '注入 CSS 必须定义 --fushi-sel-handle 供手柄引用');
    });
  });

  group('ReaderContentStyles.css theme overrides', () {
    test('dark-theme sets dark background', () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(
        settings: settings,
        themeOverride: 'dark-theme',
      );
      expect(css, contains('#121212'));
    });

    test('ecru-theme sets ecru background', () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(
        settings: settings,
        themeOverride: 'ecru-theme',
      );
      expect(css, contains('#f7f6eb'));
    });

    test('black-theme sets pure black background', () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(
        settings: settings,
        themeOverride: 'black-theme',
      );
      expect(css, contains('#000'));
    });

    test('custom-theme uses custom colors', () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(
        settings: settings,
        themeOverride: 'custom-theme',
        customBg: '#FF0000',
        customFg: '#00FF00',
      );
      expect(css, contains('#FF0000'));
      expect(css, contains('#00FF00'));
    });

    // TODO-165 / BUG-224：默认主题 system-theme（以及 light-theme / 任何未命中 preset
    // 的 key）此前落 _themeColors 的 default 分支，正文 <body> 背景恒白底 #fff，无视
    // 调用方按真实 ColorScheme 派生传入的 customBg → 「书籍正文背景没吃背景色」。
    // 现在：传了 customBg/customFg 时正文用它们；preset/custom 行为不变。
    test('system-theme with derived customBg uses it as body background',
        () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(
        settings: settings,
        themeOverride: 'system-theme',
        customBg: '#1E2A38',
        customFg: '#ECEFF4',
      );
      // 断言精确到正文 <body> 背景 selector（`background: <bg> !important;`），而不是
      // 宽泛 contains('#fff')——CSS 里另有无关的 `--fushi-system-text-color: #fff`
      // dark 媒体查询变量，与正文背景无关，不能误伤。
      expect(css, contains('background: #1E2A38 !important'),
          reason: 'system-theme 正文背景应吃派生的 ColorScheme 背景色');
      expect(css, contains('#ECEFF4'));
      expect(css, isNot(contains('background: #fff')),
          reason: '传了派生背景后正文背景不应再落硬编码白底');
    });

    test('unknown theme key with derived customBg follows it (not white)',
        () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(
        settings: settings,
        themeOverride: 'future-unmapped-theme',
        customBg: '#0A0A0A',
        customFg: '#F0F0F0',
      );
      expect(css, contains('background: #0A0A0A !important'));
      expect(css, isNot(contains('background: #fff')));
    });

    test(
        'system-theme without customBg still falls back to white body (compat)',
        () async {
      // 调用方未提供派生色时（无主题信息），正文背景保持旧的浅色默认 #fff，向后兼容。
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(
        settings: settings,
        themeOverride: 'system-theme',
      );
      expect(css, contains('background: #fff !important'));
    });
  });

  group('ReaderContentStyles.css with custom settings', () {
    test('horizontal writing mode produces horizontal-tb', () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setWritingMode('horizontal-tb');

      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('horizontal-tb'));
      expect(css, isNot(contains('text-orientation')));
    });

    test('continuous mode produces different layout', () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setViewMode('continuous');

      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('overflow'));
    });

    test('custom font faces are injected', () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(
        settings: settings,
        fontFaces: '@font-face { font-family: "TestFont"; }',
        fontFamily: '"TestFont"',
      );
      expect(css, contains('@font-face'));
      expect(css, contains('TestFont'));
    });

    test('settings custom fonts use Apple custom scheme in produced CSS',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
      });
      final Directory tempDir =
          await Directory.systemTemp.createTemp('hibiki_reader_css_font_');
      addTearDown(() async {
        await tempDir.delete(recursive: true);
      });
      final File fontFile = File('${tempDir.path}/body.ttf')
        ..writeAsBytesSync(<int>[0, 1, 0, 0]);
      final ReaderSettings settings = await _defaultSettings();
      await settings.setCustomFonts(<Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'Body Font',
          'path': fontFile.path,
          'enabled': true,
        },
      ]);

      final String css = ReaderContentStyles.css(settings: settings);

      expect(css, contains('@font-face'));
      expect(
        css,
        contains('${ReaderHibikiSource.kResourceScheme}://fushi.local/fonts/'),
      );
      expect(css, isNot(contains('https://fushi.local/fonts/')));
    });

    test('selection color override (opaque) appears verbatim in css', () async {
      // BUG-125：查词高亮预合成成不透明色；alpha=1 的覆盖色原样透传，故仍逐字出现。
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(
        settings: settings,
        selectionColor: 'rgb(1, 2, 3)',
      );
      expect(css, contains('rgb(1, 2, 3)'));
    });

    test('translucent selection override is blended to opaque (not verbatim)',
        () async {
      // 半透明覆盖色会被合成到背景色 → 不再逐字出现原 rgba，且查词高亮处不含半透明。
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(
        settings: settings,
        selectionColor: 'rgba(255, 0, 0, 0.5)',
      );
      expect(css, isNot(contains('rgba(255, 0, 0, 0.5)')),
          reason: '半透明查词色须被预合成成不透明 rgb()，不能原样进 CSS');
    });
  });

  group('ReaderContentStyles.composeOpaqueColor (BUG-125)', () {
    test('blends translucent fg over hex bg', () {
      // 0.5*255 + 0.5*0 = 127.5 → 128;  0.5*0 + 0.5*0 = 0
      expect(
        ReaderContentStyles.composeOpaqueColor('rgba(255, 0, 0, 0.5)', '#000'),
        'rgb(128, 0, 0)',
      );
      // over white: r=255, g=128, b=128
      expect(
        ReaderContentStyles.composeOpaqueColor(
            'rgba(255, 0, 0, 0.5)', '#ffffff'),
        'rgb(255, 128, 128)',
      );
    });

    test('opaque fg passes through unchanged', () {
      expect(
        ReaderContentStyles.composeOpaqueColor('rgb(10, 20, 30)', '#000'),
        'rgb(10, 20, 30)',
      );
      expect(
        ReaderContentStyles.composeOpaqueColor('#abcdef', '#000'),
        '#abcdef',
      );
    });

    test('falls back to fg when a color cannot be parsed', () {
      expect(
        ReaderContentStyles.composeOpaqueColor('rgba(1,2,3,0.5)', 'tomato'),
        'rgba(1,2,3,0.5)',
      );
      expect(
        ReaderContentStyles.composeOpaqueColor('not-a-color', '#000'),
        'not-a-color',
      );
    });

    test('parses #rgb shorthand background', () {
      // #888 -> (136,136,136); fg rgba(0,0,0,0.5) over it -> 68
      expect(
        ReaderContentStyles.composeOpaqueColor('rgba(0, 0, 0, 0.5)', '#888'),
        'rgb(68, 68, 68)',
      );
    });
  });

  group('ReaderContentStyles furigana modes', () {
    test('default mode shows furigana', () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(settings: settings);
      // Default furigana mode is 'show' → rt { font-size: 0.45em; }
      expect(css, contains('rt'));
      expect(css, contains('0.45em'));
    });

    test('hide furigana mode via themeOverride still renders rt rule',
        () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setFuriganaMode('hide');

      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('rt'));
      expect(css, contains('display: none'));
    });
  });

  group('ReaderContentStyles audiobook/selection highlight fill', () {
    // BUG-716：narrow-lane(1em 窄条 + background-position:left) 在书籍行距≠字号
    // 或 <ruby> 盒含注音轨时把条画偏（竖排往基字左侧偏移、有无振假名两种宽度不一），
    // 用户实机确认有声书与查词的注音高亮都错位。回到整句 background-color 填充：
    // 按元素 class 只刷一遍背景，注音轨天然在 ruby 元素背景盒外（BUG-110/643 不回归）。
    test('narrow-lane mechanism is fully removed in both writing modes',
        () async {
      for (final String mode in <String>['vertical-rl', 'horizontal-tb']) {
        final ReaderSettings settings = await _defaultSettings();
        await settings.setWritingMode(mode);
        final String css = ReaderContentStyles.css(settings: settings);
        expect(css, isNot(contains('--fushi-highlight-lane-color')),
            reason: '[$mode] BUG-716：高亮不再落到 lane 变量');
        expect(css,
            isNot(contains('linear-gradient(var(--fushi-highlight-lane-color')),
            reason: '[$mode] BUG-716：不再用窄条渐变绘制高亮');
        expect(css, isNot(contains('background-size: 1em 100%')),
            reason: '[$mode] BUG-716：竖排不再有 1em 窄条');
        expect(css, isNot(contains('background-size: 100% 1em')),
            reason: '[$mode] BUG-716：横排不再有 1em 窄条');
      }
    });

    test(
        'sentenceAudioHighlight ruby highlight fills the base box with full background-color',
        () async {
      final ReaderSettings settings = await _defaultSettings();
      await settings.setWritingMode('vertical-rl');

      final String css = ReaderContentStyles.css(settings: settings);

      final int sentenceAudioStart =
          css.indexOf('ruby.fushi-sentence-audio-ruby-active {');
      expect(sentenceAudioStart, isNonNegative);
      final String sentenceAudioBlock = css.substring(
        sentenceAudioStart,
        css.indexOf('}', sentenceAudioStart),
      );
      expect(
        sentenceAudioBlock,
        contains(
            'background-color: var(--fushi-sentence-audio-background-color) !important'),
        reason: 'BUG-716：ruby 有声书高亮整句填充；注音轨在 ruby 背景盒外，'
            '有无振假名宽度一致',
      );
    });

    test(
        'sentenceAudioHighlight text span highlight fills with full background-color, no box model',
        () async {
      final ReaderSettings settings = await _defaultSettings();
      await settings.setWritingMode('vertical-rl');

      final String css = ReaderContentStyles.css(settings: settings);

      expect(
        css,
        contains('.fushi-sentence-audio-cue.fushi-sentence-audio-active'),
        reason: '普通正文 cue 也必须有 active span 样式，不能只靠 CSS Highlight',
      );

      final int activeStart = css
          .indexOf('.fushi-sentence-audio-cue.fushi-sentence-audio-active {');
      expect(activeStart, isNonNegative);
      final String activeBlock = css.substring(
        activeStart,
        css.indexOf('}', activeStart),
      );
      expect(
        activeBlock,
        contains(
            'background-color: var(--fushi-sentence-audio-background-color) !important'),
        reason: 'BUG-716：普通正文 sentenceAudioHighlight 整句 background-color 填充',
      );
      expect(
        activeBlock,
        isNot(contains('line-height')),
        reason: 'active 态禁止改写盒模型。line-height:1 !important 会在书籍 CSS '
            'strut < 1em 时逐句增厚激活行盒，竖排下行盒厚度=列厚，其后所有列随播放'
            '逐句平移（TODO-1371/BUG-690）',
      );
    });

    test(
        'selection (lookup) ruby highlight also fills with full background-color',
        () async {
      // 用户 re-report：查词的注音高亮也因 narrow-lane 错位。查词 ruby 同样回填充。
      final ReaderSettings settings = await _defaultSettings();
      await settings.setWritingMode('vertical-rl');

      final String css = ReaderContentStyles.css(settings: settings);

      final int start = css.indexOf('ruby.fushi-selection-ruby-active {');
      expect(start, isNonNegative);
      final String block = css.substring(start, css.indexOf('}', start));
      expect(block, contains('background-color:'),
          reason: 'BUG-716：查词 ruby 高亮回到整句填充');
      expect(block, isNot(contains('--fushi-highlight-lane-color')),
          reason: 'BUG-716：查词 ruby 不再走窄 lane');
    });

    test('active highlight blocks are paint-only in both writing modes',
        () async {
      // TODO-1371/BUG-690 守卫：跟随句/查词/收藏的运行时 toggle 高亮（-active 类、
      // ::highlight、dict-highlight）只允许绘制层属性。任何盒模型/排版属性
      // （line-height/margin/padding/font/…）都会让「高亮激活」改变文字位置。
      const Set<String> paintOnlyAllowlist = <String>{
        'color',
        'background-color',
        'background-image',
        'background-repeat',
        'background-size',
        'background-position',
        'text-decoration-line',
        'text-decoration-color',
        'text-decoration-thickness',
        'text-underline-offset',
        'box-decoration-break',
        '-webkit-box-decoration-break',
      };
      final RegExp blockPattern = RegExp(r'([^{}]+)\{([^{}]*)\}');
      final RegExp declPattern = RegExp(r'^\s*([a-zA-Z-]+)\s*:');

      for (final String mode in <String>['vertical-rl', 'horizontal-tb']) {
        final ReaderSettings settings = await _defaultSettings();
        await settings.setWritingMode(mode);
        // TODO-2477：先做共享 CSS 词法掩码，块注释（含跨行、含花括号的）不再
        // 参与 blockPattern 配对，也不必在逐行处手判 `/*` 开头。
        final String css =
            maskCssComments(ReaderContentStyles.css(settings: settings));

        int enforcedBlocks = 0;
        for (final RegExpMatch block in blockPattern.allMatches(css)) {
          final String selector = block.group(1)!;
          final bool isToggleHighlight = selector.contains('-active') ||
              selector.contains('::highlight(') ||
              selector.contains('.fushi-dict-highlight');
          if (!isToggleHighlight) continue;
          enforcedBlocks++;
          for (final String line in block.group(2)!.split('\n')) {
            final String trimmed = line.trim();
            if (trimmed.isEmpty) continue;
            if (trimmed.startsWith('--')) continue; // 自定义变量本身不参与布局。
            final RegExpMatch? decl = declPattern.firstMatch(trimmed);
            if (decl == null) continue;
            final String property = decl.group(1)!.toLowerCase();
            expect(
              paintOnlyAllowlist.contains(property),
              isTrue,
              reason: '[$mode] 高亮 toggle 规则出现非绘制层属性 `$property`（选择器：'
                  '${selector.trim()}）。active 态改盒模型会让文字位置随高亮移动'
                  '（TODO-1371/BUG-690）；确属纯绘制属性再显式加进 allowlist',
            );
          }
        }
        expect(enforcedBlocks, greaterThan(5),
            reason: '[$mode] 守卫必须真扫到高亮 toggle 规则块，不能空转');
      }
    });

    test('horizontal ruby highlight also fills with full background-color',
        () async {
      final ReaderSettings settings = await _defaultSettings();
      await settings.setWritingMode('horizontal-tb');

      final String css = ReaderContentStyles.css(settings: settings);

      final int start = css.indexOf('ruby.fushi-sentence-audio-ruby-active {');
      expect(start, isNonNegative);
      final String block = css.substring(start, css.indexOf('}', start));
      expect(
        block,
        contains(
            'background-color: var(--fushi-sentence-audio-background-color) !important'),
        reason: 'BUG-716：横排 ruby 有声书高亮同样整句填充，rt 注音轨在上方、'
            '在 ruby 元素背景盒外',
      );
    });
  });

  group('ReaderLayoutDefaults', () {
    test('constants are consistent', () {
      expect(ReaderLayoutDefaults.fontSizePx, 22);
      expect(ReaderLayoutDefaults.bottomOverlapPx,
          ReaderLayoutDefaults.fontSizePx);
      expect(ReaderLayoutDefaults.imageWidthViewportRatio, 0.95);
    });
  });

  group('ReaderContentStyles chrome inset CSS variables', () {
    test('paginated layout contains --chrome-top-inset in padding-top',
        () async {
      final ReaderSettings settings = await _defaultSettings();
      // Default is paginated mode
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('--chrome-top-inset'));
      expect(css, contains('padding-top:'));
    });

    test('paginated layout contains --chrome-bottom-inset in padding-bottom',
        () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('--chrome-bottom-inset'));
      expect(css, contains('padding-bottom:'));
    });

    test('paginated layout padding-top uses calc with vh and var fallback 0px',
        () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(settings: settings);
      expect(
          css,
          contains(
              'padding-top: calc(${settings.marginTop}vh + var(--chrome-top-inset, 0px))'));
    });

    test(
        'paginated layout padding-bottom uses calc with vh, fontSize, and var fallback 0px',
        () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(settings: settings);
      expect(
          css,
          contains(
              'padding-bottom: calc(${settings.marginBottom}vh + ${settings.fontSize.round()}px + var(--chrome-bottom-inset, 0px))'));
    });

    test('continuous layout contains --chrome-top-inset in padding-top',
        () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setViewMode('continuous');

      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('--chrome-top-inset'));
      expect(css, contains('padding-top:'));
    });

    test('continuous layout contains --chrome-bottom-inset in padding-bottom',
        () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setViewMode('continuous');

      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('--chrome-bottom-inset'));
      expect(css, contains('padding-bottom:'));
    });

    // TODO-788：连续模式无 multicol pitch，那份独立的 fontSize px 项只是底部预留，
    // 与几何无关（不像分页 :507 的 F 要镜像 column-width/contentBox 维持翻页周期）。
    // 去掉它后「下边距」真正控制底部空白：用户调下边距=0 时不再残留约一份字号高的空白，
    // 末行下方仍由 --chrome-bottom-inset 给底栏预留。分页 :507 的 F 不动（见上方分页守卫）。
    test(
        'continuous layout padding-bottom is only marginBottom + chrome-bottom-inset (no independent fontSize term)',
        () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setViewMode('continuous');

      final String css = ReaderContentStyles.css(settings: settings);
      expect(
          css,
          contains(
              'padding-bottom: calc(${settings.marginBottom}vh + var(--chrome-bottom-inset, 0px))'));
    });

    // TODO-729：单一量纲。column-gap 固定为常量（22px），inset/margin/fontSize 不再
    // 塞进 gap——它们由 column-width(content-box) 与 padding 承载。竖排 turn 轴=scrollTop，
    // content-box 高 = page-height 扣上下 padding(margin + fontSize + 两 chrome inset)，
    // 使列周期(column-width + 22px gap) == JS pageStep，maxScroll 与对齐量同源，杜绝
    // 「翻一半跳章」（旧实现把 inset 塞进 gap 致 pitch 随 inset 漂移失配）。
    test('vertical paginated column-gap is a fixed constant (no insets)',
        () async {
      final ReaderSettings settings = await _defaultSettings();
      // Default writing-mode is vertical-rl.
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('column-gap: 22px !important;'));
      // gap 绝不再含 inset/margin/fontSize 的 calc。
      expect(css, isNot(contains('column-gap: calc(')));
    });

    test(
        'vertical paginated column-width is content-box carrying turn-axis insets',
        () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(settings: settings);
      // TODO-734：竖排 content-box 高 = reader-viewport-height(纯 V) − 上下 padding
      // （margin + fontSize + chrome insets），与 padding-top/padding-bottom 逐项镜像。
      // 基准是 --reader-viewport-height 不是 --page-height（后者含 +bottomOverlap 给图片）。
      // TODO-743：竖排 column-width 现包一层 max(<F>px, calc(...)) 坍塌地板。
      expect(
          css,
          contains(
              'column-width: max(${settings.fontSize.round()}px, calc(var(--reader-viewport-height, 100vh) - ${settings.marginTop}vh - ${settings.marginBottom}vh - ${settings.fontSize.round()}px - var(--chrome-top-inset, 0px) - var(--chrome-bottom-inset, 0px)))'));
    });

    test('horizontal paginated column-gap is the same fixed constant',
        () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setWritingMode('horizontal-tb');

      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('column-gap: 22px !important;'));
      expect(css, isNot(contains('column-gap: calc(')));
      // 横排 turn 轴=scrollLeft；content-box 宽 = page-width 扣左右 padding(margin)，
      // perpendicular 的 padding-top/bottom(含 chrome inset)不入列宽。
      expect(
          css,
          contains(
              'column-width: calc(var(--page-width, 100vw) - ${settings.marginLeft}vw - ${settings.marginRight}vw)'));
    });

    // TODO-1285：每页列数（pageColumns）根因修复。旧实现（TODO-729 遗留）只发
    // `column-count:N` 却把 column-width 钉死在整页 content-box —— CSS multicol 规范下并
    // 存时实际列数 = min(N, floor((content-box+gap)/(column-width+gap))) = min(N,1) = 1，
    // N 被整页列宽压成 1 列，「每页列数」永不生效（当年 headless 无法验证 → punt 成
    // 「留真机兜底」，实为坏结构）。正解：column-width 必须 = 单个子列宽 =
    // (content-box − (N−1)·gap)/N，浏览器才在 content-box 里正好排下 N 列；gap 仍固定
    // 22px（单量纲）。与 JS getScrollContext 的 pageStep = columnCount·(usedColW+gap) 成对，
    // N·(subW+gap) == content-box+gap，翻页网格不动（保 TODO-729/753/792 不变式）。
    test('TODO-1285 每页 N 列：column-count:N + column-width 均分成子列宽（横排）', () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setWritingMode('horizontal-tb');
      await settings.setPageColumns(2);

      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('column-count: 2 !important;'),
          reason: '每页列数 N 必须发 column-count:N');
      // gap 仍固定常量（单量纲不变式）。
      expect(css, contains('column-gap: 22px !important;'));
      // 根因修复断言：column-width 必须均分成子列宽 (content-box − (N−1)·22px)/N，
      // 绝不再是整页 content-box（否则实际列数被压回 1 列，回归失效）。
      final String base =
          'calc(var(--page-width, 100vw) - ${settings.marginLeft}vw - ${settings.marginRight}vw)';
      expect(
          css,
          contains(
              'column-width: max(1px, calc(($base - 22px) / 2)) !important;'),
          reason: 'N=2：子列宽 = (content-box − 22px)/2，浏览器才排下 2 列');
      // 防回归：绝不能退回「整页 content-box 当 column-width」的坏结构。
      expect(
          css,
          isNot(contains(
              'column-width: calc(var(--page-width, 100vw) - ${settings.marginLeft}vw - ${settings.marginRight}vw) !important;')),
          reason: '整页列宽会把 column-count:N 压成 1 列 → 每页列数失效（旧 bug）');
    });

    test('TODO-1285 每页列数=0（自动/单列）：无 column-count、列宽仍整页（字节等价）', () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setWritingMode('horizontal-tb');
      // 默认 pageColumns=0。
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, isNot(contains('column-count:')),
          reason: 'pageColumns=0 不发 column-count');
      // 单列列宽仍是整页 content-box（不被 max(1px,...) 包裹）——零回归。
      expect(
          css,
          contains(
              'column-width: calc(var(--page-width, 100vw) - ${settings.marginLeft}vw - ${settings.marginRight}vw) !important;'));
      expect(css, isNot(contains('max(1px, calc(')));
    });

    test('TODO-1285 竖排每页 3 列：子列宽 = (竖排 content-box − 2·22px)/3', () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setWritingMode('vertical-rl');
      await settings.setPageColumns(3);

      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('column-count: 3 !important;'));
      // 竖排基准是 verticalColumnWidthCss 的 max(F, calc(...))，均分后包一层 max(1px, ...)。
      final String base = ReaderContentStyles.verticalColumnWidthCss(
        marginTopVh: settings.marginTop,
        marginBottomVh: settings.marginBottom,
        fontSizePx: settings.fontSize.round(),
      );
      // totalGap = (3-1)*22 = 44。
      expect(
          css,
          contains(
              'column-width: max(1px, calc(($base - 44px) / 3)) !important;'),
          reason: '竖排 N=3：子列高 = (content-box − 44px)/3');
    });

    // 直接单测 helper 的均分代数（不经整条 css 组装）。
    test('TODO-1285 columnWidthForColumns 均分代数（N≤1 原样、N≥2 均分）', () {
      const String base = 'calc(100px)';
      // N=0/1：原样返回（零行为变化）。
      expect(
          ReaderContentStyles.columnWidthForColumns(
              baseContentBoxCss: base, pageColumns: 0, columnGapPx: 22),
          base);
      expect(
          ReaderContentStyles.columnWidthForColumns(
              baseContentBoxCss: base, pageColumns: 1, columnGapPx: 22),
          base);
      // N=2：(base − 22px)/2。
      expect(
          ReaderContentStyles.columnWidthForColumns(
              baseContentBoxCss: base, pageColumns: 2, columnGapPx: 22),
          'max(1px, calc((calc(100px) - 22px) / 2))');
      // N=4：(base − 66px)/4。
      expect(
          ReaderContentStyles.columnWidthForColumns(
              baseContentBoxCss: base, pageColumns: 4, columnGapPx: 22),
          'max(1px, calc((calc(100px) - 66px) / 4))');
    });

    // TODO-1285（相邻页/列泄露根因修复）：headless Blink 实测 pageStep/列几何均正确、
    // 且分页 CSS 一直缺 column-fill（默认 balance）——分页 multicol 规范要求显式
    // column-fill:auto，否则按规范引擎可对每个 fragment 均摊列高 → 列不落 pageStep 网格
    // → 相邻页列露出。守卫：分页 body 必发 column-fill:auto（横排/竖排/单列都发）。
    test('TODO-1285 分页 multicol 必发 column-fill: auto（横排/竖排/单列）', () async {
      for (final ({String mode, int cols}) c in <({String mode, int cols})>[
        (mode: 'horizontal-tb', cols: 2),
        (mode: 'vertical-rl', cols: 3),
        (mode: 'horizontal-tb', cols: 0),
      ]) {
        final FushiDatabase db =
            FushiDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final ReaderSettings settings = ReaderSettings(db);
        await settings.refreshFromDb();
        await settings.setWritingMode(c.mode);
        await settings.setPageColumns(c.cols);
        final String css = ReaderContentStyles.css(settings: settings);
        expect(css, contains('column-fill: auto !important;'),
            reason:
                '分页 multicol（${c.mode} pageColumns=${c.cols}）必须显式 column-fill:auto');
      }
    });

    // TODO-1285（相邻页/列泄露根因修复其二·overflow 裁剪失效兜底）：截图实测证明——
    // 相邻页的列几何上落在 body 的 padding(页边距)带里，body{overflow:hidden} 裁不掉它，
    // 唯一遮住它的是 body 的 clip-path(paint 期特性，个别 WebView 不解析/滚动不重绘就漏)。
    // 兜底：在未被 body clip-path 裁剪的 html 上加 ::before 覆盖条，四边 border 宽 == body
    // 四边 padding、border-color=背景色、pointer-events:none、z-index 压正文之上但低于 caret。
    test('TODO-1285 分页 html::before 覆盖条：引擎无关遮 padding 泄露带', () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setWritingMode('horizontal-tb');
      await settings.setPageColumns(2);
      final String css = ReaderContentStyles.css(settings: settings);

      expect(css, contains('html::before {'),
          reason: '分页必须发 html::before 覆盖条兜底 padding 泄露');
      expect(css, contains('position: fixed !important;'));
      expect(css, contains('pointer-events: none !important;'),
          reason: '覆盖条不得拦截选词/点按');
      // 四边 border 宽必须与 body padding 逐项一致（== 泄露带宽度）。
      expect(
          css,
          contains(
              'border-top-width: calc(${settings.marginTop}vh + var(--chrome-top-inset, 0px)) !important;'));
      expect(
          css,
          contains(
              'border-right-width: ${settings.marginRight}vw !important;'));
      expect(
          css,
          contains(
              'border-bottom-width: calc(${settings.marginBottom}vh + ${settings.fontSize.round()}px + var(--chrome-bottom-inset, 0px)) !important;'));
      expect(css,
          contains('border-left-width: ${settings.marginLeft}vw !important;'));
      // 覆盖条色 == 页背景色（不透明覆盖泄露文字）。
      expect(css, contains('html::before {'));
      // z-index 必须低于 caret（2147483646）以免遮住焦点/查词 caret。
      expect(css, contains('z-index: 2147483000 !important;'));
    });

    // 覆盖条只属分页：连续模式不发 html::before（避免连续滚动被 padding 条错遮）。
    test('TODO-1285 连续模式不发 html::before 覆盖条', () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setWritingMode('horizontal-tb');
      await settings.setViewMode('continuous');
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, isNot(contains('html::before {')),
          reason: '连续模式不是分页 padding 泄露模型，不应发覆盖条');
    });
  });

  group('ReaderContentStyles themed scrollbar', () {
    test('emits webkit scrollbar rules with a transparent track', () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('::-webkit-scrollbar'));
      expect(css, contains('::-webkit-scrollbar-thumb'));
      expect(css, contains('::-webkit-scrollbar-track'));
      expect(css, contains('scrollbar-width: thin;'));
    });

    test(
        'thumb colour follows the theme text colour (dark theme → light thumb)',
        () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(
        settings: settings,
        themeOverride: 'dark-theme',
      );
      // dark-theme textColor is rgba(255, 255, 255, 0.6); the thumb must reuse it.
      expect(
        css,
        contains('scrollbar-color: rgba(255, 255, 255, 0.6) transparent;'),
      );
      expect(
        css,
        contains('background-color: rgba(255, 255, 255, 0.6);'),
      );
    });

    test('thumb colour follows a light theme text colour (ecru → dark thumb)',
        () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(
        settings: settings,
        themeOverride: 'ecru-theme',
      );
      // ecru-theme textColor is rgba(0, 0, 0, 0.87).
      expect(
        css,
        contains('scrollbar-color: rgba(0, 0, 0, 0.87) transparent;'),
      );
    });

    // The native WebView2 Fluent overlay scrollbar ignores ::-webkit-scrollbar
    // and follows the UA color-scheme. Pin it to the reader theme so it flips
    // light/dark with the book background instead of the OS.
    test('light themes pin color-scheme: light', () async {
      final ReaderSettings settings = await _defaultSettings();
      for (final String theme in <String>['ecru-theme', 'water-theme']) {
        final String css = ReaderContentStyles.css(
          settings: settings,
          themeOverride: theme,
        );
        expect(css, contains('color-scheme: light;'), reason: theme);
      }
    });

    test('dark themes pin color-scheme: dark', () async {
      final ReaderSettings settings = await _defaultSettings();
      for (final String theme in <String>[
        'gray-theme',
        'dark-theme',
        'black-theme'
      ]) {
        final String css = ReaderContentStyles.css(
          settings: settings,
          themeOverride: theme,
        );
        expect(css, contains('color-scheme: dark;'), reason: theme);
      }
    });

    test('custom theme derives color-scheme from background luminance',
        () async {
      final ReaderSettings settings = await _defaultSettings();
      final String darkCss = ReaderContentStyles.css(
        settings: settings,
        themeOverride: 'custom-theme',
        customBg: '#101015',
        customFg: '#eeeeee',
      );
      expect(darkCss, contains('color-scheme: dark;'));

      final String lightCss = ReaderContentStyles.css(
        settings: settings,
        themeOverride: 'custom-theme',
        customBg: '#FAF0E6',
        customFg: '#222222',
      );
      expect(lightCss, contains('color-scheme: light;'));
    });
  });

  group('ReaderContentStyles negative margin clamping', () {
    test('negative margins are clamped to 0 in padding CSS', () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setMarginTop(-5);
      await settings.setMarginBottom(-3);
      await settings.setMarginLeft(-2);
      await settings.setMarginRight(-4);

      final String css = ReaderContentStyles.css(settings: settings);
      // Negative values must not appear in padding declarations
      expect(css, isNot(contains('padding: -')));
      expect(css, isNot(contains('padding-top: calc(-')));
      expect(css, isNot(contains('padding-bottom: calc(-')));
      // TODO-729：column-gap 现在是固定常量，天然不可能为负。
      expect(css, contains('column-gap: 22px !important;'));
      // column-width(content-box) 也不得出现负 padding 项（margin 已 clamp 到 0）。
      // TODO-734：竖排基准现为 --reader-viewport-height。
      expect(
          css,
          isNot(contains(
              'column-width: calc(var(--reader-viewport-height, 100vh) - -')));
    });

    test('overflow-wrap: anywhere is present in body', () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('overflow-wrap: anywhere'));
    });
  });

  // TODO-362（PR#3 响应式页边距）：①左右默认各 2% 留白（每行变窄）；上下默认 0%。
  // ②竖排/横排底部预留必须跟随 settings.fontSize，禁止退化成硬编码常量（防止大字号
  // 正文被底栏遮挡的回归）。
  group('TODO-362 responsive page margins', () {
    test('default left/right margin is 2%, top/bottom 0% (single source)',
        () async {
      // ReaderSettings 默认是单一真相，source 的 fallback 默认引用它。
      expect(ReaderSettings.defaultMarginLeftPercent, 2);
      expect(ReaderSettings.defaultMarginRightPercent, 2);
      expect(ReaderSettings.defaultMarginTopPercent, 0);
      expect(ReaderSettings.defaultMarginBottomPercent, 0);

      final ReaderSettings settings = await _defaultSettings();
      expect(settings.marginLeft, 2);
      expect(settings.marginRight, 2);
      expect(settings.marginTop, 0);
      expect(settings.marginBottom, 0);
    });

    test(
        'reading a default margin writes the 2% default through to the DB '
        '(existing users get 2% on first open)', () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();

      // 触发 getter → _get 把默认值写回 DB。
      expect(settings.marginLeft, 2);
      expect(settings.marginRight, 2);

      final Map<String, String> prefs = await db.getAllPrefs();
      expect(prefs['src:reader_ttu:ttu_margin_left'], '2.0');
      expect(prefs['src:reader_ttu:ttu_margin_right'], '2.0');
    });

    test('default css emits 2vw left/right padding and 0vh top/bottom',
        () async {
      final ReaderSettings settings = await _defaultSettings();
      final String css = ReaderContentStyles.css(settings: settings);
      // paddingCss = '${mt}vh ${mr}vw ${mb}vh ${ml}vw'
      expect(css, contains('padding: 0.0vh 2.0vw 0.0vh 2.0vw !important;'));
    });

    test('normalizeMarginPercent clamps to [0, 50] and maps non-finite to 0',
        () {
      expect(ReaderSettings.normalizeMarginPercent(-3), 0);
      expect(ReaderSettings.normalizeMarginPercent(60), 50);
      expect(ReaderSettings.normalizeMarginPercent(12), 12);
      expect(ReaderSettings.normalizeMarginPercent(double.nan), 0);
      expect(ReaderSettings.normalizeMarginPercent(double.infinity), 0);
    });

    // ② 回归守卫：底部预留用 ${fontSize}px（跟字号），不是硬编码常量。把字号抬到接近
    // TODO-299 的上限 128，断言底部预留 = 128px（不是 22px），否则大字号竖排正文被底栏遮挡。
    test('vertical bottom reserve scales with fontSize, not a hardcoded const',
        () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setWritingMode('vertical-rl');
      await settings.setFontSize(128);

      final String css = ReaderContentStyles.css(settings: settings);
      // 分页竖排 padding-bottom 跟随字号。
      expect(
          css,
          contains(
              'padding-bottom: calc(${settings.marginBottom}vh + 128px + var(--chrome-bottom-inset, 0px))'));
      // TODO-729：字号缩放从 column-gap 移到 column-width(content-box)——gap 固定 22px。
      // TODO-734：基准改为 --reader-viewport-height(纯 V)。竖排 content-box 高扣掉
      // fontSize(128px) 一项，列周期随字号变。
      // TODO-743：max(128px, calc(...)) 坍塌地板；宽裕视口下 max 取 calc，零变化。
      expect(
          css,
          contains(
              'column-width: max(128px, calc(var(--reader-viewport-height, 100vh) - ${settings.marginTop}vh - ${settings.marginBottom}vh - 128px - var(--chrome-top-inset, 0px) - var(--chrome-bottom-inset, 0px)))'));
      // column-gap 固定常量，不再把 fontSize 塞进去。
      expect(css, contains('column-gap: 22px !important;'));
      // 防回归：底部预留(padding-bottom)绝不能退化成 22px（旧 bottomOverlapPx 常量）。
      expect(css, isNot(contains('+ 22px + var(--chrome-bottom-inset')));
    });

    test('horizontal bottom reserve also scales with fontSize', () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setWritingMode('horizontal-tb');
      await settings.setFontSize(96);

      final String css = ReaderContentStyles.css(settings: settings);
      expect(
          css,
          contains(
              'padding-bottom: calc(${settings.marginBottom}vh + 96px + var(--chrome-bottom-inset, 0px))'));
    });

    test('source margin getters fall back to the 2% defaults', () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      ReaderHibikiSource.readerSettings = settings;
      addTearDown(() => ReaderHibikiSource.readerSettings = null);

      expect(ReaderHibikiSource.instance.ttuMarginLeft, 2);
      expect(ReaderHibikiSource.instance.ttuMarginRight, 2);
      expect(ReaderHibikiSource.instance.ttuMarginTop, 0);
      expect(ReaderHibikiSource.instance.ttuMarginBottom, 0);
    });

    test('source margin setters normalize out-of-range input', () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      ReaderHibikiSource.readerSettings = settings;
      addTearDown(() => ReaderHibikiSource.readerSettings = null);

      await ReaderHibikiSource.instance.setReaderMarginLeft(99);
      await ReaderHibikiSource.instance.setReaderMarginRight(-10);
      expect(ReaderHibikiSource.instance.ttuMarginLeft, 50);
      expect(ReaderHibikiSource.instance.ttuMarginRight, 0);
    });
  });

  group('ReaderHibikiSource live settings callbacks', () {
    test('style setting writes trigger the live callback', () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      ReaderHibikiSource.readerSettings = settings;
      addTearDown(() => ReaderHibikiSource.readerSettings = null);

      int calls = 0;
      ReaderHibikiSource.onSettingsChangedLive = () => calls++;
      addTearDown(() => ReaderHibikiSource.onSettingsChangedLive = null);

      await ReaderHibikiSource.instance.setReaderFontSize(25);
      await ReaderHibikiSource.instance.setReaderPrioritizeReaderStyles(true);
      await ReaderHibikiSource.instance.addCustomFont(name: 'Test Font');

      expect(calls, 3);
    });
  });

  group('ReaderContentStyles vertical-only CSS probes (T1)', () {
    Future<ReaderSettings> verticalSettings() async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setWritingMode('vertical-rl');
      return settings;
    }

    Future<ReaderSettings> horizontalSettings() async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setWritingMode('horizontal-tb');
      return settings;
    }

    test('vertical upright orientation emits text-orientation: upright',
        () async {
      final ReaderSettings settings = await verticalSettings();
      await settings.setVerticalTextOrientation('upright');
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('text-orientation: upright;'));
      expect(css, isNot(contains('text-orientation: mixed;')));
    });

    test('vertical mixed orientation emits text-orientation: mixed', () async {
      final ReaderSettings settings = await verticalSettings();
      await settings.setVerticalTextOrientation('mixed');
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('text-orientation: mixed;'));
      expect(css, isNot(contains('text-orientation: upright;')));
    });

    test('vertical kerning ON emits font-kerning: normal', () async {
      final ReaderSettings settings = await verticalSettings();
      await settings.setEnableVerticalFontKerning(true);
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('font-kerning: normal !important;'));
    });

    test('vertical kerning OFF omits font-kerning declaration', () async {
      final ReaderSettings settings = await verticalSettings();
      await settings.setEnableVerticalFontKerning(false);
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, isNot(contains('font-kerning')));
    });

    test('vertical VPAL ON emits font-feature-settings vpal 1', () async {
      final ReaderSettings settings = await verticalSettings();
      await settings.setEnableFontVPAL(true);
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains("font-feature-settings: 'vpal' 1 !important;"));
    });

    test('vertical VPAL OFF omits vpal feature setting', () async {
      final ReaderSettings settings = await verticalSettings();
      await settings.setEnableFontVPAL(false);
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, isNot(contains('vpal')));
    });

    test('horizontal-tb gates out all three even with every toggle ON',
        () async {
      final ReaderSettings settings = await horizontalSettings();
      await settings.setVerticalTextOrientation('upright');
      await settings.setEnableVerticalFontKerning(true);
      await settings.setEnableFontVPAL(true);

      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('horizontal-tb'));
      expect(css, isNot(contains('text-orientation')));
      expect(css, isNot(contains('font-kerning')));
      expect(css, isNot(contains('vpal')));
    });
  });
  // TODO-810：手机竖排书顶部 notch（摄像头）区漏出上一页文字。根因=WebView 是 Positioned.fill
  // 全铺 edge-to-edge，notch 遮挡只靠 body 透明 padding-top（=var(--chrome-top-inset)）腾出物理区，
  // 没有真实裁剪；竖排翻页轴=纵向 scrollTop 与顶部安全带同轴，上一页文字滚经透明带落入 notch 可见。
  // 修复=在 body 上加 clip-path: inset(...) 在顶/底 inset 带处真实裁掉滚入的文字（横竖排同生效，
  // 横排顶带本无字故无副作用；不动高度/pageStep/column-width/scrollTop 几何）。
  // 此守卫锁住分页+连续两模式 body 块都含 clip-path 且引用 --chrome-top-inset（撤回即红）。
  group('TODO-810 notch clip-path guards', () {
    test('paginated body clips top/bottom inset bands via clip-path inset',
        () async {
      final ReaderSettings settings = await _defaultSettings();
      // Default is paginated mode.
      final String css = ReaderContentStyles.css(settings: settings);
      // TODO-792：分页 clip-path 从「只裁 chrome inset」扩成「裁到正文内容盒(=全 padding，四边
      // 各含 margin/chrome/F)」，一举裁掉 notch 滚入文字 + 相邻页/列在留白区的露出(bleed)。
      expect(css, contains('clip-path: inset(calc('),
          reason: '分页 body clip-path 必须裁到正文内容盒（inset 用 calc 含 padding 表达式）');
      expect(css, contains('var(--chrome-top-inset, 0px))'),
          reason: 'clip 顶边须含 chrome-top（防 notch 滚入），且并入 margin（裁相邻页露出）');
      expect(css, contains('var(--chrome-bottom-inset, 0px))'),
          reason: 'clip 底边须含 chrome-bottom');
    });

    test('continuous body clips top/bottom inset bands via clip-path inset',
        () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setViewMode('continuous');

      final String css = ReaderContentStyles.css(settings: settings);
      expect(
          css,
          contains(
              'clip-path: inset(var(--chrome-top-inset, 0px) 0 var(--chrome-bottom-inset, 0px) 0) !important;'),
          reason: '连续 body 同样在顶/底 inset 带硬裁');
    });

    test('vertical paginated still clips (notch leak path is vertical)',
        () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setWritingMode('vertical-rl');

      final String css = ReaderContentStyles.css(settings: settings);
      // TODO-792：竖排分页 clip 现裁到内容盒（inset(calc(...)）——仍含 chrome inset 防 notch。
      expect(css, contains('clip-path: inset(calc('));
      expect(css, contains('var(--chrome-top-inset, 0px))'));
    });
  });

  // TODO-718（真机铁证·2026-06-25）：连续模式隐藏溢出轴只能放 html，不能放 body。
  // 放 body 会触发 CSS「一轴非 visible→另一轴算 auto」使 body 成为滚动容器，
  // scrollingElement/root 与真实 window 滚动器错位 → 横排滚轮跳章+进度卡 0.34%、
  // 竖排恢复(scrollToCharOffset 写 root.scrollLeft)幽灵→视口留章首。守卫两种写向。
  group('TODO-718 连续溢出轴只放 html（防 body 成滚动容器回归）', () {
    Future<String> continuousCss(String writingMode) async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setViewMode('continuous');
      await settings.setWritingMode(writingMode);
      return ReaderContentStyles.css(settings: settings);
    }

    test('横排连续：overflow-x:hidden 在 html{}、不在 html, body{}', () async {
      final String css = await continuousCss('horizontal-tb');
      expect(css, contains('html {\n  overflow-x: hidden !important;\n}'),
          reason: 'overflow-x:hidden 必须只放 html');
      expect(css, isNot(contains('html, body {\n  overflow-x: hidden')),
          reason: 'overflow-x:hidden 绝不能放 body（否则 body 成滚动容器→滚轮跳章/进度卡）');
    });

    test('竖排连续：overflow-y:hidden 在 html{}、不在 html, body{}', () async {
      final String css = await continuousCss('vertical-rl');
      expect(css, contains('html {\n  overflow-y: hidden !important;\n}'),
          reason: 'overflow-y:hidden 必须只放 html');
      expect(css, isNot(contains('html, body {\n  overflow-y: hidden')),
          reason: 'overflow-y:hidden 绝不能放 body（否则恢复 root.scrollLeft 幽灵→视口留章首）');
    });
  });

  // TODO-861①（段落间距）：纯 CSS，按书写轴选 margin 轴，=0 不注入。
  group('TODO-861① paragraph spacing CSS', () {
    test('横排 paragraphSpacing>0 注入 top/bottom margin', () async {
      final ReaderSettings settings = await _defaultSettings();
      await settings.setWritingMode('horizontal-tb');
      await settings.setParagraphSpacing(1.5);
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('margin-top: 1.5em !important;'));
      expect(css, contains('margin-bottom: 1.5em !important;'));
      expect(css, isNot(contains('margin-right: 1.5em')));
    });

    test('竖排 paragraphSpacing>0 注入 left/right margin', () async {
      final ReaderSettings settings = await _defaultSettings();
      await settings.setWritingMode('vertical-rl');
      await settings.setParagraphSpacing(2.0);
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('margin-right: 2.0em !important;'));
      expect(css, contains('margin-left: 2.0em !important;'));
      expect(css, isNot(contains('margin-top: 2.0em')));
    });

    test('paragraphSpacing=0 不注入任何 p{margin', () async {
      final ReaderSettings settings = await _defaultSettings();
      await settings.setParagraphSpacing(0);
      final String css = ReaderContentStyles.css(settings: settings);
      // =0 时段距分支返回空串：margin-top/bottom/left/right 任一段距注入都不应出现。
      expect(css, isNot(contains('margin-top: 0.0em')));
      expect(css, isNot(contains('margin-right: 0.0em')));
    });
  });

  // TODO-861④（图片防剧透）：blurImages=true 注入 .blurred filter、false 不注入。
  group('TODO-861④ blur images CSS', () {
    test('blurImages=true 注入 .blurred 的 24px 模糊', () async {
      final ReaderSettings settings = await _defaultSettings();
      await settings.setBlurImages(true);
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('img.block-img.blurred'));
      expect(css, contains('filter: blur(24px) !important;'));
      expect(css, contains('clip-path: inset(0) !important;'));
    });

    test('blurImages=false 不注入 .blurred 规则', () async {
      final ReaderSettings settings = await _defaultSettings();
      await settings.setBlurImages(false);
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, isNot(contains('.blurred')));
      expect(css, isNot(contains('filter: blur(24px)')));
    });
  });

  // TODO-1285：每页列数设置写穿守卫——UI onChanged → source.setReaderPageColumns →
  // ReaderSettings.setPageColumns → preferences 表 `ttu_page_columns`。getter 反读一致。
  group('TODO-1285 每页列数写穿 DB', () {
    test('setPageColumns 写穿 preferences 且 getter 反读一致', () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();

      expect(settings.pageColumns, 0, reason: '默认自动（0）');
      await settings.setPageColumns(3);
      expect(settings.pageColumns, 3, reason: 'getter 立即反读新值');

      final Map<String, String> prefs = await db.getAllPrefs();
      expect(prefs['src:reader_ttu:ttu_page_columns'], '3',
          reason: '每页列数必须落到 preferences 表（写穿）');

      // 独立实例重新从 DB 加载，仍读到 3（真持久化，非内存态）。
      final ReaderSettings reloaded = ReaderSettings(db);
      await reloaded.refreshFromDb();
      expect(reloaded.pageColumns, 3);
    });

    test('source.setReaderPageColumns 经 ReaderSettings 写穿并反读', () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      ReaderHibikiSource.readerSettings = settings;
      addTearDown(() => ReaderHibikiSource.readerSettings = null);

      await ReaderHibikiSource.instance.setReaderPageColumns(2);
      expect(ReaderHibikiSource.instance.ttuPageColumns, 2);
      final Map<String, String> prefs = await db.getAllPrefs();
      expect(prefs['src:reader_ttu:ttu_page_columns'], '2');
    });
  });
}
