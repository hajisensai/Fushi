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
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'package:file_picker/file_picker.dart' show FilePickerResult;
import 'package:fushi/src/media/import/real_path_directory_picker.dart'
    show pickFilesByExtensions;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/font_preview/font_file_metadata.dart'
    show readFontFamilyNameSync;
import 'package:fushi/src/pages/implementations/font_preview/system_font_browser_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/reader/font_download_service.dart';
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

/// 预览宽度档位对应的卡面宽度（逻辑像素）。
double srsCardPreviewWidth(SrsCardPreviewWidth w) =>
    w == SrsCardPreviewWidth.phone ? 390 : 1100;

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
  bool? _dark;
  SrsCardPreviewWidth? _width;
  SrsCardPreviewSource _source = SrsCardPreviewSource.sample;

  AnkiRenderedCard? _sample;
  String _css = FushiCardNoteType.template.css;
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

  String _fontLabel(SrsCardFontChoice? f) =>
      f == null ? t.srs_card_appearance_font_default : f.name;

  /// 字体库目录里的字体文件（导入过的都在这里）。
  List<SrsCardFontChoice> _libraryFonts() {
    final String? root = ref.read(srsCardFontRootProvider);
    if (root == null) return const <SrsCardFontChoice>[];
    final Directory dir = Directory(root);
    if (!dir.existsSync()) return const <SrsCardFontChoice>[];
    final List<SrsCardFontChoice> out = <SrsCardFontChoice>[];
    for (final FileSystemEntity e in dir.listSync()) {
      if (e is! File || !FontDownloadService.isFontFileName(e.path)) continue;
      final String name =
          readFontFamilyNameSync(e.path) ?? p.basenameWithoutExtension(e.path);
      out.add(SrsCardFontChoice(name: name, path: e.path));
    }
    out.sort(
      (SrsCardFontChoice a, SrsCardFontChoice b) => a.name.compareTo(b.name),
    );
    return out;
  }

  static const String _kDefault = '\u0000default';
  static const String _kSystem = '\u0000system';
  static const String _kImport = '\u0000import';

  Future<void> _pickFont(SrsCardFontSlot slot, String title) async {
    final SrsCardAppearance a = ref.read(srsCardAppearanceProvider);
    final SrsCardFontChoice? current = a.font(slot);
    final List<SrsCardFontChoice> library = _libraryFonts();
    String keyOf(SrsCardFontChoice f) => '${f.name}\u0000${f.path ?? ''}';
    final String? picked = await showFushiChoiceDialog<String>(
      context: context,
      title: title,
      icon: FushiIcons.font,
      selected: current == null ? _kDefault : keyOf(current),
      options: <FushiChoiceOption<String>>[
        FushiChoiceOption<String>(
          value: _kDefault,
          label: t.srs_card_appearance_font_default,
        ),
        if (current != null &&
            !library.any((SrsCardFontChoice f) => keyOf(f) == keyOf(current)))
          FushiChoiceOption<String>(value: keyOf(current), label: current.name),
        for (final SrsCardFontChoice f in library)
          FushiChoiceOption<String>(
            value: keyOf(f),
            label: f.name,
            subtitle: t.srs_card_appearance_font_library,
          ),
        FushiChoiceOption<String>(
          value: _kSystem,
          label: t.srs_card_appearance_font_system,
          icon: FushiIcons.font,
        ),
        FushiChoiceOption<String>(
          value: _kImport,
          label: t.srs_card_appearance_font_import,
          icon: FushiIcons.importFile,
        ),
      ],
    );
    if (picked == null || !mounted) return;
    SrsCardFontChoice? next;
    switch (picked) {
      case _kDefault:
        next = null;
      case _kSystem:
        final List<String>? names = await Navigator.of(context)
            .push<List<String>>(
              adaptivePageRoute<List<String>>(
                context: context,
                builder: (_) => const SystemFontBrowserPage(
                  alreadyAdded: <String>{},
                  target: FontTarget.body,
                ),
              ),
            );
        if (names == null || names.isEmpty) return;
        next = SrsCardFontChoice(name: names.first);
      case _kImport:
        next = await _importFont();
        if (next == null) return;
      default:
        next =
            library
                .where((SrsCardFontChoice f) => keyOf(f) == picked)
                .firstOrNull ??
            current;
    }
    _set(ref.read(srsCardAppearanceProvider).withFont(slot, next));
  }

  /// 导入字体文件：与字体库同一个落地目录与校验（扩展名白名单 + 文件头魔数）。
  Future<SrsCardFontChoice?> _importFont() async {
    final String? root = ref.read(srsCardFontRootProvider);
    if (root == null) return null;
    final FilePickerResult? result = await pickFilesByExtensions(
      context: context,
      allowedExtensions: <String>[
        for (final String e in kFontFileExtensions) e.substring(1),
      ],
    );
    final String? path = result?.files.singleOrNull?.path;
    if (path == null) return null;
    try {
      final File src = File(path);
      if (!await FontDownloadService.isValidFontFile(src)) {
        FushiToast.show(
          msg: t.srs_card_appearance_font_import_failed,
          severity: ToastSeverity.error,
        );
        return null;
      }
      final List<ImportedFontFile> files = await FontDownloadService(
        fontsDir: Directory(root)..createSync(recursive: true),
      ).importFile(src, fileName: p.basename(path));
      if (files.isEmpty) return null;
      return SrsCardFontChoice(name: files.first.name, path: files.first.path);
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsCardAppearance.importFont', e, stack);
      FushiToast.show(
        msg: t.srs_card_appearance_font_import_failed,
        severity: ToastSeverity.error,
      );
      return null;
    }
  }

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
                SizedBox(width: 400, child: _controls(context)),
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
        final double previewHeight = (c.maxHeight * 0.42).clamp(260.0, 460.0);
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
              child: SizedBox(
                height: previewHeight,
                child: _preview(context, width),
              ),
            ),
            Expanded(child: _controls(context)),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------- 预览

  Widget _preview(BuildContext context, SrsCardPreviewWidth width) {
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
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: tokens.spacing.gap,
      children: <Widget>[
        Wrap(
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
              onSelectionChanged: (Set<bool> s) =>
                  setState(() => _dark = s.first),
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
          ],
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(tokens.radii.group),
            child: ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints c) {
                  final double cardWidth = srsCardPreviewWidth(width);
                  final Widget card = Theme(
                    data: previewTheme,
                    child: ColoredBox(
                      color: srsCardColorScheme(
                        _appearance,
                        previewTheme.colorScheme,
                      ).surface,
                      child: faceBuilder(context, face),
                    ),
                  );
                  // 放得下就按真宽度居中；放不下（手机上看桌面版）整体等比缩小，
                  // 卡面里仍按 1100 的宽度排版（才看得到双栏）。
                  if (c.maxWidth >= cardWidth) {
                    return Center(
                      child: SizedBox(
                        key: const ValueKey<String>('srs-card-preview-frame'),
                        width: cardWidth,
                        height: c.maxHeight,
                        child: card,
                      ),
                    );
                  }
                  final double scale = c.maxWidth / cardWidth;
                  return FittedBox(
                    fit: BoxFit.contain,
                    alignment: Alignment.topCenter,
                    child: SizedBox(
                      key: const ValueKey<String>('srs-card-preview-frame'),
                      width: cardWidth,
                      height: c.maxHeight / scale,
                      child: card,
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

  // ---------------------------------------------------------------- 控件

  Widget _controls(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsCardAppearance a = _appearance;
    String pct(double v) => '${(v * 100).round()}%';
    final List<Widget> sections = <Widget>[
      AdaptiveSettingsSection(
        title: t.srs_card_appearance_section_fonts,
        children: <Widget>[
          for (final (SrsCardFontSlot slot, String label)
              in <(SrsCardFontSlot, String)>[
                (SrsCardFontSlot.ja, t.srs_card_appearance_font_ja),
                (SrsCardFontSlot.zh, t.srs_card_appearance_font_zh),
                (SrsCardFontSlot.latin, t.srs_card_appearance_font_latin),
              ])
            AdaptiveSettingsNavigationRow(
              key: ValueKey<String>('srs-card-font-${slot.name}'),
              title: label,
              subtitle: _fontLabel(a.font(slot)),
              icon: FushiIcons.font,
              onTap: () => srsRunLogged(
                'SrsCardAppearance.font',
                () => _pickFont(slot, label),
              ),
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
          _switch(
            'sentence-furigana',
            t.srs_card_appearance_sentence_furigana,
            a.sentenceFurigana,
            (bool v) => a.copyWith(sentenceFurigana: v),
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
    SrsCardAppearance Function(bool v) change,
  ) => AdaptiveSettingsSwitchRow(
    key: ValueKey<String>('srs-card-$key'),
    title: title,
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
