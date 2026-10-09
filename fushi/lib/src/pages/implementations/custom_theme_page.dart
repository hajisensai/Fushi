import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/focus/fushi_focus_scroll.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:fushi/models.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/settings/settings_kit.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart'
    show FushiRichTooltip;
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiHeightReporter;
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi/src/ai/ai_theme_assistant.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart'
    show isAchromaticSeed, kCustomThemeDefaultSeed;
import 'package:fushi/src/pages/implementations/ai_provider_settings_section.dart'
    show aiFailureText;
import 'package:fushi/utils.dart';
import 'package:material_color_utilities/material_color_utilities.dart' as mcu;

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

/// 解析「自定义主题」功能当前可用的 AI 提供商。返回 null = 没配 / 配的那家已被删或
/// 没配全，页面据此提示去设置里配，而**不发请求**。
///
/// 生产路径默认从 `AppModel.prefsRepo` 读；做成回调是给 widget 测试留缝——测试里
/// 的假 AppModel 没有初始化偏好仓库。
typedef CustomThemeAiProviderResolver = AiProviderConfig? Function();

/// 造 AI 调用客户端。测试注入假 `http.Client` 走这条缝；生产路径恒是
/// [AiChatClient] 的默认构造。
typedef CustomThemeAiClientFactory = AiChatClient Function();

class CustomThemePage extends BasePage {
  // TODO-930: edit an existing custom theme by id, or (null) draft a new one.
  // BUG-1841: a draft lives only in this page's state until the user taps
  // "apply" — opening the editor must never write to the theme list. The swatch
  // row's +new / edit-with-no-active entry points therefore pass null instead of
  // pre-persisting a blank entry.
  const CustomThemePage({
    super.key,
    this.themeId,
    this.resolveAiProvider,
    this.aiClientFactory,
  });

  final String? themeId;

  /// 非 null 时替代生产路径的提供商解析（仅测试传）。
  final CustomThemeAiProviderResolver? resolveAiProvider;

  /// 非 null 时替代 [AiChatClient] 默认构造（仅测试传）。
  final CustomThemeAiClientFactory? aiClientFactory;

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

  /// 当前正在编辑/被框出的角色（取色器打开期间有效）。
  _ThemeRole? _selectedRole;

  /// 鼠标悬停的色槽：预览里对应元素同样弹簧描边。
  _ThemeRole? _hoverRole;

  /// hero 名称是否在原位编辑中（平时是大号标题）。
  bool _editingName = false;
  final FocusNode _nameFocus = FocusNode(debugLabel: 'custom-theme-name');

  /// 窄屏吸顶预览是否展开。
  bool _previewExpanded = true;

  final FocusNode _aiFocus = FocusNode(debugLabel: 'custom-theme-ai');
  final GlobalKey _aiCardKey = GlobalKey(debugLabel: 'custom-theme-ai-card');

  /// 取色器「最近使用」：本进程内跨编辑页共享，不落盘（不新增偏好键）。
  static final List<int> _recentColors = <int>[];

  /// 每种明暗的 ColorScheme 缓存（键 = 参与派生的输入哈希）：一次 build 里
  /// 十几个色槽都要取实际显示色，不必每次重算整套动态方案。
  final Map<Brightness, (int, ColorScheme)> _schemeCache =
      <Brightness, (int, ColorScheme)>{};

  /// 本次 build 走的是否宽屏两栏（由 [LayoutBuilder] 的真实约束决定，是「点角色
  /// 行该切右栏还是弹窗」的唯一真相；不用 MediaQuery——它与实际给到本页的约束可能
  /// 不一致，例如被上层缩放/分栏包裹时）。
  bool _wideLayout = false;

  /// 窄屏吸顶预览（含下方 gap）的实测高度：预览浮在正文上，编辑列表的顶部
  /// 内边距按它让位（键盘弹出时预览收起，高度随 AnimatedSize 一路报到 0）。
  double _pinnedPreviewHeight = 0;

  void _onPinnedPreviewHeight(double height) {
    if (!mounted || height == _pinnedPreviewHeight) return;
    setState(() => _pinnedPreviewHeight = height);
  }

  // TODO-930: the entry being edited. Resolved in initState from widget.themeId
  // (a fresh id when null). Name is optional.
  late String _entryId;
  late TextEditingController _nameController;

  // BUG-1841: true when [_entryId] is not in the persisted list yet (a draft
  // opened via +new / edit-with-no-active). Nothing exists to delete, and apply
  // is the only path that writes it.
  late bool _isDraft;

  // ── 「让 AI 帮忙」区状态 ──

  final TextEditingController _aiRequestController = TextEditingController();
  bool _aiBusy = false;

  /// 上一次 AI 调用的结果提示（没配提供商 / 空结果 / 失败 / 已填入）。
  String? _aiMessage;

  /// AI 对本次改动的一句话说明。
  String _aiExplanation = '';

  /// AI 改动前的草稿快照（条目 + 当时的全局音频高亮色），非 null 时显示「撤销」。
  /// 一次 AI 生成会同时改十个角色，逐个「恢复跟随主题」既慢又拿不回原来的覆盖值。
  ({CustomThemeEntry entry, Color? audioHighlight})? _aiUndoSnapshot;

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
    final CustomThemeEntry entry =
        persisted ??
        CustomThemeEntry(
          id: widget.themeId ?? 'ct-${DateTime.now().microsecondsSinceEpoch}',
          name: '',
          seed: kCustomThemeDefaultSeed,
          // 新草稿的主题色就是品牌默认色本身（钉死），不走旧条目「取实际显示色」。
          primaryColor: kCustomThemeDefaultSeed,
        );
    _entryId = entry.id;
    _nameController = TextEditingController(text: entry.name);
    _previewBrightness = appModelNoUpdate.isDarkMode
        ? Brightness.dark
        : Brightness.light;
    _loadEntry(entry, audioHighlight: appModelNoUpdate.audioHighlightColor);
    _nameFocus.addListener(_onNameFocusChanged);
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
    _nameFocus
      ..removeListener(_onNameFocusChanged)
      ..dispose();
    _aiFocus.dispose();
    _nameController.dispose();
    _aiRequestController.dispose();
    super.dispose();
  }

  // ── 派生：ColorScheme / 阅读器色 / 各角色实际显示色 ──

  /// 系统是否提供取色（Android 壁纸 / 桌面强调色）。
  Color? get _systemAccent => appModelNoUpdate.systemPrimaryColor;

  /// 实际参与派生的主题色：跟随系统时是系统色（系统没有则回落所选色）。
  Color get _resolvedAccent =>
      _followSystemAccent ? (_systemAccent ?? _accent) : _accent;

  int get _schemeInputsHash => Object.hash(
    _resolvedAccent.toARGB32(),
    _accentAutoTone,
    _neutralDerived,
    _overrides[_ThemeRole.secondary]?.toARGB32(),
    _overrides[_ThemeRole.tertiary]?.toARGB32(),
    _overrides[_ThemeRole.container]?.toARGB32(),
    _overrides[_ThemeRole.surface]?.toARGB32(),
    appModelNoUpdate.einkMode,
    appModelNoUpdate.pureBlackDark,
  );

  ColorScheme _schemeFor(Brightness brightness) {
    final int key = _schemeInputsHash;
    final (int, ColorScheme)? cached = _schemeCache[brightness];
    if (cached != null && cached.$1 == key) return cached.$2;
    final ColorScheme scheme = _buildSchemeFor(brightness);
    _schemeCache[brightness] = (key, scheme);
    return scheme;
  }

  ColorScheme _buildSchemeFor(Brightness brightness) {
    return appModelNoUpdate.buildCustomThemeColorScheme(
      _buildEntry(),
      brightness,
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
        return FushiIcons.appearance;
      case _ThemeRole.surface:
        return FushiIcons.dashboardCustomize;
      case _ThemeRole.readerText:
        return FushiIcons.textFields;
      case _ThemeRole.readerBackground:
        return FushiIcons.readingMode;
      case _ThemeRole.link:
        return FushiIcons.link;
      case _ThemeRole.selection:
        return FushiIcons.lookup;
      case _ThemeRole.audioHighlight:
        return FushiIcons.audio;
      case _ThemeRole.secondary:
        return FushiIcons.tag;
      case _ThemeRole.tertiary:
        return FushiIcons.statistics;
      case _ThemeRole.container:
        return FushiIcons.widgets;
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

  /// 把一条条目整份装进编辑状态（分享码导入 / AI 建议 / AI 撤销共用），并把
  /// [audioHighlight] 写穿全局偏好。
  void _applyImportedTheme(
    CustomThemeEntry imported, {
    required Color? audioHighlight,
  }) {
    setState(() => _loadEntry(imported, audioHighlight: audioHighlight));
    // TODO-977：导入的音频高亮色也写穿全局偏好（与主题解耦），保持与手动改色一致。
    appModel.setAudioHighlightColor(audioHighlight);
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
              leadingIcon: FushiIcons.importFile,
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
                      _applyImportedTheme(
                        result,
                        audioHighlight:
                            result.sentenceAudioHighlightColor != null
                            ? Color(result.sentenceAudioHighlightColor!)
                            : null,
                      );
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

  // ── AI 生成 ──

  AiProviderConfig? _resolveAiProvider() {
    final CustomThemeAiProviderResolver? injected = widget.resolveAiProvider;
    if (injected != null) return injected();
    final PreferencesRepository prefs = appModelNoUpdate.prefsRepo;
    return prefs.aiFeatureAssignments.resolve(
      AiFeature.customTheme,
      prefs.aiProviders,
    );
  }

  Future<void> _runAi() async {
    if (_aiBusy) return;
    final String request = _aiRequestController.text.trim();
    if (request.isEmpty) return;
    final AiProviderConfig? provider = _resolveAiProvider();
    if (provider == null) {
      // 没有可用提供商就**一个请求都不发**：发出去只会拿回一条脱敏错误码，用户
      // 还得自己猜「是 key 错了还是根本没配」。
      setState(() {
        _aiMessage = t.ai_assist_no_provider;
        _aiExplanation = '';
      });
      return;
    }
    setState(() {
      _aiBusy = true;
      _aiMessage = null;
      _aiExplanation = '';
    });
    final AiChatClient client =
        widget.aiClientFactory?.call() ?? AiChatClient();
    final CustomThemeEntry before = _buildEntry();
    final Color? audioBefore = _overrides[_ThemeRole.audioHighlight];
    try {
      final AiThemeSuggestion suggestion = await requestAiTheme(
        client: client,
        provider: provider,
        request: request,
        current: before,
        darkMode: _previewBrightness == Brightness.dark,
        audioHighlight: audioBefore?.toARGB32(),
      );
      if (!mounted) return;
      if (suggestion.isEmpty) {
        setState(() => _aiMessage = t.ai_assist_empty);
        return;
      }
      // 只进**草稿**：与导入分享码同一条装载路径（[_applyImportedTheme]），
      // 落进主题列表仍然只有底部「应用」一个按钮——AI 不是第二条落盘路径。
      final CustomThemeEntry merged = suggestion.applyTo(before);
      _aiUndoSnapshot = (entry: before, audioHighlight: audioBefore);
      _nameController.text = merged.name;
      _applyImportedTheme(
        merged,
        // AI 没给音频高亮色时保持现状，不要因为条目里该字段为 null 就把用户已有
        // 的全局偏好清掉。
        audioHighlight:
            suggestion.colors.containsKey(AiThemeRole.audioHighlight)
            ? Color(merged.sentenceAudioHighlightColor!)
            : audioBefore,
      );
      setState(() {
        _aiMessage = t.theme_ai_applied;
        _aiExplanation = suggestion.explanation;
      });
    } on AiChatFailure catch (failure) {
      if (!mounted) return;
      setState(
        () => _aiMessage = t.ai_assist_failed(
          reason: aiFailureText(failure.message),
        ),
      );
    } finally {
      client.close();
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  /// 回到上一次 AI 生成前的草稿（含当时的全局音频高亮色）。
  void _undoAi() {
    final ({CustomThemeEntry entry, Color? audioHighlight})? snapshot =
        _aiUndoSnapshot;
    if (snapshot == null) return;
    _aiUndoSnapshot = null;
    _nameController.text = snapshot.entry.name;
    _applyImportedTheme(
      snapshot.entry,
      audioHighlight: snapshot.audioHighlight,
    );
    setState(() {
      _aiMessage = null;
      _aiExplanation = '';
    });
  }

  // ── 「让 AI 帮忙」：紧凑卡（2026-10 M3E 重设计）──

  /// 「让 AI 帮忙」紧凑卡：单行描述输入 + 生成按钮；生成中按钮换成转圈、下方
  /// 出现波浪进度条，结果提示 / 说明 / 撤销在卡内展开（尺寸变化走弹簧）。
  /// hero 的「更多」菜单里也有入口：滚到这张卡并把焦点交给输入框。
  Widget _buildAiCard() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiTypography type = context.fushiType;
    final FushiMotionScheme motion = context.fushiMotion;
    final bool apple = isGlassDesign(context);
    final double gap = tokens.spacing.gap;
    // 徽章：M3E 是 tertiaryContainer 的 cookie 形图形强调；Apple 是强调色实底
    // 圆角方块 + 白字形（iOS 设置图标的语言）。
    final Widget badge = FushiTooltip(
      message: t.ai_assist_section,
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: ShapeDecoration(
          color: apple ? appleColorsOf(context).accent : cs.tertiaryContainer,
          shape: apple
              ? const RoundedRectangleBorder(
                  borderRadius: FushiM3eShape.smallRadius,
                )
              : const FushiCookieBorder(lobes: 9),
        ),
        child: FushiIcon(
          FushiIcons.ai,
          size: 20,
          color: apple
              ? appleColorsOf(context).onAccent
              : cs.onTertiaryContainer,
        ),
      ),
    );
    final List<Widget> feedback = <Widget>[
      if (_aiMessage != null)
        Text(
          _aiMessage!,
          key: const ValueKey<String>('custom-theme-ai-message'),
          style: type.bodyMedium,
        ),
      if (_aiExplanation.isNotEmpty)
        Text(
          _aiExplanation,
          key: const ValueKey<String>('custom-theme-ai-explanation'),
          style: type.bodySmall.copyWith(color: cs.onSurfaceVariant),
        ),
      if (_aiUndoSnapshot != null)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FushiTextButton.icon(
            key: const ValueKey<String>('custom-theme-ai-undo'),
            onPressed: _aiBusy ? null : _undoAi,
            icon: const FushiIcon(FushiIcons.undo),
            label: Text(t.theme_ai_undo),
          ),
        ),
    ];
    return KeyedSubtree(
      key: _aiCardKey,
      child: FushiCard(
        key: const ValueKey<String>('custom-theme-ai-card'),
        pressScale: false,
        borderRadius: BorderRadius.circular(
          SettingsKitRadii.card(SettingsKitStyle.of(context)),
        ),
        padding: EdgeInsets.all(gap + gap / 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                badge,
                SizedBox(width: gap + gap / 2),
                Expanded(
                  child: FushiTextField(
                    key: const ValueKey<String>('custom-theme-ai-request'),
                    controller: _aiRequestController,
                    focusNode: _aiFocus,
                    hintText: t.theme_ai_hint,
                    size: FushiInputSize.medium,
                    readOnly: _aiBusy,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => unawaited(_runAi()),
                  ),
                ),
                SizedBox(width: gap),
                FushiFilledButton.icon(
                  key: const ValueKey<String>('custom-theme-ai-generate'),
                  onPressed: _aiBusy ? null : () => unawaited(_runAi()),
                  icon: _aiBusy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: FushiCircularProgressIndicator(strokeWidth: 2),
                        )
                      : const FushiIcon(FushiIcons.ai),
                  label: Text(t.ai_assist_generate),
                ),
              ],
            ),
            AnimatedSize(
              duration: motion.spatialDefault.duration,
              curve: motion.spatialDefault.curve,
              alignment: Alignment.topCenter,
              child: _aiBusy
                  ? Padding(
                      padding: EdgeInsets.only(top: gap),
                      child: Semantics(
                        label: t.ai_assist_working,
                        child: const FushiLinearProgressIndicator(
                          key: ValueKey<String>('custom-theme-ai-progress'),
                        ),
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
            AnimatedSize(
              duration: motion.spatialDefault.duration,
              curve: motion.spatialDefault.curve,
              alignment: Alignment.topCenter,
              child: feedback.isEmpty
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: EdgeInsets.only(top: gap),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          for (int i = 0; i < feedback.length; i++) ...<Widget>[
                            if (i > 0) SizedBox(height: gap / 2),
                            feedback[i],
                          ],
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// hero「更多」菜单的 AI 入口：滚到 AI 卡并聚焦输入框。
  void _focusAiCard() {
    final BuildContext? cardContext = _aiCardKey.currentContext;
    if (cardContext != null) {
      unawaited(
        FushiFocusScroll.ensureVisible(
          cardContext,
          alignment: 0.2,
          duration: context.fushiMotion.spatialDefault.duration,
          curve: context.fushiMotion.spatialDefault.curve,
        ),
      );
    }
    _aiFocus.requestFocus();
  }

  // ── 页面骨架 ──
  //
  // 2026-10 M3 Expressive 重设计（Apple 设计系统共用骨架，视觉由共享组件分派）：
  // - 外壳是设置模块统一的 [SettingsKitScaffold]：浮动页头 + 自动登记的分组
  //   跳转 chip（页内带标题的 AdaptiveSettingsSection 自动出现在跳转条里）；
  // - 宽屏（≥ [kCustomThemeWideLayoutMinWidth]）：左栏 sticky 大预览，右栏编辑；
  // - 窄屏：预览吸顶（可折叠，键盘弹出时自动让位），下面是编辑列表；
  // - 取色器不再常驻，点色块才弹出（宽屏是贴在预览右侧的浮层，窄屏是 sheet），
  //   改色期间预览始终看得见；
  // - 编辑列表错峰进场，色槽 / 色板的选中与形变走弹簧。

  /// 宽屏左栏（预览）的宽度。
  static const double _kWidePreviewWidth = 440;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final EdgeInsets mediaPadding = MediaQuery.paddingOf(context);
    final double bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final FushiMotionScheme motion = context.fushiMotion;
    final double gap = tokens.spacing.gap;
    final double page = tokens.spacing.page;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide =
            constraints.maxWidth >= kCustomThemeWideLayoutMinWidth &&
            !isCupertinoPlatform(context);
        _wideLayout = wide;
        return SettingsKitScaffold(
          title: t.custom_theme,
          leadingIcon: FushiIcons.appearance,
          leadingTone: SettingsIconTone.purple,
          // 正文滚到叠放的页头底下：编辑列表 / 宽屏预览栏的顶部内边距加上壳的
          // 页头让位；窄屏吸顶预览浮在页头下方，编辑列表再让开它的高度。
          bodyConsumesTopPadding: true,
          bodyBuilder:
              (
                BuildContext context,
                ScrollController controller,
                SettingsSectionSpy spy,
              ) {
                final List<Widget> editor = _buildEditorColumn();
                final double headerInset = MediaQuery.paddingOf(context).top;
                final EdgeInsets listPadding = EdgeInsets.fromLTRB(
                  page,
                  gap / 2 + headerInset + (wide ? 0 : _pinnedPreviewHeight),
                  page,
                  page * 2 + mediaPadding.bottom + bottomInset,
                );
                // 用不懒构建的滚动列：分组锚点要全部挂载，跳转 chip 才列得全。
                final Widget editorList = FushiEntranceScope(
                  child: SingleChildScrollView(
                    key: const ValueKey<String>('custom-theme-editor-list'),
                    controller: controller,
                    padding: wide
                        ? listPadding.copyWith(left: gap)
                        : listPadding,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        for (int i = 0; i < editor.length; i++)
                          FushiStaggeredEntrance(index: i, child: editor[i]),
                      ],
                    ),
                  ),
                );
                if (!wide) {
                  // 键盘弹出（在改名称 / AI 描述）时收起吸顶预览，把高度让给输入框。
                  // 预览浮在页头下方（与页头同为叠放层），编辑列表铺满整页、按预览
                  // 实测高度让位，往下滚时内容滚到预览与页头底下。
                  final bool keyboardOpen = bottomInset > 0;
                  return Stack(
                    children: <Widget>[
                      Positioned.fill(child: editorList),
                      Positioned(
                        top: headerInset,
                        left: 0,
                        right: 0,
                        child: FushiHeightReporter(
                          onHeight: _onPinnedPreviewHeight,
                          child: AnimatedSize(
                            duration: motion.spatialDefault.duration,
                            curve: motion.spatialDefault.curve,
                            alignment: Alignment.topCenter,
                            child: keyboardOpen
                                ? const SizedBox(width: double.infinity)
                                : Padding(
                                    key: const ValueKey<String>(
                                      'custom-theme-pinned-preview',
                                    ),
                                    padding: EdgeInsets.fromLTRB(
                                      page,
                                      0,
                                      page,
                                      gap,
                                    ),
                                    child: FushiStaggeredEntrance(
                                      index: 0,
                                      child: _buildPreviewCard(compact: true),
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ],
                  );
                }
                // 宽屏：左栏 sticky 预览（不随编辑列表滚动），右栏编辑列表。
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    SizedBox(
                      width: _kWidePreviewWidth,
                      child: FushiEntranceScope(
                        child: SingleChildScrollView(
                          primary: false,
                          padding: EdgeInsets.fromLTRB(
                            page,
                            gap / 2 + headerInset,
                            gap,
                            page + mediaPadding.bottom,
                          ),
                          child: FushiStaggeredEntrance(
                            index: 0,
                            child: _buildPreviewCard(),
                          ),
                        ),
                      ),
                    ),
                    Expanded(child: editorList),
                  ],
                );
              },
        );
      },
    );
  }

  List<Widget> _buildEditorColumn() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double card = tokens.spacing.card;
    final bool lowLight = _accentLowContrast(Brightness.light);
    final bool lowDark = _accentLowContrast(Brightness.dark);
    return <Widget>[
      // ── hero：名称 + 导入 / 分享 / 更多 + 预览明暗 ──
      _buildHeaderCard(),
      SizedBox(height: card),
      // ── 主题色：种子色块 + 推荐色板 + 色阶 ──
      AdaptiveSettingsSection(
        title: t.theme_role_accent,
        children: <Widget>[_buildSeedPanel()],
      ),
      // ── 选项：分段开关行（一行副标题，长说明收进 info 提示）──
      AdaptiveSettingsSection(
        children: <Widget>[
          _buildCompactSwitchRow(
            title: t.theme_accent_follow_system,
            subtitle: _systemAccent == null
                ? t.theme_accent_follow_system_unavailable
                : t.theme_accent_follow_system_short,
            info: t.theme_accent_follow_system_desc,
            value: _followSystemAccent && _systemAccent != null,
            onChanged: _systemAccent == null
                ? null
                : (bool value) => setState(() => _followSystemAccent = value),
          ),
          _buildCompactSwitchRow(
            title: t.theme_accent_auto_tone,
            subtitle: t.theme_accent_auto_tone_short,
            info: t.theme_accent_auto_tone_desc,
            value: _accentAutoTone,
            onChanged: (bool value) => setState(() => _accentAutoTone = value),
          ),
          _buildCompactSwitchRow(
            title: t.theme_neutral_derived,
            subtitle: t.theme_neutral_derived_short,
            info: t.theme_neutral_derived_desc,
            value: _neutralDerived,
            onChanged: (bool value) => setState(() => _neutralDerived = value),
          ),
          if (lowLight || lowDark)
            _buildContrastWarnings(light: lowLight, dark: lowDark),
        ],
      ),
      // ── 让 AI 帮忙（紧凑卡）──
      _buildAiCard(),
      SizedBox(height: card),
      // ── 界面配色 ──
      AdaptiveSettingsSection(
        title: t.theme_section_accent,
        children: <Widget>[
          _buildRoleGrid(const <_ThemeRole>[
            _ThemeRole.surface,
            _ThemeRole.secondary,
            _ThemeRole.tertiary,
            _ThemeRole.container,
          ]),
        ],
      ),
      // ── 阅读器（含有声书当前句高亮：全局偏好，说明见色槽提示）──
      AdaptiveSettingsSection(
        title: t.theme_section_reader,
        children: <Widget>[
          _buildRoleGrid(const <_ThemeRole>[
            _ThemeRole.readerText,
            _ThemeRole.readerBackground,
            _ThemeRole.link,
            _ThemeRole.selection,
            _ThemeRole.audioHighlight,
          ]),
        ],
      ),
      // TODO-072：视频字幕颜色不在此页配置，只放一行说明。
      _buildNoteRow(t.video_subtitle_color_note),
      SizedBox(height: card),
      FushiFilledButton.icon(
        key: const ValueKey<String>('custom-theme-apply'),
        size: FushiButtonSize.m,
        onPressed: _applyAndClose,
        icon: const FushiIcon(FushiIcons.check),
        label: Text(t.apply_theme),
      ),
    ];
  }

  /// 开关行：一行副标题（省略号截断），完整说明收进悬停 / 长按的 info 提示。
  Widget _buildCompactSwitchRow({
    required String title,
    required String subtitle,
    required String info,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    return FushiRichTooltip(
      title: title,
      message: info,
      child: AdaptiveSettingsSwitchRow(
        title: title,
        subtitle: subtitle,
        subtitleMaxLines: 1,
        value: value,
        onChanged: onChanged,
      ),
    );
  }

  /// 主题色对比度不足：行内警示 chip（长说明在 chip 的提示里）。
  Widget _buildContrastWarnings({required bool light, required bool dark}) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final double gap = tokens.spacing.gap;
    Widget chip(String label, String detail) => FushiTooltip(
      message: detail,
      child: FushiChip(
        avatar: FushiIcon(
          FushiIcons.warning,
          size: 18,
          color: cs.onErrorContainer,
        ),
        label: Text(label),
        labelStyle: context.fushiType.labelLarge.copyWith(
          color: cs.onErrorContainer,
        ),
        backgroundColor: cs.errorContainer,
        side: BorderSide.none,
      ),
    );
    return Padding(
      key: const ValueKey<String>('custom-theme-contrast-warning'),
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.card,
        gap,
        tokens.spacing.card,
        gap,
      ),
      child: Wrap(
        spacing: gap,
        runSpacing: gap,
        children: <Widget>[
          if (light)
            chip(t.theme_contrast_low_light, t.theme_accent_low_contrast_light),
          if (dark)
            chip(t.theme_contrast_low_dark, t.theme_accent_low_contrast_dark),
        ],
      ),
    );
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
    final bool confirmed =
        await showAppDialog<bool>(
          context: context,
          builder: (BuildContext ctx) {
            final FushiDesignTokens tokens = FushiDesignTokens.of(ctx);
            return FushiDialogFrame(
              maxWidth: 420,
              maxHeightFactor: 0.6,
              scrollable: false,
              child: FushiModalSheetFrame(
                title: t.delete_custom_theme,
                leadingIcon: FushiIcons.delete,
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

  // ── hero ──

  /// hero 卡（M3E primaryContainer 饱和色块）：主题色块 + 大号可内联编辑的
  /// 名称（TODO-930 M2：可留空，留空显示本地化默认名「自定义 N」，决策 3）；
  /// 下面一排按钮组（导入 / 分享 / 更多）+ 预览明暗分段控件。
  Widget _buildHeaderCard() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SettingsKitStyle style = SettingsKitStyle.of(context);
    final double gap = tokens.spacing.gap;
    return FushiCard(
      key: const ValueKey<String>('custom-theme-header'),
      tone: FushiCardTone.primary,
      pressScale: false,
      borderRadius: BorderRadius.circular(SettingsKitRadii.container(style)),
      padding: EdgeInsets.all(tokens.spacing.card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              _morphBlock(
                color: _effectiveColor(_ThemeRole.accent),
                size: 48,
                squared: true,
              ),
              SizedBox(width: gap + gap / 2),
              Expanded(child: _buildNameField()),
            ],
          ),
          SizedBox(height: gap + gap / 2),
          Wrap(
            spacing: gap,
            runSpacing: gap,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              FushiButtonGroup(
                children: <Widget>[
                  FushiFilledButton.tonalIcon(
                    key: const ValueKey<String>('custom-theme-import'),
                    onPressed: _importTheme,
                    icon: const FushiIcon(FushiIcons.importFile),
                    label: Text(t.import_theme),
                  ),
                  FushiFilledButton.tonalIcon(
                    key: const ValueKey<String>('custom-theme-share'),
                    onPressed: _shareTheme,
                    icon: const FushiIcon(FushiIcons.share),
                    label: Text(t.share_theme),
                  ),
                  _buildMoreMenu(),
                ],
              ),
              _buildBrightnessToggle(),
            ],
          ),
        ],
      ),
    );
  }

  /// 「更多」：让 AI 帮忙（跳到 AI 卡）/ 删除主题（草稿没有东西可删，不出现，
  /// BUG-1841：草稿还没进列表，也不该借删除去改全局主题键）。
  Widget _buildMoreMenu() {
    final bool apple = isGlassDesign(context);
    final Color destructive = apple
        ? appleColorsOf(context).destructive
        : Theme.of(context).colorScheme.error;
    Widget item(IconData icon, String label, {Color? color}) => Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiIcon(icon, size: 20, color: color),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            label,
            style: color == null ? null : TextStyle(color: color),
          ),
        ),
      ],
    );
    return FushiPopupMenuButton<String>(
      key: const ValueKey<String>('custom-theme-more'),
      tooltip: t.common_more_actions,
      icon: FushiIcon(apple ? FushiIcons.moreHoriz : FushiIcons.more),
      onSelected: (String value) {
        switch (value) {
          case 'ai':
            _focusAiCard();
          case 'delete':
            unawaited(_confirmDelete());
        }
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'ai',
          child: item(FushiIcons.ai, t.ai_assist_section),
        ),
        if (!_isDraft)
          PopupMenuItem<String>(
            key: const ValueKey<String>('custom-theme-delete'),
            value: 'delete',
            child: item(
              FushiIcons.delete,
              t.delete_custom_theme,
              color: destructive,
            ),
          ),
      ],
    );
  }

  /// 预览明暗：自定义主题跟随全局明暗，这里只是临时切换预览。
  Widget _buildBrightnessToggle() {
    return FushiSegmentedButton<Brightness>(
      key: const ValueKey<String>('custom-theme-preview-brightness'),
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      segments: <ButtonSegment<Brightness>>[
        ButtonSegment<Brightness>(
          value: Brightness.light,
          icon: const FushiIcon(FushiIcons.lightMode, size: 18),
          label: Text(t.theme_preview_light),
        ),
        ButtonSegment<Brightness>(
          value: Brightness.dark,
          icon: const FushiIcon(FushiIcons.darkMode, size: 18),
          label: Text(t.theme_preview_dark),
        ),
      ],
      selected: <Brightness>{_previewBrightness},
      onSelectionChanged: (Set<Brightness> s) =>
          setState(() => _previewBrightness = s.first),
    );
  }

  void _setEditingName(bool editing) {
    if (_editingName == editing) return;
    setState(() => _editingName = editing);
  }

  void _onNameFocusChanged() {
    if (!_nameFocus.hasFocus) _setEditingName(false);
  }

  /// TODO-930 M2：名称可留空（决策 3），留空显示本地化默认名「自定义 N」。
  /// 平时是大号标题（点按 / Enter 进入编辑），编辑时原位换成同字号的输入框，
  /// 回车或失焦回到标题。
  Widget _buildNameField() {
    final FushiTypography type = context.fushiType;
    final Color onContainer =
        fushiCardToneColors(context, FushiCardTone.primary)?.onContainer ??
        Theme.of(context).colorScheme.onPrimaryContainer;
    final TextStyle style = type.headlineSmallEmphasized.copyWith(
      color: onContainer,
    );
    final String name = _nameController.text.trim();
    final String placeholder = t.custom_theme_default_name(
      n: _defaultNameIndex,
    );
    final Widget child = _editingName
        ? FushiTextField(
            key: const ValueKey<String>('custom-theme-name-input'),
            controller: _nameController,
            focusNode: _nameFocus,
            autofocus: true,
            labelText: t.custom_theme_name,
            hintText: placeholder,
            style: type.titleLarge,
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _setEditingName(false),
          )
        : FushiTooltip(
            key: const ValueKey<String>('custom-theme-name-display'),
            message: t.custom_theme_name,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: FushiM3eShape.smallRadius,
                onTap: () => _setEditingName(true),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 4,
                  ),
                  child: Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          name.isEmpty ? placeholder : name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: name.isEmpty
                              ? style.copyWith(
                                  color: onContainer.withValues(alpha: 0.6),
                                )
                              : style,
                        ),
                      ),
                      SizedBox(
                        width: FushiDesignTokens.of(context).spacing.gap,
                      ),
                      FushiIcon(
                        FushiIcons.edit,
                        size: 20,
                        color: onContainer.withValues(alpha: 0.8),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
    return KeyedSubtree(
      key: const ValueKey<String>('custom-theme-name'),
      child: AnimatedSwitcher(
        duration: context.fushiMotion.effectsDefault.duration,
        switchInCurve: context.fushiMotion.effectsDefault.curve,
        switchOutCurve: context.fushiMotion.effectsDefault.curve,
        layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
          alignment: AlignmentDirectional.centerStart,
          children: <Widget>[...previous, if (current != null) current],
        ),
        child: child,
      ),
    );
  }

  // ── 主题色（种子）──

  /// 种子色：一行大色块（点开取色器）+ 推荐色板（圆形，选中弹簧变成圆角方块）+
  /// 由种子生成的 tonal palette 色阶条。跟随系统取色时上锁、色板收起；开了自动
  /// 调色调且实际显示色 ≠ 所选色时，把实际色摆在旁边，用户不用猜按钮为什么
  /// 不是自己选的那个颜色。
  Widget _buildSeedPanel() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiTypography type = context.fushiType;
    final FushiMotionScheme motion = context.fushiMotion;
    final bool apple = isGlassDesign(context);
    final double gap = tokens.spacing.gap;
    final Color picked = _resolvedAccent;
    final Color shown = _effectiveColor(_ThemeRole.accent);
    final bool differs = shown.toARGB32() != picked.toARGB32();
    final bool locked = _followSystemAccent && _systemAccent != null;
    final Widget seedRow = MouseRegion(
      onEnter: (_) => _setHoverRole(_ThemeRole.accent),
      onExit: (_) => _setHoverRole(null),
      child: FushiTooltip(
        message: _roleDescription(_ThemeRole.accent),
        child: FushiCard(
          key: const ValueKey<String>('custom-theme-role-accent'),
          selected: _selectedRole == _ThemeRole.accent,
          color: _selectedRole == _ThemeRole.accent
              ? null
              : (apple
                    ? appleColorsOf(context).tertiaryFill
                    : cs.surfaceContainerHigh),
          borderRadius: BorderRadius.circular(
            SettingsKitRadii.card(SettingsKitStyle.of(context)),
          ),
          padding: EdgeInsets.all(gap + gap / 2),
          onTap: locked ? null : () => unawaited(_openRole(_ThemeRole.accent)),
          child: Row(
            children: <Widget>[
              _morphBlock(color: picked, size: 56, squared: true),
              SizedBox(width: gap * 2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      t.theme_role_accent,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: type.titleMediumEmphasized,
                    ),
                    Text(
                      locked ? t.theme_accent_follow_system : _hex(picked),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: type.bodyMedium.tabular.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (differs) ...<Widget>[
                FushiTooltip(
                  message: t.theme_role_actual_color,
                  child: _swatchDot(shown),
                ),
                SizedBox(width: gap),
              ],
              FushiIcon(
                locked ? FushiIcons.lock : FushiIcons.edit,
                size: 20,
                color: cs.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
    return Padding(
      padding: EdgeInsets.all(gap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          seedRow,
          AnimatedSize(
            duration: motion.spatialDefault.duration,
            curve: motion.spatialDefault.curve,
            alignment: Alignment.topCenter,
            child: locked
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: EdgeInsets.only(top: gap + gap / 2),
                    child: Wrap(
                      spacing: gap,
                      runSpacing: gap,
                      children: <Widget>[
                        for (final Color preset in _accentPresets)
                          _ShapeSwatch(
                            key: ValueKey<String>(
                              'custom-theme-accent-preset-${preset.toARGB32()}',
                            ),
                            color: preset,
                            size: 40,
                            selected: preset.toARGB32() == _accent.toARGB32(),
                            onTap: () =>
                                _setRoleColor(_ThemeRole.accent, preset),
                          ),
                      ],
                    ),
                  ),
          ),
          // 墨水屏下整套配色被黑白顶掉，色阶没有意义。
          if (!appModelNoUpdate.einkMode) ...<Widget>[
            SizedBox(height: gap * 2),
            _buildTonalPalette(),
          ],
        ],
      ),
    );
  }

  /// 种子派生的 Material 动态方案（与真机同口径：中性灰 → monochrome，无彩度
  /// 种子 → tonalSpot，其余 → vibrant），只用来展示四条色阶。
  mcu.DynamicScheme _seedDynamicScheme() {
    final mcu.Hct source = mcu.Hct.fromInt(_resolvedAccent.toARGB32());
    final bool dark = _previewBrightness == Brightness.dark;
    if (_neutralDerived) {
      return mcu.SchemeMonochrome(
        sourceColorHct: source,
        isDark: dark,
        contrastLevel: 0,
      );
    }
    if (isAchromaticSeed(_resolvedAccent)) {
      return mcu.SchemeTonalSpot(
        sourceColorHct: source,
        isDark: dark,
        contrastLevel: 0,
      );
    }
    return mcu.SchemeVibrant(
      sourceColorHct: source,
      isDark: dark,
      contrastLevel: 0,
    );
  }

  /// tonal palette 预览：primary / secondary / tertiary / neutral 四条色阶，
  /// 每条 10–95 十档；换种子时逐格颜色过渡。
  Widget _buildTonalPalette() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiMotionScheme motion = context.fushiMotion;
    final double gap = tokens.spacing.gap;
    final mcu.DynamicScheme scheme = _seedDynamicScheme();
    const List<int> tones = <int>[10, 20, 30, 40, 50, 60, 70, 80, 90, 95];
    final List<(String, mcu.TonalPalette)> rows = <(String, mcu.TonalPalette)>[
      (t.theme_role_accent, scheme.primaryPalette),
      (t.theme_role_secondary, scheme.secondaryPalette),
      (t.theme_role_tertiary, scheme.tertiaryPalette),
      (t.theme_role_surface, scheme.neutralPalette),
    ];
    return Column(
      key: const ValueKey<String>('custom-theme-tonal-palette'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          t.theme_tonal_palette,
          style: context.fushiType.labelLarge.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
        SizedBox(height: gap * 0.75),
        for (int i = 0; i < rows.length; i++)
          Padding(
            padding: EdgeInsets.only(bottom: i < rows.length - 1 ? gap / 2 : 0),
            child: FushiTooltip(
              message: rows[i].$1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(
                  isGlassDesign(context) ? 6 : 10,
                ),
                child: SizedBox(
                  height: 20,
                  child: Row(
                    children: <Widget>[
                      for (final int tone in tones)
                        Expanded(
                          child: AnimatedContainer(
                            duration: motion.effectsDefault.duration,
                            curve: motion.effectsDefault.curve,
                            color: Color(rows[i].$2.get(tone)),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ── 色槽 tile ──

  void _setHoverRole(_ThemeRole? role) {
    if (_hoverRole == role) return;
    setState(() => _hoverRole = role);
  }

  /// 点色块：标出预览里对应的元素，弹出取色器；关闭后取消标记，并把新颜色记进
  /// 「最近使用」。
  Future<void> _openRole(_ThemeRole role) async {
    setState(() => _selectedRole = role);
    final Color before = _pickerColorFor(role);
    await _showRolePickerDialog(role);
    if (!mounted) return;
    final Color after = _pickerColorFor(role);
    if (after.toARGB32() != before.toARGB32()) _rememberRecent(after);
    setState(() => _selectedRole = null);
  }

  Color _pickerColorFor(_ThemeRole role) => role == _ThemeRole.accent
      ? _accent
      : (_overrides[role] ?? _effectiveColor(role));

  void _rememberRecent(Color color) {
    final int argb = color.toARGB32();
    _recentColors
      ..remove(argb)
      ..insert(0, argb);
    if (_recentColors.length > 8) {
      _recentColors.removeRange(8, _recentColors.length);
    }
  }

  /// 「跟随主题」→「自定义」：先把当前实际显示色钉成覆盖值（观感不跳），再打开
  /// 取色器微调。
  void _customizeRole(_ThemeRole role) {
    _setRoleColor(role, _effectiveColor(role));
    unawaited(_openRole(role));
  }

  /// 一组色槽的统一网格：每格是「色块 + 跟随/自定义 小切换 + 名称 + 值」，
  /// 按可用宽度 2–4 列；长说明收进格子的悬停 / 长按提示。
  Widget _buildRoleGrid(List<_ThemeRole> roles) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double gap = tokens.spacing.gap;
    return Padding(
      padding: EdgeInsets.all(gap),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final int columns = (constraints.maxWidth / 168)
              .floor()
              .clamp(2, 4)
              .toInt();
          final double width =
              (constraints.maxWidth - gap * (columns - 1)) / columns;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: <Widget>[
              for (final _ThemeRole role in roles)
                SizedBox(width: width, child: _buildRoleTile(role)),
            ],
          );
        },
      ),
    );
  }

  /// 色槽格子：可点（Tab / 方向键 / 手柄可达、Enter 确认）、按压回弹，当前编辑
  /// 的角色高亮；悬停时预览里对应元素弹簧描边。色块形状表达状态：跟随主题是
  /// 圆，自定义弹簧变成圆角方块（Apple 恒为圆形颜色井）。
  Widget _buildRoleTile(_ThemeRole role) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiTypography type = context.fushiType;
    final bool apple = isGlassDesign(context);
    final double gap = tokens.spacing.gap;
    final bool custom = _overrides[role] != null;
    final bool selected = _selectedRole == role;
    final Color shown = _effectiveColor(role);
    return MouseRegion(
      onEnter: (_) => _setHoverRole(role),
      onExit: (_) => _setHoverRole(null),
      child: FushiTooltip(
        message: _roleDescription(role),
        child: FushiCard(
          key: ValueKey<String>('custom-theme-role-${role.name}'),
          selected: selected,
          color: selected
              ? null
              : (apple
                    ? appleColorsOf(context).tertiaryFill
                    : cs.surfaceContainerHigh),
          borderRadius: BorderRadius.circular(
            SettingsKitRadii.card(SettingsKitStyle.of(context)),
          ),
          padding: EdgeInsets.all(gap + gap / 2),
          onTap: () => unawaited(_openRole(role)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  _morphBlock(color: shown, size: 40, squared: custom),
                  SizedBox(width: gap),
                  Expanded(
                    child: Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: _buildFollowToggle(role, custom),
                    ),
                  ),
                ],
              ),
              SizedBox(height: gap),
              Text(
                _roleTitle(role),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: type.titleSmallEmphasized,
              ),
              Text(
                _hex(shown),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: type.bodySmall.tabular.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// tile 上的「跟随主题 / 自定义」小切换：未选 = 跟随主题，选中 = 自定义；
  /// 取消选中即恢复跟随主题。
  Widget _buildFollowToggle(_ThemeRole role, bool custom) {
    return FushiTooltip(
      message: custom ? t.theme_role_reset : t.theme_role_customize,
      child: FushiFilterChip(
        key: ValueKey<String>('custom-theme-role-toggle-${role.name}'),
        selected: custom,
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        label: Text(
          custom ? t.theme_role_customize : t.theme_role_follows_theme,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onSelected: (bool value) {
          if (value) {
            _customizeRole(role);
          } else {
            _resetRole(role);
          }
        },
      ),
    );
  }

  /// 弹簧形变色块：[squared] 时是圆角方块（M3E 形状语言），否则正圆；Apple
  /// 设计系统恒为正圆颜色井。换色走颜色过渡而不是跳变。
  Widget _morphBlock({
    required Color color,
    required double size,
    required bool squared,
  }) {
    final bool apple = isGlassDesign(context);
    final FushiMotionScheme motion = context.fushiMotion;
    final Color border = Theme.of(context).colorScheme.outlineVariant;
    return SettingsSpringValue(
      value: squared && !apple ? 1 : 0,
      spring: fushiExpressiveFastSpatial,
      builder: (BuildContext context, double v, Widget? _) {
        final double radius = (lerpDouble(size / 2, size * 0.3, v) ?? size / 2)
            .clamp(4.0, size / 2);
        return AnimatedContainer(
          duration: motion.effectsDefault.duration,
          curve: motion.effectsDefault.curve,
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: border),
          ),
        );
      },
    );
  }

  String _hex(Color color) => _hexLabel(color);

  Widget _swatchDot(Color color) {
    return FushiColorSwatch(
      color: color,
      size: 24,
      shape: FushiColorSwatchShape.dot,
      borderColor: Theme.of(context).dividerColor,
    );
  }

  // ── 取色器（宽屏贴预览右侧的浮层 / 窄屏 sheet，共用同一个 widget）──

  Widget _buildPickerFor(_ThemeRole role, {VoidCallback? onLocalChange}) {
    final bool optional = role != _ThemeRole.accent;
    return _ThemeColorPicker(
      key: ValueKey<_ThemeRole>(role),
      color: _pickerColorFor(role),
      enableAlpha: _roleAllowsAlpha(role),
      presets: switch (role) {
        _ThemeRole.accent => _accentPresets,
        _ThemeRole.surface || _ThemeRole.readerBackground => _surfacePresets,
        _ => const <Color>[],
      },
      recents: <Color>[for (final int argb in _recentColors) Color(argb)],
      recentLabel: t.theme_picker_recent,
      onChanged: (Color c) {
        _setRoleColor(role, c);
        onLocalChange?.call();
      },
      onReset: optional && _overrides[role] != null
          ? () {
              _resetRole(role);
              onLocalChange?.call();
            }
          : null,
      resetLabel: t.theme_role_reset,
    );
  }

  Future<void> _showRolePickerDialog(_ThemeRole role) {
    Widget content(BuildContext ctx) => StatefulBuilder(
      // 路由不随页面 setState 重建：本地刷新让「恢复跟随主题」等随改色出现。
      builder: (BuildContext ctx, StateSetter setLocal) {
        final FushiDesignTokens tokens = FushiDesignTokens.of(ctx);
        return FushiModalSheetFrame(
          title: _roleTitle(role),
          subtitle: _roleDescription(role),
          leadingIcon: _roleIcon(role),
          // 选色器（HSV 面板 + 色条 + 十六进制 + 推荐色 + 最近使用）固有高
          // 约 300；矮窗口（横屏手机 / 600 高桌面窗）里 sheet 正文给不到，
          // 不滚动就底部溢出、推荐色点不到。内容放得下时不产生滚动手势。
          scrollable: true,
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
          body: _buildPickerFor(role, onLocalChange: () => setLocal(() {})),
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
        );
      },
    );
    if (_wideLayout) {
      // 宽屏：浮层贴在预览右侧、不压暗页面，改色时左栏预览完整可见。
      return showAppDialog<void>(
        context: context,
        barrierColor: Colors.transparent,
        builder: (BuildContext ctx) => FushiDialogFrame(
          maxWidth: 420,
          maxHeightFactor: 0.9,
          insetPadding: const EdgeInsets.fromLTRB(
            _kWidePreviewWidth + 24,
            24,
            24,
            24,
          ),
          child: content(ctx),
        ),
      );
    }
    return adaptiveModalSheet<void>(context: context, builder: content);
  }

  // ── 预览：一张缩小的「真 app」截面——导航胶囊 + 卡片 + 按钮 / 开关 / 标签 /
  //    进度 + 阅读器正文页（含查词高亮 / 当前句 / 链接）。每个元素的颜色都取
  //    自真实 ColorScheme / 真实阅读器解析链，按当前预览明暗实时渲染；悬停或
  //    点开某个色槽时，对应元素弹簧描边脉冲。──

  /// [compact]：窄屏吸顶用的紧凑形态——阅读器页与 app 截面左右并排，可折叠成
  /// 只剩标题行。
  Widget _buildPreviewCard({bool compact = false}) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiTypography type = context.fushiType;
    final FushiMotionScheme motion = context.fushiMotion;
    final ColorScheme cs = _scheme;
    final ReaderThemeColors reader = _readerColorsFor(cs);
    final double gap = tokens.spacing.gap;
    final bool expanded = !compact || _previewExpanded;
    final Widget header = Row(
      children: <Widget>[
        Expanded(
          child: Text(
            t.preview,
            style: type.titleSmallEmphasized.copyWith(color: cs.onSurface),
          ),
        ),
        FushiTooltip(
          message: t.theme_preview_hint,
          child: FushiIcon(
            FushiIcons.info,
            size: 18,
            color: cs.onSurfaceVariant,
          ),
        ),
        if (compact) ...<Widget>[
          SizedBox(width: gap / 2),
          FushiIconButton(
            key: const ValueKey<String>('custom-theme-preview-toggle'),
            icon: expanded ? FushiIcons.expandLess : FushiIcons.expandMore,
            tooltip: expanded
                ? t.theme_preview_collapse
                : t.theme_preview_expand,
            size: 20,
            enabledColor: cs.onSurfaceVariant,
            onTap: () => setState(() => _previewExpanded = !_previewExpanded),
          ),
        ],
      ],
    );
    final Widget body = compact
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                flex: 5,
                child: _buildReaderPreview(reader, compact: true),
              ),
              SizedBox(width: gap),
              Expanded(flex: 4, child: _buildAppPreview(cs, compact: true)),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _buildAppPreview(cs),
              SizedBox(height: gap + gap / 2),
              _buildReaderPreview(reader),
            ],
          );
    return AnimatedContainer(
      key: ValueKey<String>(
        compact ? 'custom-theme-preview-compact' : 'custom-theme-preview',
      ),
      duration: motion.effectsDefault.duration,
      curve: motion.effectsDefault.curve,
      padding: EdgeInsets.all(compact ? gap + gap / 2 : tokens.spacing.card),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(
          SettingsKitRadii.container(SettingsKitStyle.of(context)),
        ),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          header,
          AnimatedSize(
            duration: motion.spatialDefault.duration,
            curve: motion.spatialDefault.curve,
            alignment: Alignment.topCenter,
            child: expanded
                ? Padding(
                    padding: EdgeInsets.only(top: gap),
                    child: body,
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  /// app 截面：一张内容卡（封面块 / 标题 / 进度 / 按钮 / 标签 / 开关）+ 底部
  /// 导航胶囊。
  Widget _buildAppPreview(ColorScheme cs, {bool compact = false}) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiTypography type = context.fushiType;
    final double gap = tokens.spacing.gap;
    const StadiumBorder pill = StadiumBorder();
    final Widget cover = _spot(
      _ThemeRole.tertiary,
      Container(
        width: compact ? 28 : 40,
        height: compact ? 28 : 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: cs.tertiaryContainer,
          borderRadius: FushiM3eShape.smallRadius,
        ),
        child: FushiIcon(
          FushiIcons.books,
          size: compact ? 16 : 20,
          color: cs.onTertiaryContainer,
        ),
      ),
    );
    final Widget button = _spot(
      _ThemeRole.accent,
      Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? gap : gap * 2,
          vertical: gap * 0.75,
        ),
        decoration: ShapeDecoration(color: cs.primary, shape: pill),
        child: Text(
          t.theme_preview_button,
          style: type.labelLarge.copyWith(color: cs.onPrimary),
        ),
      ),
    );
    final Widget tag = _spot(
      _ThemeRole.secondary,
      Container(
        padding: EdgeInsets.symmetric(horizontal: gap, vertical: gap * 0.375),
        decoration: BoxDecoration(
          color: cs.secondaryContainer,
          borderRadius: FushiM3eShape.smallRadius,
        ),
        child: Text(
          t.theme_preview_tag,
          style: type.labelMedium.copyWith(color: cs.onSecondaryContainer),
        ),
      ),
    );
    final Widget previewSwitch = FushiPreviewSwitch(
      trackColor: cs.primaryContainer,
      thumbColor: cs.primary,
    );
    final Widget toggle = _spot(
      _ThemeRole.container,
      // 紧凑（窄屏吸顶）预览里示意开关按 28 高等比缩小：原尺寸（MD3 开关
      // 约 66×46）在约 130 宽的 app 截面里把「按钮 / 标签 / 开关」挤成三行，
      // 吸顶预览超过视口高度的三分之一。
      compact
          ? SizedBox(height: 28, child: FittedBox(child: previewSwitch))
          : previewSwitch,
    );
    final Widget progress = _spot(
      _ThemeRole.tertiary,
      SizedBox(
        height: 6,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: cs.surfaceContainerHighest,
            shape: pill,
          ),
          child: FractionallySizedBox(
            alignment: AlignmentDirectional.centerStart,
            widthFactor: 0.6,
            child: DecoratedBox(
              decoration: ShapeDecoration(color: cs.tertiary, shape: pill),
            ),
          ),
        ),
      ),
    );
    final Widget card = _spot(
      _ThemeRole.surface,
      Container(
        padding: EdgeInsets.all(compact ? gap : gap + gap / 2),
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          borderRadius: compact
              ? FushiM3eShape.smallRadius
              : FushiM3eShape.cardRadius,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                cover,
                SizedBox(width: gap),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        t.theme_preview_card,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: type.titleSmallEmphasized.copyWith(
                          color: cs.onSurface,
                        ),
                      ),
                      Text(
                        '第一章',
                        maxLines: 1,
                        style: type.bodySmall.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!compact)
                  _spot(
                    _ThemeRole.accent,
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        FushiIcon(
                          FushiIcons.filled(FushiIcons.favorite),
                          color: cs.primary,
                          size: 20,
                        ),
                        SizedBox(width: gap / 2),
                        FushiIcon(
                          FushiIcons.filled(FushiIcons.bookmark),
                          color: cs.primary,
                          size: 20,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            SizedBox(height: gap),
            progress,
            SizedBox(height: gap),
            Wrap(
              spacing: gap,
              runSpacing: gap,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[button, tag, toggle],
            ),
          ],
        ),
      ),
    );
    Widget navItem(IconData icon, {bool selected = false}) => Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? gap : gap * 1.5,
        vertical: gap * 0.75,
      ),
      decoration: selected
          ? ShapeDecoration(color: cs.secondaryContainer, shape: pill)
          : null,
      child: FushiIcon(
        selected ? FushiIcons.filled(icon) : icon,
        size: 20,
        color: selected ? cs.onSecondaryContainer : cs.onSurfaceVariant,
      ),
    );
    final Widget nav = _spot(
      _ThemeRole.secondary,
      Container(
        padding: EdgeInsets.all(gap / 2),
        decoration: ShapeDecoration(color: cs.surfaceContainer, shape: pill),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            navItem(FushiIcons.home, selected: true),
            navItem(FushiIcons.books),
            navItem(FushiIcons.video),
            if (!compact) navItem(FushiIcons.search),
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        card,
        SizedBox(height: gap),
        Center(
          child: FittedBox(fit: BoxFit.scaleDown, child: nav),
        ),
      ],
    );
  }

  /// 阅读器正文页：纸底 + 工具栏 + 正文（含查词选区 / 当前句高亮 / 链接）。
  Widget _buildReaderPreview(ReaderThemeColors reader, {bool compact = false}) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiTypography type = context.fushiType;
    final double gap = tokens.spacing.gap;
    final TextStyle bodyStyle = (compact ? type.bodySmall : type.bodyLarge)
        .copyWith(color: reader.fg, height: 1.7);
    // 与阅读器 CSS 同一规则：查词选区色按 alpha 预合成到纸底上（BUG-125）。
    final Color selectionOnPage = Color.alphaBlend(reader.selection, reader.bg);
    return _spot(
      _ThemeRole.readerBackground,
      Container(
        width: double.infinity,
        padding: EdgeInsets.all(compact ? gap : gap * 2),
        decoration: BoxDecoration(
          color: reader.bg,
          borderRadius: compact
              ? FushiM3eShape.smallRadius
              : FushiM3eShape.cardRadius,
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
                  FushiIcon(FushiIcons.back, size: 16, color: reader.fg),
                  SizedBox(width: gap),
                  Text('第一章', style: bodyStyle),
                  SizedBox(width: gap),
                  FushiIcon(FushiIcons.settings, size: 16, color: reader.fg),
                ],
              ),
            ),
            SizedBox(height: gap),
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
                Text('を読む。', style: bodyStyle),
              ],
            ),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
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

  /// 预览里「某角色影响的位置」：该角色被悬停 / 选中时弹簧描边（反色环淡入 +
  /// 一次 overshoot 脉冲缩放），其余时候只留同宽透明边（布局不跳）。墨水屏 /
  /// 减弱动态效果下直接到位。
  Widget _spot(_ThemeRole role, Widget child) {
    final bool on = _selectedRole == role || _hoverRole == role;
    final Color ring = Theme.of(context).colorScheme.inverseSurface;
    return SettingsSpringValue(
      value: on ? 1 : 0,
      spring: fushiExpressiveFastSpatial,
      child: child,
      builder: (BuildContext context, double v, Widget? spotChild) {
        final double settled = v.clamp(0.0, 1.0);
        // 弹簧越界的那一截就是脉冲：落定后缩放回到 1。
        final double pulse = (v - settled).abs();
        return Transform.scale(
          scale: 1 + pulse * 0.6,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: FushiM3eShape.smallRadius,
              border: Border.all(
                width: 2,
                color: ring.withValues(alpha: settled),
              ),
            ),
            child: Padding(padding: const EdgeInsets.all(3), child: spotChild),
          ),
        );
      },
    );
  }

  // ── 说明行 ──

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
          FushiIcon(FushiIcons.info, size: 16, color: cs.onSurfaceVariant),
          SizedBox(width: tokens.spacing.gap),
          Expanded(
            child: Text(
              text,
              style: context.fushiType.bodySmall.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// `#RRGGBB`（带透明度时追加百分比）。
String _hexLabel(Color color) {
  final int argb = color.toARGB32();
  final String rgb = (argb & 0xFFFFFF)
      .toRadixString(16)
      .padLeft(6, '0')
      .toUpperCase();
  final int alpha = (argb >> 24) & 0xFF;
  return alpha == 0xFF ? '#$rgb' : '#$rgb · ${(alpha * 100 / 255).round()}%';
}

/// M3E 色板格：未选是圆，选中弹簧变成圆角方块并加对勾与描边；Apple 恒为圆形
/// 颜色井，选中只加强调色外环。可 Tab / 方向键聚焦、Enter 选中。
class _ShapeSwatch extends StatelessWidget {
  const _ShapeSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
    super.key,
    this.size = 36,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color ring = apple ? appleColorsOf(context).accent : cs.onSurface;
    final Color check = color.computeLuminance() > 0.5
        ? const Color(0xFF000000)
        : const Color(0xFFFFFFFF);
    return FushiTooltip(
      message: _hexLabel(color),
      child: SettingsSpringValue(
        value: selected ? 1 : 0,
        spring: fushiExpressiveFastSpatial,
        builder: (BuildContext context, double v, Widget? _) {
          final double settled = v.clamp(0.0, 1.0);
          final double radius = apple
              ? size / 2
              : (lerpDouble(size / 2, size * 0.28, v) ?? size / 2).clamp(
                  4.0,
                  size / 2,
                );
          final BorderRadius shape = BorderRadius.circular(radius);
          return Semantics(
            selected: selected,
            button: true,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: onTap,
                customBorder: RoundedRectangleBorder(borderRadius: shape),
                child: Container(
                  width: size,
                  height: size,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: shape,
                    border: Border.all(
                      width: 1 + 1.5 * settled,
                      color: Color.lerp(cs.outlineVariant, ring, settled)!,
                    ),
                  ),
                  child: apple
                      ? null
                      : Opacity(
                          opacity: settled,
                          child: FushiIcon(
                            FushiIcons.check,
                            size: size * 0.5,
                            color: check,
                          ),
                        ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 紧凑选色器：固定尺寸的 HSV 面板 + 色相条（+ 可选透明度条）+ 十六进制输入
/// + 推荐色 + 最近使用 + 「恢复跟随主题」。自己持 HSV 状态（灰色时保住色相，与包内
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
    required this.recentLabel,
    super.key,
    this.onReset,
    this.presets = const <Color>[],
    this.recents = const <Color>[],
  });

  final Color color;
  final bool enableAlpha;
  final ValueChanged<Color> onChanged;
  final VoidCallback? onReset;
  final String resetLabel;
  final String recentLabel;
  final List<Color> presets;
  final List<Color> recents;

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

  Widget _swatchRow(List<Color> colors, Color current) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Wrap(
      spacing: tokens.spacing.gap,
      runSpacing: tokens.spacing.gap,
      children: <Widget>[
        for (final Color c in colors)
          _ShapeSwatch(
            key: ValueKey<String>(
              'custom-theme-swatch-${c.toARGB32().toRadixString(16).padLeft(8, '0')}',
            ),
            color: c,
            size: 32,
            selected: c.toARGB32() == current.toARGB32(),
            onTap: () => _set(HSVColor.fromColor(c)),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiMotionScheme motion = context.fushiMotion;
    final double gap = tokens.spacing.gap;
    final Color current = _hsv.toColor();
    final List<Color> recents = <Color>[
      for (final Color c in widget.recents)
        if (!widget.presets.any((Color p) => p.toARGB32() == c.toARGB32())) c,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(
            SettingsKitRadii.small(SettingsKitStyle.of(context)),
          ),
          child: SizedBox(
            height: 160,
            child: ColorPickerArea(_hsv, _set, PaletteType.hsvWithHue),
          ),
        ),
        SizedBox(height: gap),
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
        SizedBox(height: gap),
        Row(
          children: <Widget>[
            AnimatedContainer(
              duration: motion.effectsFast.duration,
              curve: motion.effectsFast.curve,
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: current,
                borderRadius: FushiM3eShape.smallRadius,
                border: Border.all(color: cs.outlineVariant),
              ),
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
          SizedBox(height: gap + gap / 2),
          _swatchRow(widget.presets, current),
        ],
        if (recents.isNotEmpty) ...<Widget>[
          SizedBox(height: gap + gap / 2),
          Text(
            widget.recentLabel,
            style: context.fushiType.labelLarge.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          SizedBox(height: gap / 2),
          _swatchRow(recents, current),
        ],
        if (widget.onReset != null) ...<Widget>[
          SizedBox(height: gap),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FushiTextButton.icon(
              onPressed: widget.onReset,
              icon: const FushiIcon(FushiIcons.restart, size: 18),
              label: Text(widget.resetLabel),
            ),
          ),
        ],
      ],
    );
  }
}
