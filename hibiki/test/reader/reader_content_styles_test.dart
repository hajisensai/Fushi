import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/reader/reader_content_styles.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';

Future<ReaderSettings> _defaultSettings() async {
  final HibikiDatabase db = HibikiDatabase.forTesting(NativeDatabase.memory());
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
      // 宽泛 contains('#fff')——CSS 里另有无关的 `--hoshi-system-text-color: #fff`
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
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setWritingMode('horizontal-tb');

      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('horizontal-tb'));
      expect(css, isNot(contains('text-orientation')));
    });

    test('continuous mode produces different layout', () async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
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
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setFuriganaMode('hide');

      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('rt'));
      expect(css, contains('display: none'));
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
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
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
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setViewMode('continuous');

      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('--chrome-bottom-inset'));
      expect(css, contains('padding-bottom:'));
    });

    test(
        'continuous layout padding-bottom includes fontSize and chrome-bottom-inset',
        () async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setViewMode('continuous');

      final String css = ReaderContentStyles.css(settings: settings);
      expect(
          css,
          contains(
              'padding-bottom: calc(${settings.marginBottom}vh + ${settings.fontSize.round()}px + var(--chrome-bottom-inset, 0px))'));
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
      // 竖排 content-box 高 = page-height − 上下 padding（margin + fontSize + chrome insets），
      // 与 padding-top/padding-bottom 逐项镜像。
      expect(
          css,
          contains(
              'column-width: calc(var(--page-height, 100vh) - ${settings.marginTop}vh - ${settings.marginBottom}vh - ${settings.fontSize.round()}px - var(--chrome-top-inset, 0px) - var(--chrome-bottom-inset, 0px))'));
    });

    test('horizontal paginated column-gap is the same fixed constant',
        () async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
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

    // TODO-729 双页 spread：pageColumns>0 → column-count:N。CSS 层守住单一量纲不变式
    // （gap 仍固定 22px、column-width 仍 content-box）；列宽是否仍 = 一屏滚动量由 N
    // 主导还是 column-width 主导，是 headless WebView 无法验证的几何点（decision #2），
    // 留真机双页翻到章尾兜底。这里只锁 CSS 结构不回退。
    test(
        'double-page spread emits column-count but keeps fixed gap + content-box width',
        () async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setWritingMode('horizontal-tb');
      await settings.setPageColumns(2);

      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('column-count: 2 !important;'),
          reason: '双页 spread 必须发 column-count');
      // 单一量纲不变式：gap 仍固定常量、column-width 仍 content-box（不被 spread 破坏）。
      expect(css, contains('column-gap: 22px !important;'));
      expect(
          css,
          contains(
              'column-width: calc(var(--page-width, 100vw) - ${settings.marginLeft}vw - ${settings.marginRight}vw)'));
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
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
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
      expect(css,
          isNot(contains('column-width: calc(var(--page-height, 100vh) - -')));
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
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
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
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
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
      // 竖排 content-box 高扣掉 fontSize(128px) 一项，列周期随字号变。
      expect(
          css,
          contains(
              'column-width: calc(var(--page-height, 100vh) - ${settings.marginTop}vh - ${settings.marginBottom}vh - 128px - var(--chrome-top-inset, 0px) - var(--chrome-bottom-inset, 0px))'));
      // column-gap 固定常量，不再把 fontSize 塞进去。
      expect(css, contains('column-gap: 22px !important;'));
      // 防回归：底部预留(padding-bottom)绝不能退化成 22px（旧 bottomOverlapPx 常量）。
      expect(css, isNot(contains('+ 22px + var(--chrome-bottom-inset')));
    });

    test('horizontal bottom reserve also scales with fontSize', () async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
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
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
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
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      ReaderHibikiSource.readerSettings = settings;
      addTearDown(() => ReaderHibikiSource.readerSettings = null);

      await ReaderHibikiSource.instance.setTtuMarginLeft(99);
      await ReaderHibikiSource.instance.setTtuMarginRight(-10);
      expect(ReaderHibikiSource.instance.ttuMarginLeft, 50);
      expect(ReaderHibikiSource.instance.ttuMarginRight, 0);
    });
  });

  group('ReaderHibikiSource live settings callbacks', () {
    test('style setting writes trigger the live callback', () async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      ReaderHibikiSource.readerSettings = settings;
      addTearDown(() => ReaderHibikiSource.readerSettings = null);

      int calls = 0;
      ReaderHibikiSource.onSettingsChangedLive = () => calls++;
      addTearDown(() => ReaderHibikiSource.onSettingsChangedLive = null);

      await ReaderHibikiSource.instance.setTtuFontSize(25);
      await ReaderHibikiSource.instance.setTtuPrioritizeReaderStyles(true);
      await ReaderHibikiSource.instance.addCustomFont(name: 'Test Font');

      expect(calls, 3);
    });
  });

  group('ReaderContentStyles vertical-only CSS probes (T1)', () {
    Future<ReaderSettings> verticalSettings() async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setWritingMode('vertical-rl');
      return settings;
    }

    Future<ReaderSettings> horizontalSettings() async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
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
}
