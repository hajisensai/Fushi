import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hibiki/src/settings/settings_context.dart';

enum SettingsDestinationId {
  appearance,
  profiles,
  reading,
  lookup,
  cardCreation,
  video,
  listening,
  // 「下载」一级分类：torrent / qBittorrent 后端配置从下载页齿轮抬进设置主页
  // （可达 + 可搜）。位置紧随视频/听，在同步备份之前。
  downloads,
  // 「游戏」一级分类（审计 K/Phase 3.12）：游戏库 / 捕获工作台 / 兼容性诊断此前
  // 完全没有 settings destination，页面与其中配置项不可搜。与 games 顶层 tab
  // 同门控（仅 Windows，galgame hook 平台边界）。
  game,
  syncBackup,
  system,
  // Hibiki P2P 互联（设备直连 + 本机作为服务器）；从 syncBackup 拆出的
  // 独立一级分类（构建函数在 sync_settings_schema.dart 同库，共享私有状态）。
  interconnect,
  // Synthetic destination for the reader quick-settings dialog; its own id so
  // it never collides with the real reading destination (HBK-AUDIT-131).
  readerQuickSettings,
  // Synthetic destination for the pushed app-icon sub-page
  // (MiscellaneousSettingsPage)；own id so the shell no longer borrows
  // `appearance` for content that isn't the appearance destination.
  appIcon,
  // Synthetic destination for the in-video quick-settings sheet; its own id so
  // it never collides with the real video destination（与 readerQuickSettings
  // 同款约定）。
  videoQuickSettings,
  // Synthetic destination for the pushed shortcut-settings page
  // (ShortcutSettingsPage)；own id so the shell no longer borrows `system` for
  // content that isn't the system destination（与 appIcon 同款约定）。
  shortcuts,
}

/// 书内快捷面板的分组维度，与全局 [SettingsDestinationId] 正交。
/// 一个设置项可以同时出现在全局某 destination 和书内某 [ReaderGroup]。
///
/// TODO-802/774：原「外观」组（appearance）已删——字体/行高/缩进早已并入
/// [layout]（TODO-774），最后只剩主题选择器，亦并入 [layout]（主题改的也是阅读
/// 显示），外观组整个不再存在。
enum ReaderGroup { layout, behavior, lookup, audiobook }

/// 描述某个 [SettingsItem] 在书内快捷面板里的放置位置。
/// 为 null 表示该项不出现在书内面板（仅全局可见）。
class ReaderPlacement {
  const ReaderPlacement({required this.group, required this.order});

  final ReaderGroup group;

  /// 在所属 [group] 内的升序排序键（仅组内有效，可有间隔）。
  final int order;
}

/// 视频快捷设置面板的分组维度，与全局 [SettingsDestinationId] 正交；与
/// [ReaderGroup] 同款设计。取值对齐 video_quick_settings_sheet 的现有大分类
/// （playback/audio/subtitle/shaders/mpv/danmaku/controls），阶段 B 重写该
/// 面板时按此投影 schema。
enum VideoGroup { playback, audio, subtitle, shaders, mpv, danmaku, controls }

/// 描述某个 [SettingsItem] 在视频快捷面板里的放置位置。
/// 为 null 表示该项不出现在视频面板（仅全局可见）。
class VideoPlacement {
  const VideoPlacement(
      {required this.group, required this.order, this.section});

  final VideoGroup group;

  /// 在所属 [group] 内的升序排序键（仅组内有效，可有间隔）。
  final int order;

  /// 组内小节标题（如 mpv 组的「画质 / 画面几何 / 色彩均衡」）。投影时相邻同名
  /// 条目并入同一个带标题 [SettingsSection]；null = 无题小节（相邻 null 合并）。
  final String? section;
}

typedef SettingsVisibility = bool Function(SettingsContext context);
typedef SettingsItemAction = FutureOr<void> Function(SettingsContext context);
typedef SettingsItemBuilder = Widget Function(SettingsContext context);
typedef SettingsValueGetter<T extends Object> = T Function(
  SettingsContext context,
);
typedef SettingsValueChanged<T extends Object> = FutureOr<void> Function(
  SettingsContext context,
  T value,
);
typedef SettingsSwitchGetter = bool Function(SettingsContext context);
typedef SettingsSwitchChanged = FutureOr<void> Function(
  SettingsContext context,
  bool value,
);
typedef SettingsDoubleFormatter = String Function(double value);

class SettingsDestination {
  const SettingsDestination({
    required this.id,
    required this.title,
    required this.icon,
    required this.sections,
    this.summary,
    this.visible,
    this.body,
    this.bodySearchEntries = const <SettingsBodySearchEntry>[],
  });

  final SettingsDestinationId id;
  final String title;
  final IconData icon;
  final String? summary;
  final SettingsVisibility? visible;
  final List<SettingsSection> sections;

  /// 可选的「整页正文」逃生口：非空时，渲染器在渲染完 [sections] 后把
  /// `body(context)` 接在同一个滚动容器里。用于把原本藏在子级菜单（独立路由
  /// 页）的复杂正文——Anki 设置、Profile 管理——直接平铺进本 destination 详情页，
  /// 消掉一层多余跳转。返回的 widget 必须自带 [AdaptiveSettingsSection] 布局且
  /// **不得**自带脚手架/独立滚动（外层渲染器已提供滚动与内边距）。
  final SettingsItemBuilder? body;

  /// [body] 逃生口里设置行的搜索元数据。设置搜索索引器只遍历 [sections]，
  /// body 自绘正文里的行对它不可见；在此登记行标题让它们进入搜索。命中后跳转
  /// 到本分类正文即可——body 行不是 schema item，没有滚动定位挂点。
  final List<SettingsBodySearchEntry> bodySearchEntries;

  bool isVisible(SettingsContext context) => visible?.call(context) ?? true;

  List<SettingsSection> visibleSections(SettingsContext context) {
    return sections
        .where((SettingsSection section) => section.isVisible(context))
        .map((SettingsSection section) => section.visibleCopy(context))
        .where((SettingsSection section) => section.items.isNotEmpty)
        .toList(growable: false);
  }
}

/// [SettingsDestination.bodySearchEntries] 的一条：body 逃生口正文里某个设置行
/// 的搜索元数据（标题用与正文行一致的 i18n 文案；[subtitle] 参与元数据打分）。
/// [visible] 为 null 表示恒可搜；否则与渲染同款谓词求值，平台/状态下不显示的
/// 行不会进搜索索引。
class SettingsBodySearchEntry {
  const SettingsBodySearchEntry({
    required this.id,
    required this.title,
    this.subtitle,
    this.visible,
  });

  /// 全局唯一 id（约定带所属 destination 前缀，如 `card_creation.anki.deck`）。
  /// 只用于搜索条目身份，不对应任何 schema item。
  final String id;
  final String title;
  final String? subtitle;
  final SettingsVisibility? visible;

  bool isVisible(SettingsContext context) => visible?.call(context) ?? true;
}

/// 测试钩子：为 true 时，渲染器忽略每个 section 的 [SettingsSection.collapsedByDefault]，
/// 把所有可折叠 section 一律按展开渲染。默认折叠会把折叠 section 的行移出 widget 树，
/// 而 `settings_schema_coverage_test` 以 Tab 焦点遍历逐行驱动——够不到的行会被静默跳过、
/// 削弱这道覆盖守卫。凡「枚举/驱动全部设置行」的测试须在 setUp 里置 true、tearDown 复位。
bool debugSettingsForceExpandAllSections = false;

class SettingsSection {
  const SettingsSection({
    required this.items,
    this.title,
    this.footer,
    this.visible,
    this.collapsedByDefault = false,
  });

  final String? title;
  final String? footer;
  final SettingsVisibility? visible;
  final List<SettingsItem> items;

  /// 为 true 时本 section 进入详情页默认收起，标题头带可点击的展开箭头（触摸/鼠标
  /// 点头 + 焦点驱动 Enter/手柄 A 都能展开）。只对带 [title] 的 section 生效——无题
  /// section（如互联未激活指引）没有可点的头，永远平铺。搜索命中折叠 section 内的项
  /// 时渲染器强制展开定位（见 SettingsSchemaSection）。仅影响显示，不改 item 集合/顺序/
  /// 持久化。
  final bool collapsedByDefault;

  bool isVisible(SettingsContext context) => visible?.call(context) ?? true;

  SettingsSection visibleCopy(SettingsContext context) {
    return SettingsSection(
      title: title,
      footer: footer,
      visible: visible,
      collapsedByDefault: collapsedByDefault,
      items: items
          .where((SettingsItem item) => item.isVisible(context))
          .toList(growable: false),
    );
  }
}

sealed class SettingsItem {
  const SettingsItem({
    required this.id,
    required this.title,
    this.subtitle,
    this.icon,
    this.visible,
    this.reader,
    this.video,
  });

  final String id;
  final String title;
  final String? subtitle;
  final IconData? icon;
  final SettingsVisibility? visible;

  /// 书内快捷面板放置；null = 仅全局可见。
  final ReaderPlacement? reader;

  /// 视频快捷面板放置；null = 不出现在视频面板。
  final VideoPlacement? video;

  bool isVisible(SettingsContext context) => visible?.call(context) ?? true;
}

class SettingsNavigationItem extends SettingsItem {
  const SettingsNavigationItem({
    required super.id,
    required super.title,
    this.builder,
    this.onTap,
    this.showIcon = false,
    super.subtitle,
    super.icon,
    super.visible,
    super.reader,
    super.video,
  }) : assert(builder != null || onTap != null);

  final WidgetBuilder? builder;
  final SettingsItemAction? onTap;
  final bool showIcon;
}

class SettingsActionItem extends SettingsItem {
  const SettingsActionItem({
    required super.id,
    required super.title,
    required this.onTap,
    super.subtitle,
    super.icon,
    super.visible,
    super.reader,
    super.video,
  });

  final SettingsItemAction onTap;
}

class SettingsSwitchItem extends SettingsItem {
  const SettingsSwitchItem({
    required super.id,
    required super.title,
    required this.value,
    required this.onChanged,
    super.subtitle,
    super.icon,
    super.visible,
    super.reader,
    super.video,
  });

  final SettingsSwitchGetter value;
  final SettingsSwitchChanged onChanged;
}

class SettingsSegmentOption<T extends Object> {
  const SettingsSegmentOption({
    required this.value,
    required this.label,
    this.icon,
    this.tooltip,
  });

  final T value;
  final String label;
  final IconData? icon;
  final String? tooltip;
}

class SettingsSegmentedItem<T extends Object> extends SettingsItem {
  const SettingsSegmentedItem({
    required super.id,
    required super.title,
    required this.options,
    required this.selected,
    required this.onChanged,
    super.subtitle,
    super.icon,
    super.visible,
    super.reader,
    super.video,
    this.controlBelow = true,
    this.dropdown = false,
  });

  final List<SettingsSegmentOption<T>> options;
  final SettingsValueGetter<T> selected;
  final SettingsValueChanged<T> onChanged;
  final bool controlBelow;

  /// true = 渲染成下拉单选（AdaptiveSettingsPickerRow）而非分段条。用于标签长 /
  /// 选项多、分段条在窄 pane 只能横向滚动裁断的行（TODO-209 沉浸模式四态、mpv
  /// 解码/几何/声道等）；数据模型不变，仅换行控件。
  final bool dropdown;

  /// 渲染器持有的是 `SettingsSegmentedItem<Object>`，静态读 [onChanged]（实际签名
  /// `(ctx, T)`）会因函数参数逆变抛 `_TypeError`——故在真实 [T] 上下文里转回再调。
  FutureOr<void> dispatchChange(SettingsContext context, Object value) =>
      onChanged(context, value as T);
}

class SettingsSliderItem extends SettingsItem {
  const SettingsSliderItem({
    required super.id,
    required super.title,
    required this.value,
    required this.onChanged,
    super.subtitle,
    super.icon,
    super.visible,
    super.reader,
    super.video,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
    this.onChangeEnd,
    this.step,
    this.titleReadout = false,
    this.commitOnRelease = false,
  }) : assert(
          !commitOnRelease || onChangeEnd == null,
          'commitOnRelease 滑条松手统一走 onChanged 提交，不得再声明 onChangeEnd',
        );

  final double Function(SettingsContext context) value;
  final double min;
  final double max;
  final int? divisions;
  final SettingsDoubleFormatter? label;
  final SettingsValueChanged<double> onChanged;
  final SettingsValueChanged<double>? onChangeEnd;

  /// 键盘 / 手柄左右键单按步进（覆盖默认的「一档 divisions」步进）。
  /// 用于拖动档位（细）与按键步进（粗）需要解耦的滑条。
  final double? step;

  /// 为 true 时渲染器在标题后追加实时读数 `(label(value))`，如「音量 (95%)」。
  /// [title] 本身保持裸标题不变（焦点遍历 / 覆盖测试以裸标题为身份 key）。
  final bool titleReadout;

  /// 为 true 时拖动只更新渲染层本地预览值（跟手 + 读数实时），松手才把最终值经
  /// [onChanged] 提交一次。用于写穿成本高（BUG-963：播放页逐 tick 写穿触发全页
  /// rebuild 掉帧）且拖动过程无实时预览意义的滑条；键盘/手柄步进仍每按即提交。
  /// 与 [onChangeEnd] 互斥（松手提交统一走 [onChanged]）。
  final bool commitOnRelease;
}

class SettingsStepperItem extends SettingsItem {
  const SettingsStepperItem({
    required super.id,
    required super.title,
    required this.value,
    required this.step,
    required this.min,
    required this.max,
    required this.format,
    required this.onChanged,
    super.subtitle,
    super.icon,
    super.visible,
    super.reader,
    super.video,
  });

  final double Function(SettingsContext context) value;
  final double step;
  final double min;
  final double max;
  final SettingsDoubleFormatter format;
  final SettingsValueChanged<double> onChanged;
}

/// 一等文本输入项：字符串值经 getter/setter 闭包同步读写。渲染复用
/// settings_schema_fields 的 [SettingsSecretField] 内部（防抖/提交语义一致），
/// 由共享 SettingsSchemaItem 分发，Material/Cupertino 同路径。
class SettingsTextItem extends SettingsItem {
  const SettingsTextItem({
    required super.id,
    required super.title,
    required this.value,
    required this.onChanged,
    this.secret = false,
    this.debounce = const Duration(milliseconds: 500),
    this.resetValue,
    this.placeholder,
    this.keyboardType,
    super.subtitle,
    super.icon,
    super.visible,
    super.reader,
    super.video,
  });

  final SettingsValueGetter<String> value;
  final SettingsValueChanged<String> onChanged;

  /// true = 敏感值：明文遮蔽渲染 + 行尾眼睛按钮切换显隐（API key 等）。
  final bool secret;

  /// 击键到写穿的防抖间隔；[Duration.zero] = 每次击键立即写。提交（回车）恒立即写。
  final Duration debounce;

  /// 非 null 时行尾提供重置按钮，点击把该值写回并回填输入框。
  final SettingsValueGetter<String>? resetValue;

  /// 输入框占位提示；null = 不显示。
  final String? placeholder;

  /// null 时按 [secret] 取 visiblePassword / text。
  final TextInputType? keyboardType;
}

/// 一等数字输入项：文本框输入 int/double，镜像 [SettingsNumberField] 行为
/// （逐击键解析写穿 + 重置按钮），另支持可选 min/max 夹取；解析失败不写。
class SettingsNumberItem extends SettingsItem {
  const SettingsNumberItem({
    required super.id,
    required super.title,
    required this.value,
    required this.onChanged,
    this.resetValue,
    this.integer = false,
    this.min,
    this.max,
    this.suffixText,
    super.subtitle,
    super.icon,
    super.visible,
    super.reader,
    super.video,
  });

  final num Function(SettingsContext context) value;
  final SettingsValueChanged<num> onChanged;

  /// 非 null 时行尾提供重置按钮，点击把该值写回并回填输入框。
  final num Function(SettingsContext context)? resetValue;

  /// true = 整数输入（int 解析），false = 小数（double 解析）。
  final bool integer;

  /// 写穿前的夹取边界；null = 不限。
  final num? min;
  final num? max;

  /// 输入框尾缀单位文字（如 ms / px）。
  final String? suffixText;
}

class SettingsCustomItem extends SettingsItem {
  const SettingsCustomItem({
    required super.id,
    required this.builder,
    super.title = '',
    this.searchTitle,
    super.subtitle,
    super.icon,
    super.visible,
    super.reader,
    super.video,
  });

  final SettingsItemBuilder builder;

  /// 搜索元数据 opt-in：custom 行的 [title] 通常为空（正文由 [builder] 自绘），
  /// 默认不可搜。声明本字段后该行以此标题进入设置搜索（展平/打分/结果展示均用它，
  /// 见 settingsItemSearchTitle）；不影响渲染。
  final String? searchTitle;
}
