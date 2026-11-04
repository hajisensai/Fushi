/// 浏览页的快捷视图（内置五个，带计数）与用户保存的视图（名字 + 查询，存 profile 偏好
/// `srs_browse_saved_views`，随 Profile 快照 / 备份走，不进复习同步）。
///
/// 计数一次 `browse_counts`（[SrsBrowseSession.counts]）算完：快捷视图 + 保存的视图 + 健康条用的几条
/// 查询拼成一次调用，见浏览页 `_refreshCounts`。
library;

import 'dart:convert';

import 'package:fushi_engine/srs/srs_browse.dart' show srsFieldContainsQuery;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/srs/srs_browse_query.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart';

/// 用户保存的一个视图。
@immutable
class SrsBrowseSavedView {
  const SrsBrowseSavedView({required this.name, required this.query});

  final String name;
  final String query;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'query': query,
  };

  @override
  bool operator ==(Object other) =>
      other is SrsBrowseSavedView && other.name == name && other.query == query;

  @override
  int get hashCode => Object.hash(name, query);
}

/// 偏好值 → 保存的视图。读不出 / 形状不对的条目跳过（不因一条坏数据丢掉全部）。
List<SrsBrowseSavedView> decodeSrsBrowseSavedViews(String raw) {
  if (raw.trim().isEmpty) return const <SrsBrowseSavedView>[];
  final Object? json;
  try {
    json = jsonDecode(raw);
  } on FormatException {
    return const <SrsBrowseSavedView>[];
  }
  if (json is! List) return const <SrsBrowseSavedView>[];
  return <SrsBrowseSavedView>[
    for (final Object? e in json)
      if (e is Map &&
          e['name'] is String &&
          e['query'] is String &&
          (e['name']! as String).trim().isNotEmpty)
        SrsBrowseSavedView(
          name: e['name']! as String,
          query: e['query']! as String,
        ),
  ];
}

/// 保存的视图 → 偏好值。
String encodeSrsBrowseSavedViews(List<SrsBrowseSavedView> views) =>
    views.isEmpty
    ? ''
    : jsonEncode(<Object?>[
        for (final SrsBrowseSavedView v in views) v.toJson(),
      ]);

/// 内置快捷视图。
enum SrsBrowseQuickView { due, recent, hard, problems, suspended }

/// 快捷视图的条件（[fushiNoteTypeName]：内置 Fushi 卡片类型的名字；null = 库里没有这个类型，「问题卡」只看
/// 主字段为空）。问题卡里的缺音频只判 Fushi 卡片（spec §2.3：其它类型本来就未必有音频字段）。
String srsBrowseQuickViewQuery(
  SrsBrowseQuickView view, {
  required String? fushiNoteTypeName,
}) => switch (view) {
  SrsBrowseQuickView.due => 'is:due',
  SrsBrowseQuickView.recent => 'added:7',
  SrsBrowseQuickView.hard => kSrsBrowseHealthHardQuery,
  SrsBrowseQuickView.problems =>
    fushiNoteTypeName == null
        ? 'is:emptyfield'
        : '(is:emptyfield or (-has:audio ${srsBrowseNoteTypeTerm(fushiNoteTypeName)}))',
  SrsBrowseQuickView.suspended => 'is:suspended',
};

/// `note:"名字"`（转义与 [srsFieldContainsQuery] 同一规则：名字按字面量匹配）。
String srsBrowseNoteTypeTerm(String name) => 'note:"${srsBrowseLiteral(name)}"';

/// 「主字段为空」的条件（健康条的分项计数与「查看」套用的筛选：同一条件、按笔记数）。
const String kSrsBrowseHealthEmptyQuery = 'is:emptyfield';

/// 「难卡：遗忘 ≥ 4 次」的条件（健康条与快捷视图「难卡」共用）。
const String kSrsBrowseHealthHardQuery = 'prop:lapses>=4';

/// 「疑似重复」的条件（健康条的分项计数与「查看」套用的筛选）。
const String kSrsBrowseHealthDupesQuery = 'is:dupe';

/// 「Fushi 笔记缺单词音频」的条件（健康条的分项计数与「查看」套用的筛选）。
String srsBrowseMissingAudioQuery(String fushiNoteTypeName) =>
    '-has:audio ${srsBrowseNoteTypeTerm(fushiNoteTypeName)}';

/// 快捷视图的文字。
String srsBrowseQuickViewLabel(SrsBrowseQuickView view) => switch (view) {
  SrsBrowseQuickView.due => t.srs_browse_quick_due,
  SrsBrowseQuickView.recent => t.srs_browse_quick_recent,
  SrsBrowseQuickView.hard => t.srs_browse_quick_hard,
  SrsBrowseQuickView.problems => t.srs_browse_quick_problems,
  SrsBrowseQuickView.suspended => t.srs_browse_quick_suspended,
};

/// 快捷视图的图标。
IconData srsBrowseQuickViewIcon(SrsBrowseQuickView view) => switch (view) {
  SrsBrowseQuickView.due => FushiIcons.schedule,
  SrsBrowseQuickView.recent => FushiIcons.libraryAdd,
  SrsBrowseQuickView.hard => FushiIcons.speed,
  SrsBrowseQuickView.problems => FushiIcons.warning,
  SrsBrowseQuickView.suspended => FushiIcons.pauseCircle,
};

/// 套用快捷视图：留下牌组积木（从牌组菜单进来带的范围），其余条件换成 [view] 的；[view] 已经套着时
/// 再点一次 = 撤掉它的条件。
List<SrsBrowseChip> srsBrowseToggleQuickView(
  List<SrsBrowseChip> chips,
  List<SrsBrowseChip> view,
) {
  if (srsBrowseChipsContain(chips, view)) {
    return <SrsBrowseChip>[
      for (final SrsBrowseChip c in chips)
        if (!view.contains(c)) c,
    ];
  }
  return <SrsBrowseChip>[
    for (final SrsBrowseChip c in chips)
      if (c.kind == SrsBrowseChipKind.deck) c,
    ...view,
  ];
}

/// 视图条上的一项（内置或保存的）。
class SrsBrowseViewEntry {
  const SrsBrowseViewEntry({
    required this.id,
    required this.label,
    required this.icon,
    required this.selected,
    required this.count,
    required this.onTap,
    this.onMenu,
  });

  final String id;
  final String label;
  final IconData icon;
  final bool selected;

  /// 命中数；null = 还没算出来 / 查询不合法（-1）。
  final int? count;
  final VoidCallback onTap;

  /// 长按 / 右键（保存的视图：重命名 / 删除）。
  final VoidCallback? onMenu;
}

/// 快捷视图条：横向滚动的一排过滤胶囊（「今天到期 · 47」）。
class SrsBrowseViewStrip extends StatelessWidget {
  const SrsBrowseViewStrip({super.key, required this.entries});

  final List<SrsBrowseViewEntry> entries;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return SingleChildScrollView(
      key: const ValueKey<String>('srs-browse-views'),
      scrollDirection: Axis.horizontal,
      child: Row(
        spacing: tokens.spacing.gap,
        children: <Widget>[
          for (final SrsBrowseViewEntry e in entries)
            FushiPressScale(
              child: GestureDetector(
                onLongPress: e.onMenu,
                onSecondaryTap: e.onMenu,
                child: FushiFilterChip(
                  key: ValueKey<String>('srs-browse-view-${e.id}'),
                  avatar: FushiIcon(e.icon, size: 18),
                  showCheckmark: false,
                  selected: e.selected,
                  label: Text(
                    e.count == null ? e.label : '${e.label} · ${e.count}',
                  ),
                  onSelected: (_) => e.onTap(),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 存为视图：问名字。返回 null = 取消。
Future<String?> askSrsBrowseViewName(
  BuildContext context, {
  String? initial,
  required String title,
}) => showFushiTextInputDialog(
  context: context,
  title: title,
  hintText: t.srs_browse_view_name,
  initialValue: initial ?? '',
  icon: FushiIcons.bookmarkAdd,
);
