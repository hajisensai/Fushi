import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:fushi/models.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/models/theme_notifier.dart'
    show buildEinkColorScheme, kCustomThemeDefaultSeed;
import 'package:fushi/utils.dart';

/// 自定义主题编辑页里可改的颜色「角色」——按用户看得见的用途命名，不按 Material
/// 术语命名（seed/primary/tertiary 对用户没有意义）。每个角色在预览卡里都有一个
/// 对应的元素，选中该角色时预览会框出它影响的位置。
enum _ThemeRole {
  /// 主题色：钉死为 ColorScheme.primary（或按明暗自动调色调时作 seed）。
  accent,

  /// 界面底色：页面 / 卡片 / 菜单，其余中性层级由它推出（[deriveSurfaceRolesFrom]）。
  surface,

  /// 阅读器正文字色（含阅读器 chrome 图标/文字、词典弹窗 onSurface）。
  readerText,

  /// 阅读器页面背景（含阅读器 chrome 背景、词典弹窗底色）。
  readerBackground,

  /// 书内链接 + 选区拖拽手柄。
  link,

  /// 查词选区高亮。
  selection,

  /// 有声书当前句高亮（全局偏好，对所有主题生效）。
  audioHighlight,

  /// ColorScheme.secondary：标签/徽章/选中列表项。
  secondary,

  /// ColorScheme.tertiary：合集/统计点缀。
  tertiary,

  /// ColorScheme.primaryContainer：开关轨道/FAB/播放条。
  container,
}

/// 桌面宽屏阈值：≥ 此宽度时预览 + 选色器固定在右栏、设置列表在左栏，任何时候
/// 都不再把大面积选色板塞进滚动主路径（PC 上滚一下就误改颜色、页面长到看不见
/// 自己改了什么，是本页重设计前的头号抱怨）。
const double kCustomThemeWideLayoutMinWidth = 900;

class CustomThemePage extends BasePage {
  // TODO-930: edit an existing custom theme by id, or (null) draft a new one.
  // BUG-1841: a draft lives only in this page's state until the user taps
  // "apply" — opening the editor must never write to the theme list. The swatch
  // row's +new / edit-with-no-active entry points therefore pass null instead of
  // pre-persisting a blank entry.
  const CustomThemePage({super.key, this.themeId});

  final String? themeId;

  @override
  BasePageState createState() => _CustomThemePageState();
}

class _CustomThemePageState extends BasePageState<CustomThemePage> {
  /// 用户选的主题色。`_accentAutoTone` 关闭（默认）时它就是最终 primary，所见即
  /// 所得；开启时只作 seed，由 Material 按明暗各自派生色调。
  late Color _accent;
  bool _accentAutoTone = false;

  /// 主题色跟随系统取色（Android 壁纸 / 桌面 OS 强调色）。开启时 [_accent] 只是
  /// 系统不提供时的兜底，真正用的是 [_resolvedAccent]。
  bool _followSystemAccent = false;

  /// 派生色中性灰（标签 / 选中项 / 菜单不带主题色相）。
  bool _neutralDerived = false;

  /// 可选角色的显式覆盖；null = 跟随主题。`audioHighlight` 是全局偏好，
  /// 改动立即写穿 AppModel（TODO-977），其余随「应用」一起落进条目。
  final Map<_ThemeRole, Color?> _overrides = <_ThemeRole, Color?>{};

  /// 预览用的明暗：默认跟当前 app 明暗，可在预览卡上临时切换查看另一种模式。
  late Brightness _previewBrightness;

  /// 当前正在编辑/被框出的角色。宽屏下右栏选色器编辑它；窄屏下弹窗打开期间有效。
  _ThemeRole? _selectedRole;

  /// 本次 build 走的是否宽屏两栏（由 [LayoutBuilder] 的真实约束决定，是「点角色
  /// 行该切右栏还是弹窗」的唯一真相；不用 MediaQuery——它与实际给到本页的约束可能
  /// 不一致，例如被上层缩放/分栏包裹时）。
  bool _wideLayout = false;

  // TODO-930: the entry being edited. Resolved in initState from widget.themeId
  // (a fresh id when null). Name is optional.
  late String _entryId;
  late TextEditingController _nameController;

  // BUG-1841: true when [_entryId] is not in the persisted list yet (a draft
  // opened via +new / edit-with-no-active). Nothing exists to delete, and apply
  // is the only path that writes it.
  late bool _isDraft;

  @override
  void initState() {
    super.initState();
    // TODO-930 / BUG-1841: resolve which entry we are editing. A persisted
    // entry (by widget.themeId) seeds the editor from its stored colors; any
    // other case (null id, or an id that is not in the list) is a draft: a
    // fresh blank entry with the brand default seed and no role overrides that
    // exists only in this State until apply upserts it.
    final CustomThemeEntry? persisted = widget.themeId != null
        ? appModelNoUpdate.customThemeById(widget.themeId!)
        : null;
    _isDraft = persisted == null;
    final CustomThemeEntry entry = persisted ??
        CustomThemeEntry(
          id: widget.themeId ?? 'ct-${DateTime.now().microsecondsSinceEpoch}',
          name: '',
          seed: kCustomThemeDefaultSeed,
          // 新草稿的主题色就是品牌默认色本身（钉死），不走旧条目「取实际显示色」。
          primaryColor: kCustomThemeDefaultSeed,
        );
    _entryId = entry.id;
    _nameController = TextEditingController(text: entry.name);
    _previewBrightness =
        appModelNoUpdate.isDarkMode ? Brightness.dark : Brightness.light;
    _loadEntry(entry, audioHighlight: appModelNoUpdate.audioHighlightColor);
  }

  /// 把一条条目装进编辑状态。已钉主色的条目主题色 = 钉的那个（自动调色调关）；
  /// 只有 seed 的条目（旧数据 / 分享码）主题色 = seed 且自动调色调开——正好还原
  /// 它原来的观感。
  void _loadEntry(CustomThemeEntry entry, {required Color? audioHighlight}) {
    Color? roleColor(int? fromEntry) =>
        fromEntry != null ? Color(fromEntry) : null;
    _accent = Color(entry.primaryColor ?? entry.seed);
    _accentAutoTone = entry.primaryColor == null;
    _followSystemAccent = entry.followSystemAccent;
    _neutralDerived = entry.neutralDerived;
    _overrides
      ..[_ThemeRole.surface] = roleColor(entry.surfaceColor)
      ..[_ThemeRole.readerText] = roleColor(entry.fontColor)
      ..[_ThemeRole.readerBackground] = roleColor(entry.bgColor)
      ..[_ThemeRole.link] = roleColor(entry.linkColor)
      ..[_ThemeRole.selection] = roleColor(entry.selectionColor)
      ..[_ThemeRole.secondary] = roleColor(entry.secondaryColor)
      ..[_ThemeRole.tertiary] = roleColor(entry.tertiaryColor)
      ..[_ThemeRole.container] = roleColor(entry.containerColor)
      // TODO-977：音频高亮是全局偏好（与主题解耦），从 AppModel 读；条目/分享码
      // 里的 sentenceAudioHighlightColor 只作分享兼容。
      ..[_ThemeRole.audioHighlight] = audioHighlight;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  // ── 派生：ColorScheme / 阅读器色 / 各角色实际显示色 ──

  /// 系统是否提供取色（Android 壁纸 / 桌面强调色）。
  Color? get _systemAccent => appModelNoUpdate.systemPrimaryColor;

  /// 实际参与派生的主题色：跟随系统时是系统色（系统没有则回落所选色）。
  Color get _resolvedAccent =>
      _followSystemAccent ? (_systemAccent ?? _accent) : _accent;

  ColorScheme _schemeFor(Brightness brightness) {
    // 墨水屏模式下真机整套 ColorScheme 会被黑白顶掉，预览必须同样如此，
    // 否则编辑页彩色、书里黑白。
    if (appModelNoUpdate.einkMode) return buildEinkColorScheme(brightness);
    return buildFushiColorScheme(
      seedColor: _resolvedAccent,
      brightness: brightness,
      primary: _accentAutoTone ? null : _resolvedAccent,
      secondary: _overrides[_ThemeRole.secondary],
      tertiary: _overrides[_ThemeRole.tertiary],
      primaryContainer: _overrides[_ThemeRole.container],
      surface: _overrides[_ThemeRole.surface],
      neutralDerived: _neutralDerived,
    );
  }

  ColorScheme get _scheme => _schemeFor(_previewBrightness);

  /// 阅读器五角色色：与真机同一条解析链（[resolveReaderThemeColors]），
  /// 保证编辑页看到的正文/背景/选区/链接/当前句就是书里渲染的。
  ReaderThemeColors _readerColorsFor(ColorScheme scheme) {
    return resolveReaderThemeColors(
      themeKey: 'custom-theme:$_entryId',
      presetMap: const <String, ReaderThemeColors>{},
      scheme: scheme,
      customOverrides: (
        bg: _overrides[_ThemeRole.readerBackground],
        fg: _overrides[_ThemeRole.readerText],
        selection: _overrides[_ThemeRole.selection],
        link: _overrides[_ThemeRole.link],
      ),
      audioHighlightOverride: _overrides[_ThemeRole.audioHighlight],
    );
  }

  /// 某角色在当前预览明暗下**实际显示**的颜色（覆盖值或跟随主题的派生值）。
  Color _effectiveColor(_ThemeRole role) {
    final ColorScheme cs = _scheme;
    final ReaderThemeColors reader = _readerColorsFor(cs);
    switch (role) {
      case _ThemeRole.accent:
        return cs.primary;
      case _ThemeRole.surface:
        return cs.surface;
      case _ThemeRole.readerText:
        return reader.fg;
      case _ThemeRole.readerBackground:
        return reader.bg;
      case _ThemeRole.link:
        return reader.link;
      case _ThemeRole.selection:
        return reader.selection;
      case _ThemeRole.audioHighlight:
        return reader.sentenceAudioHighlight;
      case _ThemeRole.secondary:
        return cs.secondary;
      case _ThemeRole.tertiary:
        return cs.tertiary;
      case _ThemeRole.container:
        return cs.primaryContainer;
    }
  }

  /// 主题色在 [brightness] 下是否难以辨认（相对该模式的页面底色对比度 < 3:1，
  /// WCAG 对大号 UI 元素的下限）。
  bool _accentLowContrast(Brightness brightness) {
    final ColorScheme cs = _schemeFor(brightness);
    return _contrastRatio(cs.primary, cs.surface) < 3.0;
  }

  static double _contrastRatio(Color a, Color b) {
    final double la = a.computeLuminance() + 0.05;
    final double lb = b.computeLuminance() + 0.05;
    return la > lb ? la / lb : lb / la;
  }

  // ── 角色元数据 ──

  String _roleTitle(_ThemeRole role) {
    switch (role) {
      case _ThemeRole.accent:
        return t.theme_role_accent;
      case _ThemeRole.surface:
        return t.theme_role_surface;
      case _ThemeRole.readerText:
        return t.theme_role_reader_text;
      case _ThemeRole.readerBackground:
        return t.theme_role_reader_background;
      case _ThemeRole.link:
        return t.theme_role_link;
      case _ThemeRole.selection:
        return t.theme_role_selection;
      case _ThemeRole.audioHighlight:
        return t.theme_role_audio_highlight;
      case _ThemeRole.secondary:
        return t.theme_role_secondary;
      case _ThemeRole.tertiary:
        return t.theme_role_tertiary;
      case _ThemeRole.container:
        return t.theme_role_container;
    }
  }

  String _roleDescription(_ThemeRole role) {
    switch (role) {
      case _ThemeRole.accent:
        return t.theme_role_accent_desc;
      case _ThemeRole.surface:
        return t.theme_role_surface_desc;
      case _ThemeRole.readerText:
        return t.theme_role_reader_text_desc;
      case _ThemeRole.readerBackground:
        return t.theme_role_reader_background_desc;
      case _ThemeRole.link:
        return t.theme_role_link_desc;
      case _ThemeRole.selection:
        return t.theme_role_selection_desc;
      case _ThemeRole.audioHighlight:
        return t.theme_role_audio_highlight_desc;
      case _ThemeRole.secondary:
        return t.theme_role_secondary_desc;
      case _ThemeRole.tertiary:
        return t.theme_role_tertiary_desc;
      case _ThemeRole.container:
        return t.theme_role_container_desc;
    }
  }

  IconData _roleIcon(_ThemeRole role) {
    switch (role) {
      case _ThemeRole.accent:
        return Icons.palette_outlined;
      case _ThemeRole.surface:
        return Icons.web_asset_outlined;
      case _ThemeRole.readerText:
        return Icons.text_fields;
      case _ThemeRole.readerBackground:
        return Icons.crop_portrait_outlined;
      case _ThemeRole.link:
        return Icons.link;
      case _ThemeRole.selection:
        return Icons.highlight_alt_outlined;
      case _ThemeRole.audioHighlight:
        return Icons.graphic_eq;
      case _ThemeRole.secondary:
        return Icons.label_outline;
      case _ThemeRole.tertiary:
        return Icons.auto_awesome_outlined;
      case _ThemeRole.container:
        return Icons.toggle_on_outlined;
    }
  }

  /// 允许透明度的角色：叠在正文上的高亮类。字色也允许（旧数据里有带 alpha 的）。
  bool _roleAllowsAlpha(_ThemeRole role) {
    switch (role) {
      case _ThemeRole.readerText:
      case _ThemeRole.selection:
      case _ThemeRole.audioHighlight:
        return true;
      case _ThemeRole.accent:
      case _ThemeRole.surface:
      case _ThemeRole.readerBackground:
      case _ThemeRole.link:
      case _ThemeRole.secondary:
      case _ThemeRole.tertiary:
      case _ThemeRole.container:
        return false;
    }
  }

  /// 界面背景 / 页面背景的常用预设：纯白、纯黑、暖纸、冷灰、深灰。
  static const List<Color> _surfacePresets = <Color>[
    Color(0xFFFFFFFF),
    Color(0xFF000000),
    Color(0xFFFAF6EF),
    Color(0xFFF3F3F3),
    Color(0xFF202020),
  ];

  static const List<Color> _accentPresets = <Color>[
    Color(kCustomThemeDefaultSeed),
    Color(0xFF0B57D0),
    Color(0xFF6750A4),
    Color(0xFF006E1C),
    Color(0xFF9A4700),
    Color(0xFFB3261E),
    Color(0xFF8E24AA),
    Color(0xFF00897B),
  ];

  // ── 状态变更 ──

  void _setRoleColor(_ThemeRole role, Color color) {
    setState(() {
      if (role == _ThemeRole.accent) {
        _accent = color;
      } else {
        _overrides[role] = color;
      }
    });
    if (role == _ThemeRole.audioHighlight) {
      appModel.setAudioHighlightColor(color);
    }
  }

  void _resetRole(_ThemeRole role) {
    setState(() => _overrides[role] = null);
    if (role == _ThemeRole.audioHighlight) {
      appModel.setAudioHighlightColor(null);
    }
  }

  /// TODO-930: build the [CustomThemeEntry] from the current editor state.
  CustomThemeEntry _buildEntry() {
    int? argb(Color? c) => c?.toARGB32();
    return CustomThemeEntry(
      id: _entryId,
      name: _nameController.text.trim(),
      // seed 与钉死的主色同值：派生色（次要强调/点缀/底色）都从主题色出发，
      // 用户只需要理解一个「主题色」。
      seed: _accent.toARGB32(),
      primaryColor: _accentAutoTone ? null : _accent.toARGB32(),
      surfaceColor: argb(_overrides[_ThemeRole.surface]),
      followSystemAccent: _followSystemAccent,
      neutralDerived: _neutralDerived,
      fontColor: argb(_overrides[_ThemeRole.readerText]),
      bgColor: argb(_overrides[_ThemeRole.readerBackground]),
      selectionColor: argb(_overrides[_ThemeRole.selection]),
      linkColor: argb(_overrides[_ThemeRole.link]),
      secondaryColor: argb(_overrides[_ThemeRole.secondary]),
      tertiaryColor: argb(_overrides[_ThemeRole.tertiary]),
      containerColor: argb(_overrides[_ThemeRole.container]),
      sentenceAudioHighlightColor: argb(_overrides[_ThemeRole.audioHighlight]),
    );
  }

  /// TODO-930: 1-based index of this entry in the list, for the default name
  /// hint (`Custom N`). Falls back to list length + 1 for a not-yet-persisted
  /// new entry.
  int get _defaultNameIndex {
    final int idx = appModelNoUpdate.customThemes.indexWhere(
      (CustomThemeEntry e) => e.id == _entryId,
    );
    return idx >= 0 ? idx + 1 : appModelNoUpdate.customThemes.length + 1;
  }

  // ── 分享码（wire 格式不变：hibiki-theme:<seed>:<brightness>[:xx<argb>...]）──

  String _encodeTheme() {
    String hex(int argb) => argb.toRadixString(16).padLeft(8, '0');
    final CustomThemeEntry entry = _buildEntry();
    final String mode = appModelNoUpdate.brightnessMode;
    var code = 'hibiki-theme:${hex(entry.seed)}:$mode';
    void segment(String tag, int? argb) {
      if (argb != null) code += ':$tag${hex(argb)}';
    }

    segment('fc', entry.fontColor);
    segment('bg', entry.bgColor);
    segment('sc', entry.selectionColor);
    segment('pr', entry.primaryColor);
    segment('sr', entry.secondaryColor);
    segment('tr', entry.tertiaryColor);
    segment('cr', entry.containerColor);
    segment('sk', entry.sentenceAudioHighlightColor);
    segment('lk', entry.linkColor);
    segment('sf', entry.surfaceColor);
    if (entry.followSystemAccent) code += ':sa1';
    if (entry.neutralDerived) code += ':nd1';
    return code;
  }

  /// 解析分享码成条目（id/name 用当前编辑中的）。格式不合法返回 null。
  CustomThemeEntry? _decodeTheme(String code) {
    final List<String> parts = code.trim().split(':');
    if (parts.length < 3 || parts[0] != 'hibiki-theme') return null;
    final int? seed = int.tryParse(parts[1], radix: 16);
    if (seed == null) return null;
    if (!const <String>{'dark', 'light', 'system'}.contains(parts[2])) {
      return null;
    }
    final Map<String, int> segments = <String, int>{};
    for (int i = 3; i < parts.length; i++) {
      if (parts[i].length < 3) continue;
      final int? v = int.tryParse(parts[i].substring(2), radix: 16);
      if (v != null) segments[parts[i].substring(0, 2)] = v;
    }
    return CustomThemeEntry(
      id: _entryId,
      name: _nameController.text.trim(),
      seed: seed,
      fontColor: segments['fc'],
      bgColor: segments['bg'],
      selectionColor: segments['sc'],
      primaryColor: segments['pr'],
      secondaryColor: segments['sr'],
      tertiaryColor: segments['tr'],
      containerColor: segments['cr'],
      sentenceAudioHighlightColor: segments['sk'],
      linkColor: segments['lk'],
      surfaceColor: segments['sf'],
      followSystemAccent: segments['sa'] == 1,
      neutralDerived: segments['nd'] == 1,
    );
  }

  void _shareTheme() {
    final code = _encodeTheme();
    Clipboard.setData(ClipboardData(text: code));
    FushiToast.show(msg: t.theme_code_copied, severity: ToastSeverity.success);
  }

  void _applyImportedTheme(CustomThemeEntry imported) {
    final Color? audio = imported.sentenceAudioHighlightColor != null
        ? Color(imported.sentenceAudioHighlightColor!)
        : null;
    setState(() => _loadEntry(imported, audioHighlight: audio));
    // TODO-977：导入的音频高亮色也写穿全局偏好（与主题解耦），保持与手动改色一致。
    appModel.setAudioHighlightColor(audio);
  }

  Future<void> _importTheme() async {
    final controller = TextEditingController();
    try {
      await showAppDialog(
        context: context,
        builder: (ctx) {
          final FushiDesignTokens tokens = FushiDesignTokens.of(ctx);
          return FushiDialogFrame(
            maxWidth: 480,
            maxHeightFactor: 0.78,
            scrollable: false,
            child: FushiModalSheetFrame(
              title: t.import_theme,
              leadingIcon: Icons.content_paste_outlined,
              bodyPadding: EdgeInsets.fromLTRB(
                tokens.spacing.card,
                0,
                tokens.spacing.card,
                tokens.spacing.gap,
              ),
              footerPadding: EdgeInsets.fromLTRB(
                tokens.spacing.card,
                tokens.spacing.gap,
                tokens.spacing.card,
                tokens.spacing.card,
              ),
              body: FushiTextField(
                controller: controller,
                hintText: t.import_theme_hint,
                autofocus: true,
              ),
              footer: Wrap(
                alignment: WrapAlignment.end,
                spacing: tokens.spacing.gap,
                runSpacing: tokens.spacing.gap,
                children: [
                  adaptiveDialogAction(
                    context: ctx,
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(t.dialog_close),
                  ),
                  adaptiveDialogAction(
                    context: ctx,
                    isDefaultAction: true,
                    onPressed: () {
                      final CustomThemeEntry? result = _decodeTheme(
                        controller.text,
                      );
                      if (result == null) {
                        FushiToast.show(
                          msg: t.import_theme_invalid,
                          severity: ToastSeverity.error,
                        );
                        return;
                      }
                      Navigator.pop(ctx);
                      _applyImportedTheme(result);
                      FushiToast.show(
                        msg: t.import_theme_success,
                        severity: ToastSeverity.success,
                      );
                    },
                    child: Text(t.dialog_import),
                  ),
                ],
              ),
            ),
          );
        },
      );
    } finally {
      controller.dispose();
    }
  }

  // ── 页面骨架 ──

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final EdgeInsets mediaPadding = MediaQuery.of(context).padding;
    final double bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final EdgeInsets listPadding = EdgeInsets.fromLTRB(
      tokens.spacing.page,
      tokens.spacing.gap + tokens.spacing.gap / 2,
      tokens.spacing.page,
      tokens.spacing.gap +
          tokens.spacing.gap / 2 +
          mediaPadding.bottom +
          bottomInset,
    );
    final List<Widget> actions = <Widget>[
      FushiIconButton(
        icon: Icons.content_paste_outlined,
        tooltip: t.import_theme,
        onTap: _importTheme,
      ),
      FushiIconButton(
        icon: Icons.share_outlined,
        tooltip: t.share_theme,
        onTap: _shareTheme,
      ),
    ];

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide =
            constraints.maxWidth >= kCustomThemeWideLayoutMinWidth &&
                !isCupertinoPlatform(context);
        _wideLayout = wide;
        if (!wide) {
          return AdaptiveSettingsScaffold(
            title: Text(t.custom_theme),
            padding: listPadding,
            actions: actions,
            children: <Widget>[
              _buildPreviewCard(),
              SizedBox(height: tokens.spacing.card),
              ..._buildSettingsColumn(),
            ],
          );
        }
        // 宽屏：左栏设置列表 / 右栏固定的预览 + 当前角色的选色器。选色器从此不在
        // 滚动主路径上，鼠标滚轮只滚列表。
        return FushiToolScaffold.customTitle(
          title: Text(t.custom_theme),
          actions: actions,
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: ListView(
                  padding: listPadding,
                  children: _buildSettingsColumn(),
                ),
              ),
              SizedBox(
                width: 400,
                child: SingleChildScrollView(
                  padding: listPadding.copyWith(left: 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _buildPreviewCard(),
                      SizedBox(height: tokens.spacing.card),
                      _buildSidePickerCard(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _buildSettingsColumn() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return <Widget>[
      // ── 主题色 ──
      AdaptiveSettingsSection(
        title: t.theme_section_accent,
        children: <Widget>[
          // TODO-930: 主题名称（可选，留空显示「自定义 N」默认名）。
          _buildNameField(),
          _buildAccentRow(),
          AdaptiveSettingsSwitchRow(
            title: t.theme_accent_follow_system,
            subtitle: _systemAccent == null
                ? t.theme_accent_follow_system_unavailable
                : t.theme_accent_follow_system_desc,
            value: _followSystemAccent && _systemAccent != null,
            onChanged: _systemAccent == null
                ? null
                : (bool value) => setState(() => _followSystemAccent = value),
          ),
          AdaptiveSettingsSwitchRow(
            title: t.theme_accent_auto_tone,
            subtitle: t.theme_accent_auto_tone_desc,
            value: _accentAutoTone,
            onChanged: (bool value) => setState(() => _accentAutoTone = value),
          ),
          _buildRoleRow(_ThemeRole.surface),
          AdaptiveSettingsSwitchRow(
            title: t.theme_neutral_derived,
            subtitle: t.theme_neutral_derived_desc,
            value: _neutralDerived,
            onChanged: (bool value) => setState(() => _neutralDerived = value),
          ),
          if (_accentLowContrast(Brightness.light))
            _buildHintRow(t.theme_accent_low_contrast_light),
          if (_accentLowContrast(Brightness.dark))
            _buildHintRow(t.theme_accent_low_contrast_dark),
        ],
      ),
      // ── 阅读器 ──
      AdaptiveSettingsSection(
        title: t.theme_section_reader,
        children: <Widget>[
          _buildRoleRow(_ThemeRole.readerText),
          _buildRoleRow(_ThemeRole.readerBackground),
          _buildRoleRow(_ThemeRole.link),
          _buildRoleRow(_ThemeRole.selection),
        ],
      ),
      // ── 有声书 ──
      AdaptiveSettingsSection(
        title: t.theme_section_audiobook,
        children: <Widget>[_buildRoleRow(_ThemeRole.audioHighlight)],
      ),
      // TODO-072：视频字幕颜色不在此页配置，只放一行说明。
      _buildNoteRow(t.video_subtitle_color_note),
      // ── 微调派生色（默认折叠：多数用户只需要主题色）──
      AdaptiveSettingsSection(
        title: t.theme_section_fine_tune,
        titlePlacement: SettingsSectionTitlePlacement.inside,
        collapsible: true,
        initiallyExpanded: _overrides[_ThemeRole.secondary] != null ||
            _overrides[_ThemeRole.tertiary] != null ||
            _overrides[_ThemeRole.container] != null,
        children: <Widget>[
          _buildRoleRow(_ThemeRole.secondary),
          _buildRoleRow(_ThemeRole.tertiary),
          _buildRoleRow(_ThemeRole.container),
        ],
      ),
      SizedBox(height: tokens.spacing.card),
      FilledButton.icon(
        onPressed: _applyAndClose,
        icon: const Icon(Icons.check),
        label: Text(t.apply_theme),
      ),
      // TODO-930 M2: 删除当前编辑的主题（确认后），回退由 deleteCustomTheme +
      // _resolveThemeKeyAfterDelete 处理（决策 1：列表非空选第一项，空→system）。
      // BUG-1841：草稿还没进列表、没有东西可删，也不该借删除去改全局主题键——
      // 直接不渲染删除按钮，返回即丢弃草稿。
      if (!_isDraft) ...<Widget>[
        SizedBox(height: tokens.spacing.gap),
        OutlinedButton.icon(
          onPressed: _confirmDelete,
          style: OutlinedButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          icon: const Icon(Icons.delete_outline),
          label: Text(t.delete_custom_theme),
        ),
      ],
    ];
  }

  /// TODO-930 M2: persist the edited theme into the list, select it, point the
  /// app theme key at it, then close. Replaces the legacy applyCustomTheme call
  /// so naming + multi-theme selection round-trip through the list model.
  Future<void> _applyAndClose() async {
    final NavigatorState navigator = Navigator.of(context);
    final CustomThemeEntry entry = _buildEntry();
    await appModel.upsertCustomTheme(entry);
    await appModel.selectCustomTheme(entry.id);
    await appModel.setAppThemeKey('custom-theme:${entry.id}');
    if (!mounted) return;
    navigator.pop();
  }

  /// TODO-930 M2: confirm + delete the current theme. After delete, repoint the
  /// app theme key per decision 1 (first remaining custom theme, else
  /// system-theme) so the app never points at a now-missing custom entry.
  Future<void> _confirmDelete() async {
    final NavigatorState navigator = Navigator.of(context);
    final bool confirmed = await showAppDialog<bool>(
          context: context,
          builder: (BuildContext ctx) {
            final FushiDesignTokens tokens = FushiDesignTokens.of(ctx);
            return FushiDialogFrame(
              maxWidth: 420,
              maxHeightFactor: 0.6,
              scrollable: false,
              child: FushiModalSheetFrame(
                title: t.delete_custom_theme,
                leadingIcon: Icons.delete_outline,
                bodyPadding: EdgeInsets.fromLTRB(
                  tokens.spacing.card,
                  0,
                  tokens.spacing.card,
                  tokens.spacing.gap,
                ),
                footerPadding: EdgeInsets.fromLTRB(
                  tokens.spacing.card,
                  tokens.spacing.gap,
                  tokens.spacing.card,
                  tokens.spacing.card,
                ),
                body: Text(
                  t.delete_custom_theme_confirm,
                  style: tokens.type.listSubtitle,
                ),
                footer: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: tokens.spacing.gap,
                  runSpacing: tokens.spacing.gap,
                  children: [
                    adaptiveDialogAction(
                      context: ctx,
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(t.dialog_close),
                    ),
                    adaptiveDialogAction(
                      context: ctx,
                      isDestructiveAction: true,
                      isDefaultAction: true,
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(t.delete_custom_theme),
                    ),
                  ],
                ),
              ),
            );
          },
        ) ??
        false;
    if (!confirmed) return;

    final String nextKey = _resolveThemeKeyAfterDelete(_entryId);
    await appModel.deleteCustomTheme(_entryId);
    await appModel.setAppThemeKey(nextKey);
    if (!mounted) return;
    navigator.pop();
  }

  /// TODO-930 M2 decision 1: after deleting [deletedId], the app theme key
  /// should point at the first remaining custom theme (`custom-theme:<id>`), or
  /// fall back to `system-theme` when the list becomes empty. Pure for testing.
  String _resolveThemeKeyAfterDelete(String deletedId) {
    final List<CustomThemeEntry> remaining = appModelNoUpdate.customThemes
        .where((CustomThemeEntry e) => e.id != deletedId)
        .toList();
    if (remaining.isEmpty) return 'system-theme';
    return 'custom-theme:${remaining.first.id}';
  }

  /// TODO-930 M2: the optional name field. Empty name is allowed (decision 3);
  /// the hint shows the localized default `Custom N`.
  Widget _buildNameField() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.gap,
      ),
      child: FushiTextField(
        controller: _nameController,
        labelText: t.custom_theme_name,
        hintText: t.custom_theme_default_name(n: _defaultNameIndex),
        onChanged: (_) => setState(() {}),
      ),
    );
  }

  // ── 角色行 ──

  /// 点角色行：宽屏切右栏选色器；窄屏弹选色窗，关窗后取消框选。
  Future<void> _openRole(_ThemeRole role) async {
    setState(() => _selectedRole = role);
    if (_wideLayout) return;
    await _showRolePickerDialog(role);
    if (mounted) setState(() => _selectedRole = null);
  }

  Widget _buildAccentRow() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme appCs = Theme.of(context).colorScheme;
    final Color picked = _resolvedAccent;
    final Color shown = _effectiveColor(_ThemeRole.accent);
    final bool differs = shown.toARGB32() != picked.toARGB32();
    final bool locked = _followSystemAccent && _systemAccent != null;
    return _highlightIfSelected(
      _ThemeRole.accent,
      AdaptiveSettingsRow(
        title: t.theme_role_accent,
        subtitle:
            locked ? t.theme_accent_follow_system : t.theme_role_accent_desc,
        icon: _roleIcon(_ThemeRole.accent),
        showIcon: true,
        // 跟随系统取色时主题色不可手选。
        onTap: locked ? null : () => _openRole(_ThemeRole.accent),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _swatchDot(picked),
            // 开了自动调色调且派生结果 ≠ 所选：把「实际显示」直接摆在旁边，
            // 用户不用猜为什么按钮不是自己选的那个颜色。
            if (differs) ...<Widget>[
              SizedBox(width: tokens.spacing.gap / 2),
              Icon(
                Icons.arrow_forward,
                size: 14,
                color: appCs.onSurfaceVariant,
              ),
              SizedBox(width: tokens.spacing.gap / 2),
              Tooltip(
                message: t.theme_role_actual_color,
                child: _swatchDot(shown),
              ),
            ],
            SizedBox(width: tokens.spacing.gap),
            Icon(
              locked ? Icons.lock_outline : Icons.chevron_right,
              color: appCs.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRoleRow(_ThemeRole role) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color? override = _overrides[role];
    return _highlightIfSelected(
      role,
      AdaptiveSettingsRow(
        title: _roleTitle(role),
        subtitle: _roleDescription(role),
        icon: _roleIcon(role),
        showIcon: true,
        onTap: () => _openRole(role),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (override == null) ...<Widget>[
              Text(
                t.theme_role_follows_theme,
                style: tokens.type.metadata.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              SizedBox(width: tokens.spacing.gap),
            ],
            _swatchDot(_effectiveColor(role)),
            SizedBox(width: tokens.spacing.gap / 2),
            if (override != null)
              FushiIconButton(
                icon: Icons.restart_alt,
                tooltip: t.theme_role_reset,
                size: 20,
                onTap: () => _resetRole(role),
              )
            else
              Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Widget _highlightIfSelected(_ThemeRole role, Widget row) {
    final bool selected = _selectedRole == role;
    return ColoredBox(
      color: selected
          ? FushiDesignTokens.of(context).surfaces.selected
          : Colors.transparent,
      child: row,
    );
  }

  Widget _swatchDot(Color color) {
    return FushiColorSwatch(
      color: color,
      size: 24,
      shape: FushiColorSwatchShape.dot,
      borderColor: Theme.of(context).dividerColor,
    );
  }

  // ── 选色器（宽屏右栏 / 窄屏弹窗共用同一个 widget）──

  Widget _buildPickerFor(_ThemeRole role) {
    final bool optional = role != _ThemeRole.accent;
    final Color current = role == _ThemeRole.accent
        ? _accent
        : (_overrides[role] ?? _effectiveColor(role));
    return _ThemeColorPicker(
      key: ValueKey<_ThemeRole>(role),
      color: current,
      enableAlpha: _roleAllowsAlpha(role),
      presets: switch (role) {
        _ThemeRole.accent => _accentPresets,
        _ThemeRole.surface || _ThemeRole.readerBackground => _surfacePresets,
        _ => const <Color>[],
      },
      onChanged: (Color c) => _setRoleColor(role, c),
      onReset:
          optional && _overrides[role] != null ? () => _resetRole(role) : null,
      resetLabel: t.theme_role_reset,
    );
  }

  Widget _buildSidePickerCard() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final _ThemeRole role = _selectedRole ?? _ThemeRole.accent;
    return FushiCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(_roleIcon(role), color: cs.onSurfaceVariant),
              SizedBox(width: tokens.spacing.gap),
              Expanded(
                child: Text(_roleTitle(role), style: tokens.type.listTitle),
              ),
            ],
          ),
          SizedBox(height: tokens.spacing.gap / 2),
          Text(
            _roleDescription(role),
            style: tokens.type.metadata.copyWith(color: cs.onSurfaceVariant),
          ),
          SizedBox(height: tokens.spacing.gap + tokens.spacing.gap / 2),
          if (role == _ThemeRole.accent &&
              _followSystemAccent &&
              _systemAccent != null)
            Row(
              children: <Widget>[
                Icon(Icons.lock_outline, size: 18, color: cs.onSurfaceVariant),
                SizedBox(width: tokens.spacing.gap),
                Expanded(
                  child: Text(
                    t.theme_accent_follow_system_desc,
                    style: tokens.type.listSubtitle,
                  ),
                ),
              ],
            )
          else
            _buildPickerFor(role),
        ],
      ),
    );
  }

  Future<void> _showRolePickerDialog(_ThemeRole role) {
    return showAppDialog<void>(
      context: context,
      builder: (BuildContext ctx) {
        final FushiDesignTokens tokens = FushiDesignTokens.of(ctx);
        return FushiDialogFrame(
          maxWidth: 400,
          maxHeightFactor: 0.9,
          child: FushiModalSheetFrame(
            title: _roleTitle(role),
            subtitle: _roleDescription(role),
            leadingIcon: _roleIcon(role),
            bodyPadding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              0,
              tokens.spacing.card,
              tokens.spacing.gap,
            ),
            footerPadding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              tokens.spacing.gap,
              tokens.spacing.card,
              tokens.spacing.card,
            ),
            // 弹窗自己持 HSV 状态；页面 setState 只重绘弹窗下面的预览卡。
            body: _buildPickerFor(role),
            footer: Wrap(
              alignment: WrapAlignment.end,
              spacing: tokens.spacing.gap,
              children: <Widget>[
                adaptiveDialogAction(
                  context: ctx,
                  isDefaultAction: true,
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(t.dialog_done),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── 预览卡：一张缩小的「真 app」——每个元素的颜色都取自真实 ColorScheme /
  //    真实阅读器解析链，选中某个角色时框出它影响的元素。──

  Widget _buildPreviewCard() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = _scheme;
    final ReaderThemeColors reader = _readerColorsFor(cs);
    final ColorScheme appCs = Theme.of(context).colorScheme;
    final TextStyle titleStyle = tokens.type.listTitle.copyWith(
      color: cs.onSurface,
      fontWeight: FontWeight.bold,
    );

    return FushiCard(
      color: cs.surface,
      borderColor: cs.outlineVariant,
      padding: EdgeInsets.all(tokens.spacing.card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text(t.preview, style: titleStyle)),
              SegmentedButton<Brightness>(
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                segments: <ButtonSegment<Brightness>>[
                  ButtonSegment<Brightness>(
                    value: Brightness.light,
                    icon: const Icon(Icons.light_mode_outlined, size: 16),
                    label: Text(t.theme_preview_light),
                  ),
                  ButtonSegment<Brightness>(
                    value: Brightness.dark,
                    icon: const Icon(Icons.dark_mode_outlined, size: 16),
                    label: Text(t.theme_preview_dark),
                  ),
                ],
                selected: <Brightness>{_previewBrightness},
                onSelectionChanged: (Set<Brightness> s) =>
                    setState(() => _previewBrightness = s.first),
              ),
            ],
          ),
          SizedBox(height: tokens.spacing.gap + tokens.spacing.gap / 2),
          // 界面控件行：按钮 / 开关 / 标签 / 点缀进度
          Wrap(
            spacing: tokens.spacing.gap + tokens.spacing.gap / 2,
            runSpacing: tokens.spacing.gap,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              _spot(
                _ThemeRole.accent,
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: tokens.spacing.gap * 2,
                    vertical: tokens.spacing.gap * 0.75,
                  ),
                  decoration: BoxDecoration(
                    color: cs.primary,
                    // 预览里的「按钮」要长得跟 app 真按钮一样，所以走共享控件
                    // 同一枚半径 token（FushiButton 用的也是 controlRadius）。
                    // 写死 20 会让预览展示一个 app 里并不存在的形状。
                    borderRadius: tokens.radii.controlRadius,
                  ),
                  child: Text(
                    t.theme_preview_button,
                    style: tokens.type.controlLabel.copyWith(
                      color: cs.onPrimary,
                    ),
                  ),
                ),
              ),
              _spot(
                _ThemeRole.accent,
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.favorite, color: cs.primary, size: 20),
                    SizedBox(width: tokens.spacing.gap / 2),
                    Icon(Icons.bookmark, color: cs.primary, size: 20),
                  ],
                ),
              ),
              _spot(
                _ThemeRole.container,
                FushiPreviewSwitch(
                  trackColor: cs.primaryContainer,
                  thumbColor: cs.primary,
                ),
              ),
              _spot(
                _ThemeRole.secondary,
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: tokens.spacing.gap,
                    vertical: tokens.spacing.gap * 0.375,
                  ),
                  decoration: BoxDecoration(
                    color: cs.secondaryContainer,
                    borderRadius: tokens.radii.controlRadius,
                  ),
                  child: Text(
                    t.theme_preview_tag,
                    style: tokens.type.metadata.copyWith(
                      color: cs.onSecondaryContainer,
                    ),
                  ),
                ),
              ),
              _spot(
                _ThemeRole.surface,
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: tokens.spacing.gap,
                    vertical: tokens.spacing.gap * 0.375,
                  ),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainer,
                    borderRadius: tokens.radii.chipRadius,
                    border: Border.all(color: cs.outlineVariant),
                  ),
                  child: Text(
                    t.theme_preview_card,
                    style: tokens.type.metadata.copyWith(color: cs.onSurface),
                  ),
                ),
              ),
              _spot(
                _ThemeRole.tertiary,
                SizedBox(
                  width: 72,
                  height: 8,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                      borderRadius: tokens.radii.chipRadius,
                    ),
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: 0.6,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: cs.tertiary,
                          borderRadius: tokens.radii.chipRadius,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: tokens.spacing.gap + tokens.spacing.gap / 2),
          _buildReaderPreview(reader),
          SizedBox(height: tokens.spacing.gap),
          Text(
            t.theme_preview_hint,
            style: tokens.type.metadata.copyWith(color: appCs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// 阅读器缩略：纸底 + 工具栏 + 正文（含查词选区 / 当前句高亮 / 链接）。
  Widget _buildReaderPreview(ReaderThemeColors reader) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TextStyle bodyStyle = tokens.type.listSubtitle.copyWith(
      color: reader.fg,
      height: 1.6,
    );
    // 与阅读器 CSS 同一规则：查词选区色按 alpha 预合成到纸底上（BUG-125）。
    final Color selectionOnPage = Color.alphaBlend(reader.selection, reader.bg);
    return _spot(
      _ThemeRole.readerBackground,
      Container(
        width: double.infinity,
        padding: EdgeInsets.all(tokens.spacing.gap + tokens.spacing.gap / 2),
        decoration: BoxDecoration(
          color: reader.bg,
          borderRadius: tokens.radii.chipRadius,
          border: Border.all(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _spot(
              _ThemeRole.readerText,
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.arrow_back, size: 16, color: reader.fg),
                  SizedBox(width: tokens.spacing.gap),
                  Text('第一章', style: bodyStyle),
                  SizedBox(width: tokens.spacing.gap),
                  Icon(Icons.tune, size: 16, color: reader.fg),
                ],
              ),
            ),
            SizedBox(height: tokens.spacing.gap),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                _spot(_ThemeRole.readerText, Text('日本語の', style: bodyStyle)),
                _spot(
                  _ThemeRole.selection,
                  ColoredBox(
                    color: selectionOnPage,
                    child: Text('テキスト', style: bodyStyle),
                  ),
                ),
                Text('プレビュー', style: bodyStyle),
              ],
            ),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                Text('♪ ', style: bodyStyle),
                _spot(
                  _ThemeRole.audioHighlight,
                  ColoredBox(
                    color: reader.sentenceAudioHighlight,
                    child: Text('音声ハイライト', style: bodyStyle),
                  ),
                ),
                Text('　', style: bodyStyle),
                _spot(
                  _ThemeRole.link,
                  Text(
                    'リンク',
                    style: bodyStyle.copyWith(
                      color: reader.link,
                      decoration: TextDecoration.underline,
                      decorationColor: reader.link,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 预览里「某角色影响的位置」：该角色被选中时画一圈反色描边，其余时候只留
  /// 同宽透明边（布局不跳）。
  Widget _spot(_ThemeRole role, Widget child) {
    final bool on = _selectedRole == role;
    final ColorScheme appCs = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: fushiMd3StateDuration,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        // 选中环走共享半径 token（此前写死 8，不在 app 的半径尺度上）。
        borderRadius: FushiBorderRadius.group,
        border: Border.all(
          width: 2,
          color: on ? appCs.inverseSurface : Colors.transparent,
        ),
      ),
      child: child,
    );
  }

  // ── 提示与说明行 ──

  /// A non-interactive hint row (lightbulb icon + secondary text) used inside a
  /// settings section to explain a behaviour to the user.
  Widget _buildHintRow(String text) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.gap,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lightbulb_outline, size: 18, color: cs.primary),
          SizedBox(width: tokens.spacing.gap),
          Expanded(
            child: Text(
              text,
              style: tokens.type.metadata.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  /// A standalone note line (info icon + secondary text) shown between or below
  /// sections. TODO-072 uses it to point out that subtitle colours live in the
  /// video player, not on this page.
  Widget _buildNoteRow(String text) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.gap,
        vertical: tokens.spacing.gap / 2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 16, color: cs.onSurfaceVariant),
          SizedBox(width: tokens.spacing.gap),
          Expanded(
            child: Text(
              text,
              style: tokens.type.metadata.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// 紧凑选色器：固定尺寸的 HSV 面板 + 色相条（+ 可选透明度条）+ 十六进制输入
/// + 可选预设色 + 「恢复跟随主题」。自己持 HSV 状态（灰色时保住色相，与包内
/// [ColorPicker] 一致），每次变化经 [onChanged] 通知页面即时重绘预览。
///
/// 不再用包内整块 [ColorPicker]：它按可用宽度撑满（桌面上 1900px 宽 → 近千像素
/// 高的色板），且每个启用的颜色都内联一块，页面被色板淹没、滚轮一滑就误改色。
class _ThemeColorPicker extends StatefulWidget {
  const _ThemeColorPicker({
    required this.color,
    required this.enableAlpha,
    required this.onChanged,
    required this.resetLabel,
    super.key,
    this.onReset,
    this.presets = const <Color>[],
  });

  final Color color;
  final bool enableAlpha;
  final ValueChanged<Color> onChanged;
  final VoidCallback? onReset;
  final String resetLabel;
  final List<Color> presets;

  @override
  State<_ThemeColorPicker> createState() => _ThemeColorPickerState();
}

class _ThemeColorPickerState extends State<_ThemeColorPicker> {
  late HSVColor _hsv;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.color);
  }

  @override
  void didUpdateWidget(_ThemeColorPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部换了颜色（导入分享码 / 恢复跟随主题）才重置；自己拖出来的变化回流
    // 时 toColor() 相等，保留 HSV 里的色相不被 fromColor 抹成 0。
    if (widget.color.toARGB32() != _hsv.toColor().toARGB32()) {
      _hsv = HSVColor.fromColor(widget.color);
    }
  }

  void _set(HSVColor value) {
    setState(() => _hsv = value);
    widget.onChanged(value.toColor());
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Color current = _hsv.toColor();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ClipRRect(
          borderRadius: tokens.radii.controlRadius,
          child: SizedBox(
            height: 160,
            child: ColorPickerArea(_hsv, _set, PaletteType.hsvWithHue),
          ),
        ),
        SizedBox(height: tokens.spacing.gap),
        SizedBox(
          height: 32,
          child: ColorPickerSlider(
            TrackType.hue,
            _hsv,
            _set,
            displayThumbColor: true,
          ),
        ),
        if (widget.enableAlpha)
          SizedBox(
            height: 32,
            child: ColorPickerSlider(
              TrackType.alpha,
              _hsv,
              _set,
              displayThumbColor: true,
            ),
          ),
        SizedBox(height: tokens.spacing.gap),
        Row(
          children: <Widget>[
            FushiColorSwatch(
              color: current,
              size: 36,
              borderColor: Theme.of(context).dividerColor,
            ),
            const Spacer(),
            ColorPickerInput(
              current,
              (Color c) => _set(HSVColor.fromColor(c)),
              enableAlpha: widget.enableAlpha,
              embeddedText: true,
            ),
          ],
        ),
        if (widget.presets.isNotEmpty) ...<Widget>[
          SizedBox(height: tokens.spacing.gap),
          Wrap(
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            children: <Widget>[
              for (final Color preset in widget.presets)
                FushiColorSwatch(
                  color: preset,
                  size: 28,
                  shape: FushiColorSwatchShape.dot,
                  selected: preset.toARGB32() == current.toARGB32(),
                  borderColor: Theme.of(context).dividerColor,
                  onTap: () => _set(HSVColor.fromColor(preset)),
                ),
            ],
          ),
        ],
        if (widget.onReset != null) ...<Widget>[
          SizedBox(height: tokens.spacing.gap),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: widget.onReset,
              icon: const Icon(Icons.restart_alt, size: 18),
              label: Text(widget.resetLabel),
            ),
          ),
        ],
      ],
    );
  }
}
