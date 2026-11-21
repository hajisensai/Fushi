// 首页「媒体库全景」小组件：旧面板的自动档（不显示）在迁移时的落点与冻结 id。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/home_dashboard_panel.dart';
import 'package:fushi/src/models/home_widget_layout.dart';

void main() {
  bool placed(HomeDashboardPanelMode? mode) => migrateHomeWidgetLayout(
    grid: HomeGridKind.compact,
    modes: <HomeDashboardPanel, HomeDashboardPanelMode>{
      if (mode != null) HomeDashboardPanel.panorama: mode,
    },
    auto: const HomeWidgetAutoFacts(),
  ).any((HomeWidgetItem e) => e.kind == HomeWidgetKind.panorama);

  test('旧显示档：自动 / 钉了隐藏 → 首个布局不放；钉了显示 → 放上', () {
    expect(placed(null), isFalse);
    expect(placed(HomeDashboardPanelMode.auto), isFalse);
    expect(placed(HomeDashboardPanelMode.hidden), isFalse);
    expect(placed(HomeDashboardPanelMode.shown), isTrue);
  });

  test('组件 id 与旧面板 id 冻结；旧显示档能读出', () {
    expect(HomeWidgetKind.panorama.id, 'panorama');
    expect(HomeDashboardPanel.panorama.id, 'library_panorama');
    expect(
      decodeHomeDashboardPanelModes('{"library_panorama":"shown"}'),
      <HomeDashboardPanel, HomeDashboardPanelMode>{
        HomeDashboardPanel.panorama: HomeDashboardPanelMode.shown,
      },
    );
  });
}
