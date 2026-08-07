import 'package:flutter/material.dart';
import 'package:fushi/src/focus/hibiki_focus_scroll.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/hibiki_design_tokens.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';

/// item 的可搜索标题：普通项就是 [SettingsItem.title]；[SettingsCustomItem]
/// 的 title 通常为空（正文由 builder 自绘），可用
/// [SettingsCustomItem.searchTitle] 显式 opt-in。空串 = 不可搜。
///
/// 给了 [context] 就走 [SettingsItem.resolveTitle]，让带 [SettingsItem.titleBuilder]
/// 的行（诊断分区那三条带实时计数的）在搜索结果里显示的标题与列表里那条一致。
String settingsItemSearchTitle(SettingsItem item, [SettingsContext? context]) {
  if (item is SettingsCustomItem) {
    final String? custom = item.searchTitle;
    if (custom != null && custom.isNotEmpty) return custom;
  }
  return context == null ? item.title : item.resolveTitle(context);
}

/// 设置搜索的一条可命中条目（已展平：分类 → 分区 → 配置项）。
class SettingsSearchEntry {
  const SettingsSearchEntry({
    required this.destination,
    required this.item,
    this.sectionTitle,
    this.isBodyEntry = false,
    String? resolvedTitle,
  }) : _resolvedTitle = resolvedTitle;

  /// 展平时就地求好的标题（带 [SettingsItem.titleBuilder] 的行才有意义）。
  final String? _resolvedTitle;

  final SettingsDestination destination;
  final String? sectionTitle;
  final SettingsItem item;

  /// true = 由 [SettingsDestination.bodySearchEntries] 合成（body 逃生口正文
  /// 里的行）。命中后只跳转分类，不登记滚动定位挂点——body 行不是 schema item，
  /// 挂点永远不会被消费。
  final bool isBodyEntry;

  /// 打分与结果展示用的标题（custom 项取 searchTitle，见
  /// [settingsItemSearchTitle]）。
  String get title => _resolvedTitle ?? settingsItemSearchTitle(item);
}

/// 搜索结果副标题的「分类 › 分区」面包屑（框架级去重）。
///
/// 当分区标题为空、或与所属 destination 标题相同（如「系统」destination 里一个
/// 同名「系统」section），只显示 destination 标题，消灭「系统 › 系统」这一整类
/// 语义重复——而不是逐个改命名。分区名有独立含义时才拼成「分类 › 分区」。
String settingsSearchBreadcrumb(SettingsSearchEntry entry) {
  final String destination = entry.destination.title;
  final String? section = entry.sectionTitle;
  if (section == null || section.isEmpty || section == destination) {
    return destination;
  }
  return '$destination › $section';
}

/// 把当前可见的 schema 展平成搜索条目列表。
///
/// 只收有可搜索标题的项（见 [settingsItemSearchTitle]：custom 项默认 title 为空
/// 跳过，声明 searchTitle 后进入索引）。可见性用与渲染完全相同的
/// [SettingsDestination.visibleSections] 谓词求值，搜索结果绝不会指向一个
/// 当前平台/状态下根本不显示的行。
List<SettingsSearchEntry> flattenVisibleSettings(
  List<SettingsDestination> destinations,
  SettingsContext context,
) {
  final List<SettingsSearchEntry> entries = <SettingsSearchEntry>[];
  for (final SettingsDestination destination in destinations) {
    if (!destination.isVisible(context)) continue;
    for (final SettingsSection section
        in destination.visibleSections(context)) {
      for (final SettingsItem item in section.items) {
        final String title = settingsItemSearchTitle(item, context);
        if (title.isEmpty) continue;
        entries.add(SettingsSearchEntry(
          destination: destination,
          sectionTitle: section.title,
          item: item,
          resolvedTitle: title,
        ));
      }
    }
    // body 逃生口正文（如「制卡」的 AnkiSettingsBody）不走 sections，索引器
    // 看不见其中的行；把 destination 声明的 bodySearchEntries 合成为普通搜索
    // 条目（复用 custom 项的 searchTitle 通道），命中后跳转到该分类正文。
    for (final SettingsBodySearchEntry bodyEntry
        in destination.bodySearchEntries) {
      if (!bodyEntry.isVisible(context)) continue;
      entries.add(SettingsSearchEntry(
        destination: destination,
        item: SettingsCustomItem(
          id: bodyEntry.id,
          searchTitle: bodyEntry.title,
          subtitle: bodyEntry.subtitle,
          builder: (_) => const SizedBox.shrink(),
        ),
        isBodyEntry: true,
      ));
    }
  }
  return entries;
}

/// 纯过滤：大小写不敏感子串匹配，命中位置决定排序权重
/// （标题前缀 < 标题包含 < 副标题/分区/分类包含），稳定排序保持 schema 原序。
List<SettingsSearchEntry> filterSettingsEntries(
  List<SettingsSearchEntry> entries,
  String query, {
  int maxResults = 50,
}) {
  final String q = query.trim().toLowerCase();
  if (q.isEmpty) return const <SettingsSearchEntry>[];

  int scoreOf(SettingsSearchEntry e) {
    final String title = e.title.toLowerCase();
    if (title.startsWith(q)) return 0;
    if (title.contains(q)) return 1;
    final String haystack = <String?>[
      e.item.subtitle,
      e.sectionTitle,
      e.destination.title,
    ].whereType<String>().join('\n').toLowerCase();
    if (haystack.contains(q)) return 2;
    return -1;
  }

  final List<(int, SettingsSearchEntry)> scored =
      <(int, SettingsSearchEntry)>[];
  for (final SettingsSearchEntry e in entries) {
    final int score = scoreOf(e);
    if (score >= 0) scored.add((score, e));
  }
  // List.sort 不稳定；按 (score, 原始下标) 排序保证同分保持 schema 顺序。
  final List<int> order = List<int>.generate(scored.length, (int i) => i);
  order.sort((int a, int b) {
    final int byScore = scored[a].$1.compareTo(scored[b].$1);
    return byScore != 0 ? byScore : a.compareTo(b);
  });
  return <SettingsSearchEntry>[
    for (final int i in order.take(maxResults)) scored[i].$2,
  ];
}

/// 跨页面传递「进入详情后要滚到并高亮哪一项」的一次性挂点。
///
/// 搜索结果点击时写入目标 item id；目标行随后在任意详情容器里被
/// [SettingsSchemaItem] 构建时消费（包上 [SettingsRevealTarget] 滚动定位 +
/// 短暂高亮），消费即清除。模块级单槽足够：同一时刻只可能有一个"跳转中"的
/// 目标，且消费点唯一。
class SettingsSearchReveal {
  SettingsSearchReveal._();

  static String? pendingItemId;
}

/// 搜索跳转的落点包装：首帧后把自己滚进视口（滚动统一委托 HibikiFocusScroll——
/// 焦点架构守卫禁止 lib/src 各处自持 ensureVisible 实现；非懒详情容器里恒可用，
/// 见 material renderer 的 SingleChildScrollView 契约），并用主题色短暂闪烁一次
/// 帮助用户锁定视线。
class SettingsRevealTarget extends StatefulWidget {
  const SettingsRevealTarget({super.key, required this.child});

  final Widget child;

  @override
  State<SettingsRevealTarget> createState() => _SettingsRevealTargetState();
}

class _SettingsRevealTargetState extends State<SettingsRevealTarget> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // eink 下滚动动画归零（连续重绘=残影），直接跳到目标位置。
      HibikiFocusScroll.ensureVisible(
        context,
        duration: einkSafeDuration(context, const Duration(milliseconds: 250)),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final Color highlight = Theme.of(context).colorScheme.primary;
    // MD3 守卫：圆角一律走 design tokens，不自持字面量。
    final BorderRadius radius =
        HibikiDesignTokens.of(context).radii.controlRadius;
    // eink 下闪烁衰减动画归零：TweenAnimationBuilder duration zero 直接落在
    // end（透明），不闪不残影；定位仍由上面的滚动完成。
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 1, end: 0),
      duration: einkSafeDuration(context, const Duration(milliseconds: 1400)),
      curve: Curves.easeOut,
      child: widget.child,
      builder: (BuildContext context, double value, Widget? child) {
        return DecoratedBox(
          decoration: BoxDecoration(
            color: highlight.withValues(alpha: 0.14 * value),
            borderRadius: radius,
          ),
          child: child,
        );
      },
    );
  }
}
