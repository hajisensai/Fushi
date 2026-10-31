/// 卡面外观（「Fushi 卡片」模板的可视化定制）：左 / 上是控件，右 / 下是**实时预览**。
///
/// 预览就是复习页的真实卡面组件（[srsCardFaceBuilderProvider]）渲染同一份模板：样例卡或
/// 用户自己的一张 Fushi 卡片，可切正面 / 背面、浅色 / 深色、手机 / 桌面宽度。改动立即写进
/// 偏好（[SrsCardAppearance]，按 profile），预览与复习页的卡面经 `__fushiSrsSetTheme` 原地换
/// 外观，不重跑卡片脚本——所以拖滑块时预览跟手。
///
/// 宽（≥ 840dp）：控件栏 400dp 在左、预览在右；窄：预览在上（约四成高）、控件在下滚动。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/custom_fonts_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_fushi_card_view.dart';
import 'package:fushi/src/reader/reader_settings.dart' show FontTarget;
import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi/src/srs/srs_card_sample.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 自定义强调色的候选（色相环上均匀取，外加 Fushi 默认绿）。
const List<int> kSrsCardAccentSwatches = <int>[
  0xFF386A58,
  0xFF3F5F90,
  0xFF6750A4,
  0xFF8E4585,
  0xFFB3261E,
  0xFFB25E02,
  0xFF7D6A00,
  0xFF33691E,
  0xFF00696F,
  0xFF5D5F5F,
];

/// 预览里用哪张卡。
enum SrsCardPreviewSource { sample, mine }

/// 预览宽度：手机（390 CSS px，单栏）/ 桌面（1100，双栏）。
enum SrsCardPreviewWidth { phone, desktop }

/// 宽屏两栏布局的断点（逻辑像素）。
const double kSrsCardAppearanceWideBreakpoint = 840;

/// 手机预览的卡面宽度上限（逻辑像素）。
const double kSrsCardPreviewPhoneWidth = 390;

/// 桌面版式需要的最小排版宽度（CSS px）：预览区比它窄时用页面内 zoom 缩到这个宽度排版。
const double kSrsCardPreviewDesktopMinWidth = 760;

/// 桌面版式在窄预览区里模拟的视口宽度（CSS px）。
const double kSrsCardPreviewDesktopViewport = 1100;

/// 预览框：卡面宽度、左边距（已对齐到整设备像素）、强制版式与页面内 zoom。
class SrsCardPreviewFrame {
  const SrsCardPreviewFrame({
    required this.width,
    required this.left,
    required this.layout,
    this.pageZoom,
  });

  final double width;
  final double left;
  final SrsCardLayout layout;
  final double? pageZoom;
}

/// 按预览档位与可用宽度算预览框（纯函数，测试直接调）。
SrsCardPreviewFrame srsCardPreviewFrame(
  SrsCardPreviewWidth w, {
  required double availableWidth,
  required double devicePixelRatio,
}) {
  double snap(double v) =>
      (v * devicePixelRatio).floorToDouble() / devicePixelRatio;
  if (w == SrsCardPreviewWidth.phone) {
    final double width = snap(
      availableWidth < kSrsCardPreviewPhoneWidth
          ? availableWidth
          : kSrsCardPreviewPhoneWidth,
    );
    return SrsCardPreviewFrame(
      width: width,
      left: snap((availableWidth - width) / 2),
      layout: SrsCardLayout.narrow,
    );
  }
  final double width = snap(availableWidth);
  return SrsCardPreviewFrame(
    width: width,
    left: 0,
    layout: SrsCardLayout.wide,
    pageZoom: width < kSrsCardPreviewDesktopMinWidth
        ? width / kSrsCardPreviewDesktopViewport
        : null,
  );
}

/// 打开卡面外观页（复习页 ⋯、笔记类型管理页 Fushi 卡片那一行共用）。
Future<void> openSrsCardAppearancePage(BuildContext context) =>
    Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => const SrsCardAppearancePage(),
      ),
    );

class SrsCardAppearancePage extends ConsumerStatefulWidget {
  const SrsCardAppearancePage({super.key});

  @override
  ConsumerState<SrsCardAppearancePage> createState() =>
      _SrsCardAppearancePageState();
}

class _SrsCardAppearancePageState extends ConsumerState<SrsCardAppearancePage> {
  bool _answer = true;
  bool _previewCollapsed = false;
  bool? _dark;
  SrsCardPreviewWidth? _width;
  SrsCardPreviewSource _source = SrsCardPreviewSource.sample;

  AnkiRenderedCard? _sample;
  String _css = FushiCardNoteType.template.css;

  /// 用户的 Fushi 卡片模板未改过：预览与复习页一样走原生 + 释义 WebView。
  bool _sampleNative = true;
  final String _sampleDefinitions =
      _renderSample(
        FushiCardNoteType.template.front,
        kFushiCardDefinitionsTemplate,
      )?.answer ??
      '';
  SrsRenderedCard? _mine;

  @override
  void initState() {
    super.initState();
    _sample = _renderSample(
      FushiCardNoteType.template.front,
      FushiCardNoteType.template.back,
    );
    unawaited(_loadCards());
  }

  static AnkiRenderedCard? _renderSample(String front, String back) {
    try {
      return renderAnkiCard(
        questionTemplate: front,
        answerTemplate: back,
        noteFields: srsSampleCardFields(),
        cardOrd: 0,
        isCloze: false,
      );
    } on AnkiTemplateError {
      return null;
    }
  }

  /// 用户当前的 Fushi 卡片模板（可能改过 CSS / 模板）渲染样例，再找一张用户自己的卡。
  Future<void> _loadCards() async {
    try {
      final SrsDbStore? store = await readSrsStore(ref);
      if (store == null) return;
      final SrsNoteTypeView? type = await store.noteType(
        store.fushiCardNoteTypeId,
      );
      if (type != null && type.templates.isNotEmpty) {
        final Map<String, String> idToName = <String, String>{
          for (final SrsFieldDef f in type.fields) f.id: f.name,
        };
        final SrsTemplateDef tpl = type.templates.first;
        final AnkiRenderedCard? sample = _renderSample(
          templateIdsToNames(tpl.front, idToName),
          templateIdsToNames(tpl.back, idToName),
        );
        if (mounted && sample != null) {
          setState(() {
            _sample = sample;
            _css = type.css;
            _sampleNative =
                templateIdsToNames(tpl.front, idToName) ==
                    FushiCardNoteType.template.front &&
                templateIdsToNames(tpl.back, idToName) ==
                    FushiCardNoteType.template.back &&
                type.css == FushiCardNoteType.template.css;
          });
        }
      }
      SrsRenderedCard? mine;
      for (final String noteId in await store.noteIdsOfType(
        store.fushiCardNoteTypeId,
      )) {
        for (final SrsCardCacheRow c in await store.cardsOfNote(noteId)) {
          if (c.hidden) continue;
          mine = await store.renderCard(c.id);
          if (mine != null) break;
        }
        if (mine != null) break;
      }
      if (mounted && mine != null) setState(() => _mine = mine);
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsCardAppearance.load', e, stack);
    }
  }

  SrsCardAppearance get _appearance => ref.watch(srsCardAppearanceProvider);

  void _set(SrsCardAppearance a) {
    final AppModel app = ref.read(appProvider);
    srsRunLogged('SrsCardAppearance.save', () => app.setSrsCardAppearance(a));
  }

  // ---------------------------------------------------------------- 字体

  /// 卡面字体链的摘要（字体库「复习卡片」用途里启用的字体，按顺序）。
  String _fontSummary(List<Map<String, dynamic>> fonts) {
    final List<String> names = <String>[
      for (final Map<String, dynamic> f in fonts)
        if ((f['enabled'] as bool? ?? true) && f['name'] is String)
          f['name'] as String,
    ];
    return names.isEmpty
        ? t.srs_card_appearance_font_default
        : names.join(' · ');
  }

  /// 卡面字体走统一字体库：已有字体、推荐下载、URL / 文件导入、系统字体、用途徽章都在那里。
  Future<void> _openFontLibrary() => Navigator.of(context).push<void>(
    adaptivePageRoute<void>(
      context: context,
      builder: (_) => const CustomFontsPage(target: FontTarget.srsCard),
    ),
  );

  // ---------------------------------------------------------------- 页面

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    return FushiPageScaffold(
      title: t.srs_card_appearance_title,
      header: apple ? null : _buildTopBar(context),
      actions: apple
          ? <Widget>[
              FushiIconButton(
                key: _resetItem.key,
                icon: _resetItem.icon,
                tooltip: _resetItem.label,
                onTap: _resetItem.onPressed,
              ),
            ]
          : const <Widget>[],
      body: Builder(builder: _buildBody),
    );
  }

  FushiToolbarItem get _resetItem => FushiToolbarItem(
    key: const ValueKey<String>('srs-card-appearance-reset'),
    icon: FushiIcons.refresh,
    label: t.srs_card_appearance_reset,
    onPressed: () => _set(const SrsCardAppearance()),
  );

  Widget _buildTopBar(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final NavigatorState? navigator = Navigator.maybeOf(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.gap,
      ),
      child: FushiFloatingTopBar(
        title: t.srs_card_appearance_title,
        leading: <FushiToolbarItem>[
          if (navigator != null && navigator.canPop())
            FushiToolbarItem(
              icon: FushiIcons.back,
              label: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => unawaited(navigator.maybePop()),
            ),
        ],
        actions: <List<FushiToolbarItem>>[
          <FushiToolbarItem>[_resetItem],
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double top = tokens.spacing.gap + MediaQuery.paddingOf(context).top;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final bool wide = c.maxWidth >= kSrsCardAppearanceWideBreakpoint;
        final SrsCardPreviewWidth width =
            _width ??
            (wide ? SrsCardPreviewWidth.desktop : SrsCardPreviewWidth.phone);
        if (wide) {
          return Padding(
            padding: EdgeInsets.only(top: top),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SizedBox(width: 400, child: _keepHeader(_controls(context))),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      0,
                      0,
                      tokens.spacing.page,
                      tokens.spacing.page,
                    ),
                    child: _preview(context, width),
                  ),
                ),
              ],
            ),
          );
        }
        // 窄屏：预览在上、控件在下。预览高度取可用高度的 36%，夹在 [200, 340]：
        // 矮屏少占、高屏也不超过上限，控件区始终至少留六成以上；预览工具条右端可整块
        // 收起（收起时连 WebView 一起卸掉，只留工具条）。
        final double previewHeight = (c.maxHeight * 0.36).clamp(200.0, 340.0);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.page,
                top,
                tokens.spacing.page,
                tokens.spacing.gap,
              ),
              child: _previewCollapsed
                  ? _previewToolbar(context, width, collapsible: true)
                  : SizedBox(
                      height: previewHeight,
                      child: _preview(context, width, collapsible: true),
                    ),
            ),
            Expanded(child: _keepHeader(_controls(context))),
          ],
        );
      },
    );
  }

  /// 控件列表的滚动不往上冒：页面顶栏不随滚动隐藏（这页的预览钉在顶栏下方，顶栏一藏
  /// 就在预览上方留出一条空白）。
  Widget _keepHeader(Widget child) => NotificationListener<ScrollNotification>(
    onNotification: (ScrollNotification _) => true,
    child: child,
  );

  // ---------------------------------------------------------------- 预览

  Widget _preview(
    BuildContext context,
    SrsCardPreviewWidth width, {
    bool collapsible = false,
  }) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData base = Theme.of(context);
    final bool dark = _dark ?? base.brightness == Brightness.dark;
    final Brightness want = dark ? Brightness.dark : Brightness.light;
    final ThemeData previewTheme = base.brightness == want
        ? base
        : base.copyWith(
            brightness: want,
            colorScheme: ColorScheme.fromSeed(
              seedColor: base.colorScheme.primary,
              brightness: want,
            ),
          );
    final SrsCardFaceBuilder faceBuilder = ref.watch(
      srsCardFaceBuilderProvider,
    );
    final bool mine = _source == SrsCardPreviewSource.mine && _mine != null;
    final String body = mine
        ? (_answer ? _mine!.answer : _mine!.question)
        : (_answer ? _sample?.answer : _sample?.question) ?? '';
    final String css = mine ? _mine!.css : _css;
    final String language = ref.read(appProvider).defaultContentLanguage;
    final SrsCardFace face = SrsCardFace(
      cardId: 'appearance-preview-${mine ? 'mine' : 'sample'}',
      showingAnswer: _answer,
      bodyHtml: body,
      css: css,
      languageCode: language.isEmpty ? 'ja' : language,
      onBridgeKey: (String token) {
        if (token == 'Space' || token == 'Enter') {
          setState(() => _answer = !_answer);
        }
      },
      bridgeKeys: kSrsBrowseBridgeKeys,
      fushiCard: true,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: tokens.spacing.gap,
      children: <Widget>[
        _previewToolbar(context, width, collapsible: collapsible),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(tokens.radii.group),
            child: ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints c) {
                  final SrsCardPreviewFrame frame = srsCardPreviewFrame(
                    width,
                    availableWidth: c.maxWidth,
                    devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                  );
                  // 卡面 WebView 一律 1:1 设备像素渲染：不在 Flutter 侧缩放平台视图（缩放的是
                  // 已栅格化的纹理，文字必糊）；位置对齐到整设备像素（亚像素偏移同样会让纹理
                  // 采样发虚）。「手机 / 桌面」由宿主类名强制版式，桌面版式在窄预览区里用页面内
                  // CSS zoom 按缩小后的尺寸重排重绘。
                  return Padding(
                    padding: EdgeInsets.only(left: frame.left),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        key: const ValueKey<String>('srs-card-preview-frame'),
                        width: frame.width,
                        height: c.maxHeight,
                        child: Theme(
                          data: previewTheme,
                          child: ColoredBox(
                            color: srsCardColorScheme(
                              _appearance,
                              previewTheme.colorScheme,
                            ).surface,
                            child: _faceView(
                              context,
                              face.withLayout(
                                frame.layout,
                                pageZoom: frame.pageZoom,
                              ),
                              faceBuilder,
                              mine: mine,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 预览卡面：模板未改的 Fushi 卡片与复习页同样走原生混合渲染，否则整面 WebView。
  Widget _faceView(
    BuildContext context,
    SrsCardFace face,
    SrsCardFaceBuilder faceBuilder, {
    required bool mine,
  }) {
    final String? defs = mine
        ? _mine!.fushiCardDefinitions
        : (_sampleNative ? _sampleDefinitions : null);
    if (defs == null) return faceBuilder(context, face);
    return SrsFushiCardView(
      key: const ValueKey<String>('srs-card-preview-native'),
      face: face,
      fields: mine ? _mine!.fields : srsSampleCardFields(),
      definitionsHtml: defs,
    );
  }

  /// 预览工具条：正反面、深浅色、手机 / 桌面、样例 / 我的卡；[collapsible] 时末尾带
  /// 收起 / 展开预览的按钮（窄屏）。
  Widget _previewToolbar(
    BuildContext context,
    SrsCardPreviewWidth width, {
    bool collapsible = false,
  }) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool dark = _dark ?? Theme.of(context).brightness == Brightness.dark;
    return Wrap(
      spacing: tokens.spacing.gap,
      runSpacing: tokens.spacing.gap / 2,
      alignment: WrapAlignment.center,
      children: <Widget>[
        FushiSegmentedButton<bool>(
          key: const ValueKey<String>('srs-card-preview-side'),
          showSelectedIcon: false,
          segments: <ButtonSegment<bool>>[
            ButtonSegment<bool>(
              value: false,
              label: Text(t.srs_card_appearance_preview_front),
            ),
            ButtonSegment<bool>(
              value: true,
              label: Text(t.srs_card_appearance_preview_back),
            ),
          ],
          selected: <bool>{_answer},
          onSelectionChanged: (Set<bool> s) =>
              setState(() => _answer = s.first),
        ),
        FushiSegmentedButton<bool>(
          key: const ValueKey<String>('srs-card-preview-brightness'),
          showSelectedIcon: false,
          segments: <ButtonSegment<bool>>[
            ButtonSegment<bool>(
              value: false,
              icon: const Icon(FushiIcons.lightMode),
              tooltip: t.srs_card_appearance_preview_light,
            ),
            ButtonSegment<bool>(
              value: true,
              icon: const Icon(FushiIcons.darkMode),
              tooltip: t.srs_card_appearance_preview_dark,
            ),
          ],
          selected: <bool>{dark},
          onSelectionChanged: (Set<bool> s) => setState(() => _dark = s.first),
        ),
        FushiSegmentedButton<SrsCardPreviewWidth>(
          key: const ValueKey<String>('srs-card-preview-width'),
          showSelectedIcon: false,
          segments: <ButtonSegment<SrsCardPreviewWidth>>[
            ButtonSegment<SrsCardPreviewWidth>(
              value: SrsCardPreviewWidth.phone,
              icon: const Icon(FushiIcons.phone),
              tooltip: t.srs_card_appearance_preview_phone,
            ),
            ButtonSegment<SrsCardPreviewWidth>(
              value: SrsCardPreviewWidth.desktop,
              icon: const Icon(FushiIcons.laptop),
              tooltip: t.srs_card_appearance_preview_desktop,
            ),
          ],
          selected: <SrsCardPreviewWidth>{width},
          onSelectionChanged: (Set<SrsCardPreviewWidth> s) =>
              setState(() => _width = s.first),
        ),
        if (_mine != null)
          FushiSegmentedButton<SrsCardPreviewSource>(
            key: const ValueKey<String>('srs-card-preview-source'),
            showSelectedIcon: false,
            segments: <ButtonSegment<SrsCardPreviewSource>>[
              ButtonSegment<SrsCardPreviewSource>(
                value: SrsCardPreviewSource.sample,
                label: Text(t.srs_card_appearance_preview_sample),
              ),
              ButtonSegment<SrsCardPreviewSource>(
                value: SrsCardPreviewSource.mine,
                label: Text(t.srs_card_appearance_preview_mine),
              ),
            ],
            selected: <SrsCardPreviewSource>{_source},
            onSelectionChanged: (Set<SrsCardPreviewSource> s) =>
                setState(() => _source = s.first),
          ),
        if (collapsible)
          FushiIconButton(
            key: const ValueKey<String>('srs-card-preview-collapse'),
            icon: _previewCollapsed
                ? FushiIcons.expandMore
                : FushiIcons.expandLess,
            tooltip: t.srs_note_types_preview,
            onTap: () => setState(() => _previewCollapsed = !_previewCollapsed),
          ),
      ],
    );
  }

  // ---------------------------------------------------------------- 控件

  Widget _controls(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsCardAppearance a = _appearance;
    String pct(double v) => '${(v * 100).round()}%';
    final List<Widget> sections = <Widget>[
      // 其它卡片类型（Anki 导入牌组、Lapis、自建）的设计系统样式覆盖：下面各节只管 Fushi 卡片，
      // 这一项管其余全部卡片，放最前面。
      AdaptiveSettingsSection(
        title: t.srs_card_appearance_section_other,
        children: <Widget>[
          AdaptiveSettingsSwitchRow(
            key: const ValueKey<String>('srs-card-design-skin'),
            title: t.srs_card_appearance_design_skin,
            subtitle: t.srs_card_appearance_design_skin_hint,
            value: a.designSkin,
            onChanged: (bool v) => _set(a.copyWith(designSkin: v)),
          ),
        ],
      ),
      AdaptiveSettingsSection(
        title: t.srs_card_appearance_section_fonts,
        children: <Widget>[
          AdaptiveSettingsNavigationRow(
            key: const ValueKey<String>('srs-card-font-library'),
            title: t.srs_card_appearance_font,
            subtitle:
                '${_fontSummary(ref.watch(srsCardFontsProvider))}\n'
                '${t.srs_card_appearance_font_hint}',
            icon: FushiIcons.font,
            onTap: () =>
                srsRunLogged('SrsCardAppearance.fonts', _openFontLibrary),
          ),
        ],
      ),
      AdaptiveSettingsSection(
        title: t.srs_card_appearance_section_text,
        children: <Widget>[
          AdaptiveSettingsSliderRow(
            key: const ValueKey<String>('srs-card-text-scale'),
            title: t.srs_card_appearance_text_size,
            readout: pct(a.textScale),
            value: a.textScale,
            min: SrsCardAppearance.minTextScale,
            max: SrsCardAppearance.maxTextScale,
            divisions: 11,
            onChanged: (double v) => _set(a.copyWith(textScale: v)),
          ),
          AdaptiveSettingsSliderRow(
            key: const ValueKey<String>('srs-card-term-scale'),
            title: t.srs_card_appearance_term_size,
            readout: pct(a.termScale),
            value: a.termScale,
            min: SrsCardAppearance.minTermScale,
            max: SrsCardAppearance.maxTermScale,
            divisions: 12,
            onChanged: (double v) => _set(a.copyWith(termScale: v)),
          ),
          AdaptiveSettingsSliderRow(
            key: const ValueKey<String>('srs-card-line-spacing'),
            title: t.srs_card_appearance_line_spacing,
            readout: pct(a.lineSpacing),
            value: a.lineSpacing,
            min: SrsCardAppearance.minLineSpacing,
            max: SrsCardAppearance.maxLineSpacing,
            divisions: 9,
            onChanged: (double v) => _set(a.copyWith(lineSpacing: v)),
          ),
        ],
      ),
      AdaptiveSettingsSection(
        title: t.srs_card_appearance_section_color,
        children: <Widget>[
          AdaptiveSettingsSegmentedRow<SrsCardColorSource>(
            key: const ValueKey<String>('srs-card-color-source'),
            title: t.srs_card_appearance_section_color,
            selected: a.colorSource,
            segments: <ButtonSegment<SrsCardColorSource>>[
              ButtonSegment<SrsCardColorSource>(
                value: SrsCardColorSource.app,
                label: Text(t.srs_card_appearance_color_app),
              ),
              ButtonSegment<SrsCardColorSource>(
                value: SrsCardColorSource.custom,
                label: Text(t.srs_card_appearance_color_custom),
              ),
            ],
            onChanged: (SrsCardColorSource v) =>
                _set(a.copyWith(colorSource: v)),
          ),
          if (a.colorSource == SrsCardColorSource.custom)
            Padding(
              padding: EdgeInsets.all(tokens.spacing.card),
              child: Wrap(
                spacing: tokens.spacing.gap,
                runSpacing: tokens.spacing.gap,
                children: <Widget>[
                  for (final int argb in kSrsCardAccentSwatches)
                    _Swatch(
                      key: ValueKey<String>('srs-card-accent-$argb'),
                      color: Color(argb),
                      selected: a.customAccent == argb,
                      onTap: () => _set(a.copyWith(customAccent: argb)),
                    ),
                ],
              ),
            ),
          AdaptiveSettingsSwitchRow(
            key: const ValueKey<String>('srs-card-dict-unified'),
            title: t.srs_card_appearance_dict_unified,
            subtitle: t.srs_card_appearance_dict_unified_hint,
            value: a.dictUnified,
            onChanged: (bool v) => _set(a.copyWith(dictUnified: v)),
          ),
        ],
      ),
      AdaptiveSettingsSection(
        title: t.srs_card_appearance_section_layout,
        children: <Widget>[
          AdaptiveSettingsSegmentedRow<SrsCardDensity>(
            key: const ValueKey<String>('srs-card-density'),
            title: t.srs_card_appearance_density,
            selected: a.density,
            segments: <ButtonSegment<SrsCardDensity>>[
              ButtonSegment<SrsCardDensity>(
                value: SrsCardDensity.compact,
                label: Text(t.srs_card_appearance_density_compact),
              ),
              ButtonSegment<SrsCardDensity>(
                value: SrsCardDensity.standard,
                label: Text(t.srs_card_appearance_density_standard),
              ),
              ButtonSegment<SrsCardDensity>(
                value: SrsCardDensity.comfortable,
                label: Text(t.srs_card_appearance_density_comfortable),
              ),
            ],
            onChanged: (SrsCardDensity v) => _set(a.copyWith(density: v)),
          ),
        ],
      ),
      AdaptiveSettingsSection(
        title: t.srs_card_appearance_section_content,
        children: <Widget>[
          _switch(
            'show-picture',
            t.srs_card_appearance_show_picture,
            a.showPicture,
            (bool v) => a.copyWith(showPicture: v),
          ),
          _switch(
            'show-translation',
            t.srs_card_appearance_show_translation,
            a.showTranslation,
            (bool v) => a.copyWith(showTranslation: v),
          ),
          if (a.showTranslation)
            _switch(
              'blur-translation',
              t.srs_card_appearance_blur_translation,
              a.blurTranslation,
              (bool v) => a.copyWith(blurTranslation: v),
              // 模板卡面只认 Fushi 卡片模板的 `.fc-translation`（srs_card_translation_blur.dart）。
              subtitle: t.srs_card_appearance_blur_translation_desc,
            ),
          _switch(
            'show-frequency',
            t.srs_card_appearance_show_frequency,
            a.showFrequency,
            (bool v) => a.copyWith(showFrequency: v),
          ),
          _switch(
            'show-source',
            t.srs_card_appearance_show_source,
            a.showSource,
            (bool v) => a.copyWith(showSource: v),
          ),
          _switch(
            'glossary-expanded',
            t.srs_card_appearance_glossary_expanded,
            a.glossaryExpanded,
            (bool v) => a.copyWith(glossaryExpanded: v),
          ),
          _switch(
            'compact-phone',
            t.srs_card_appearance_compact_phone,
            a.compactPhone,
            (bool v) => a.copyWith(compactPhone: v),
          ),
          _switch(
            'front-reading',
            t.srs_card_appearance_front_reading,
            a.frontReading,
            (bool v) => a.copyWith(frontReading: v),
          ),
          _switch(
            'front-frequency',
            t.srs_card_appearance_front_frequency,
            a.frontFrequency,
            (bool v) => a.copyWith(frontFrequency: v),
          ),
        ],
      ),
    ];
    return FushiEntranceScope(
      child: ListView.separated(
        key: const ValueKey<String>('srs-card-appearance-controls'),
        padding: withBottomSafeInset(
          context,
          EdgeInsets.fromLTRB(
            tokens.spacing.page,
            0,
            tokens.spacing.page,
            tokens.spacing.section,
          ),
        ),
        itemCount: sections.length,
        separatorBuilder: (BuildContext context, int index) =>
            SizedBox(height: tokens.spacing.gap),
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int index) => sections[index],
        ),
      ),
    );
  }

  Widget _switch(
    String key,
    String title,
    bool value,
    SrsCardAppearance Function(bool v) change, {
    String? subtitle,
  }) => AdaptiveSettingsSwitchRow(
    key: ValueKey<String>('srs-card-$key'),
    title: title,
    subtitle: subtitle,
    value: value,
    onChanged: (bool v) => _set(change(v)),
  );
}

/// 自定义强调色的色块（选中时外圈描边 + 对勾）。
class _Swatch extends StatelessWidget {
  const _Swatch({
    super.key,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return FushiPressScale(
      child: Semantics(
        button: true,
        selected: selected,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: AnimatedContainer(
            duration: fushiMotionDuration(
              context,
              const Duration(milliseconds: 180),
            ),
            width: 48,
            height: 48,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? cs.onSurface : Colors.transparent,
                width: 2,
              ),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: selected
                  ? Icon(FushiIcons.check, color: Colors.white, size: 20)
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}
