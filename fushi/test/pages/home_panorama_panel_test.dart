// 首页「媒体库全景」面板（HomeDashboardPanel.panorama）：显隐判据与持久化 id。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/home_dashboard_panel.dart';
import 'package:fushi/src/pages/implementations/home_panorama_panel.dart';

void main() {
  test('默认（自动）/ 钉了隐藏：不出；钉了显示：出', () {
    expect(
      resolveHomePanoramaPanelVisible(mode: HomeDashboardPanelMode.auto),
      isFalse,
    );
    expect(
      resolveHomePanoramaPanelVisible(mode: HomeDashboardPanelMode.shown),
      isTrue,
    );
    expect(
      resolveHomePanoramaPanelVisible(mode: HomeDashboardPanelMode.hidden),
      isFalse,
    );
  });

  test('面板 id 冻结、能往返持久化', () {
    expect(HomeDashboardPanel.panorama.id, 'library_panorama');
    final String json = encodeHomeDashboardPanelModes(
      <HomeDashboardPanel, HomeDashboardPanelMode>{
        HomeDashboardPanel.panorama: HomeDashboardPanelMode.hidden,
      },
    );
    expect(json, '{"library_panorama":"hidden"}');
    expect(
      decodeHomeDashboardPanelModes(json),
      <HomeDashboardPanel, HomeDashboardPanelMode>{
        HomeDashboardPanel.panorama: HomeDashboardPanelMode.hidden,
      },
    );
  });
}
