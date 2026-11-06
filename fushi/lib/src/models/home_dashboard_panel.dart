/// 首页 dashboard 的「可选面板」注册表。
///
/// 首页的固定分区（今日 / 继续 / 最近添加 / 同步卡）不在这里：它们恒在，或由
/// 功能模块开关整体门控。这里登记的是**按用户情况才出现**的面板——每个面板有
/// 自己的默认判据（[HomeDashboardPanelMode.auto]），用户可以在 设置 › 外观 ›
/// 首页面板 里把它钉成显示 / 隐藏。
///
/// 持久化：偏好 `home_dashboard_panels` 存一个 JSON map `{面板 id: 档位 wire}`，
/// 缺省 = auto。面板 id（[HomeDashboardPanel.id]）与档位 wire 冻结不追改。
library;

import 'dart:convert';

/// 一个可选的首页面板。顺序 = 设置页「首页面板」分区的展示顺序。
enum HomeDashboardPanel {
  /// Fushi 复习（内置 SRS）入口条：今日待复习计数 + 「开始复习」。
  ///
  /// 默认判据（见 `home_srs_panel.dart` 的 `resolveHomeSrsPanelVisible`）：复习
  /// 模块开着，且（挖词目标 = Fushi 复习 或 库里已有复习卡）。制卡仍发 Anki、也
  /// 没有复习卡的存量用户首页不多这一栏（用户拍板：老用户不提醒）。
  srsReview('srs_review'),

  /// AI 助手入口条（spec 2026-10-26 D4 ①）：点了打开 AI 浮层。默认判据（见
  /// `home_ai_agent_panel.dart` 的 `resolveHomeAiAgentPanelVisible`）：AI 模块开着且
  /// 给「AI 助手」指派了可用的提供商。
  aiAgent('ai_agent'),

  /// 媒体库全景（需求 2026-10-29）：全部作品封面与制卡词组成的可操作 3D 球幕，附分享用
  /// 16 秒开场动画。默认判据（`home_panorama_panel.dart` 的
  /// `resolveHomePanoramaPanelVisible`）：默认不显示（2026-10-30），钉成显示才出现；
  /// 空库时面板里给引导语。
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

/// 编码显示档；auto 不落盘（缺省即 auto）。
String encodeHomeDashboardPanelModes(
  Map<HomeDashboardPanel, HomeDashboardPanelMode> modes,
) {
  final Map<String, String> out = <String, String>{
    for (final MapEntry<HomeDashboardPanel, HomeDashboardPanelMode> e
        in modes.entries)
      if (e.value != HomeDashboardPanelMode.auto) e.key.id: e.value.wire,
  };
  return out.isEmpty ? '' : jsonEncode(out);
}
