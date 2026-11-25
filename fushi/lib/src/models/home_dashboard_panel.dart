/// 旧首页 dashboard 的「可选面板」显示档（只读，迁移用）。
///
/// 2026-11-15 首页改成小组件网格（`home_widget_layout.dart`）后，这份偏好不再写、
/// 不再影响渲染；只在用户从没编辑过首页布局时，由 `migrateHomeWidgetLayout` 读它
/// 生成首个布局：钉成 hidden 的面板不放、钉成 shown 的放上、auto 的按面板当时的
/// 默认判据算一次。
///
/// 持久化：偏好 `home_dashboard_panels` 存一个 JSON map `{面板 id: 档位 wire}`，
/// 缺省 = auto。面板 id（[HomeDashboardPanel.id]）与档位 wire 冻结不追改。
library;

import 'dart:convert';

/// 一个旧可选首页面板。
enum HomeDashboardPanel {
  /// Fushi 复习（内置 SRS）入口条：今日待复习计数 + 「开始复习」。
  ///
  /// 自动档判据（`home_srs_panel.dart` 的 `homeSrsAutoDefault`）：复习模块开着，
  /// 且（挖词目标 = Fushi 复习 或 库里已有复习卡）。制卡仍发 Anki、也没有复习卡的
  /// 存量用户首个布局里不放（用户拍板：老用户不提醒）。
  srsReview('srs_review'),

  /// Tracking strip (Bangumi and tracking plugin sites). Automatic rule:
  /// only while something needs the user (a title to link, a failed send, a
  /// site that wants a new sign-in), `HomeTrackingSummary.needsAttention`.
  tracking('tracking'),

  /// AI 助手入口条（spec 2026-10-26 D4 ①）。自动档判据：AI 模块开着且给「AI 助手」
  /// 指派了可用的提供商（`resolveHomeAiAgentAutoDefault`）。
  aiAgent('ai_agent'),

  /// 媒体库全景（需求 2026-10-29）。自动档 = 不显示（2026-10-30），钉成显示才放。
  panorama('library_panorama');

  const HomeDashboardPanel(this.id);

  /// 持久化 id（冻结）。
  final String id;
}

/// 面板显示档：自动（面板自己的默认判据）/ 始终显示 / 始终隐藏。
enum HomeDashboardPanelMode {
  auto('auto'),
  shown('shown'),
  hidden('hidden');

  const HomeDashboardPanelMode(this.wire);

  /// 持久化值（冻结）。
  final String wire;

  /// 未知值 / null = [auto]。
  static HomeDashboardPanelMode fromWire(Object? wire) {
    for (final HomeDashboardPanelMode m in HomeDashboardPanelMode.values) {
      if (m.wire == wire) return m;
    }
    return HomeDashboardPanelMode.auto;
  }
}

/// 解出偏好里的显示档；坏 JSON / 未知面板 / 未知档位一律忽略（= auto）。
Map<HomeDashboardPanel, HomeDashboardPanelMode> decodeHomeDashboardPanelModes(
  String json,
) {
  final Map<HomeDashboardPanel, HomeDashboardPanelMode> out =
      <HomeDashboardPanel, HomeDashboardPanelMode>{};
  if (json.isEmpty) return out;
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return out;
  }
  if (decoded is! Map) return out;
  for (final HomeDashboardPanel panel in HomeDashboardPanel.values) {
    final HomeDashboardPanelMode mode = HomeDashboardPanelMode.fromWire(
      decoded[panel.id],
    );
    if (mode != HomeDashboardPanelMode.auto) out[panel] = mode;
  }
  return out;
}
