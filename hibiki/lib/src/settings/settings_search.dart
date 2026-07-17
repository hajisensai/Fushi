import 'package:flutter/material.dart';
import 'package:hibiki/src/focus/hibiki_focus_scroll.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';

/// 设置搜索的一条可命中条目（已展平：分类 → 分区 → 配置项）。
class SettingsSearchEntry {
  const SettingsSearchEntry({
    required this.destination,
    required this.item,
    this.sectionTitle,
  });

  final SettingsDestination destination;
  final String? sectionTitle;
  final SettingsItem item;
}

/// 把当前可见的 schema 展平成搜索条目列表。
///
/// 只收带标题的项（[SettingsCustomItem] 通常 title 为空，无文本可匹配，跳过——
/// 自定义 selector 行的可发现性仍靠其所在分类）。可见性用与渲染完全相同的
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
        if (item.title.isEmpty) continue;
        entries.add(SettingsSearchEntry(
          destination: destination,
          sectionTitle: section.title,
          item: item,
        ));
      }
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
    final String title = e.item.title.toLowerCase();
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
      HibikiFocusScroll.ensureVisible(
        context,
        duration: const Duration(milliseconds: 250),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final Color highlight = Theme.of(context).colorScheme.primary;
    // MD3 守卫：圆角一律走 design tokens，不自持字面量。
    final BorderRadius radius =
        HibikiDesignTokens.of(context).radii.controlRadius;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 1, end: 0),
      duration: const Duration(milliseconds: 1400),
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
