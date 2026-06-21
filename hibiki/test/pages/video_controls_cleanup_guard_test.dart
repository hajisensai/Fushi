import 'package:flutter_test/flutter_test.dart';
import 'video_hibiki_page_source_corpus.dart';

/// TODO-127 视频控制条清理源码守卫（随 TODO-274 控制条数据化重构刷新）。
///
/// media_kit 跑不了 headless，桌面/移动 controls 主题与菜单都难在 widget 测试里真实
/// 驱动，故把不变量锁在 `video_hibiki_page.dart` 的源码结构上：
/// ① 控制条不再放着色器对比按钮（C 快捷键 + 右键菜单 + `_toggleShaderCompare` 保留）。
/// ② 音轨 / 字幕源菜单可滚动——TODO-274 后这些菜单从 bottom sheet 迁到右侧
///    push-aside **side panel**（`_VideoSidePanelKind`），面板内容用可滚动
///    `ListView.builder`（不再裸 Column 堆 ListTile，否则长档位列表裁底）。
/// ③ 倍速入口回到底栏可配置按钮，但只打开紧凑锚点浮层（TODO-438），不回到挤占
///    顶栏/底栏的常驻宽控件，也不撑开右侧 side panel。
///
/// 注：旧 ④「字幕列表按钮在 topButtonBar 倒数第二」已随 BUG-248B / TODO-274 作废——
/// 设置（tune）与字幕列表按钮都已移出 topButtonBar，改由可配置的右侧 rail / 侧栏
/// （`VideoControlButton` 数据模型 + `_activateVideoControlButton`）承载，topButtonBar
/// 不再硬编码这两枚按钮，故该结构断言已删（详见 video_mobile_controls_static_test）。
void main() {
  final String src = readVideoHibikiSource();

  /// 桌面 + 移动两套 controls 主题方法体。TODO-274 把轨道菜单 `_showTrackMenu` 改名
  /// `_showAudioTrackMenu` 且移到 themes 之前，故控制条段终点改用 themes 之后紧邻的
  /// `_buildVideoControlButton`（仍夹住两套 controls 主题 + 其 topButtonBar/bottomBar）。
  String controlsThemes() {
    final int start = src.indexOf('MaterialDesktopVideoControlsThemeData');
    final int end = src.indexOf('Widget _buildVideoControlButton(');
    expect(start, greaterThanOrEqualTo(0), reason: '需有桌面 controls 主题起点');
    expect(end, greaterThan(start),
        reason: '需有 _buildVideoControlButton 作为 controls 段终点');
    return src.substring(start, end);
  }

  group('① 控制条无着色器对比按钮（保留 C / 右键 / _toggleShaderCompare）', () {
    String actionCallback(String field, String nextField) {
      final int start = src.indexOf('$field:');
      expect(start, greaterThanOrEqualTo(0), reason: '缺 $field 回调');
      final int end = src.indexOf('$nextField:', start);
      expect(end, greaterThan(start), reason: '缺 $field 回调终点 $nextField');
      return src.substring(start, end);
    }

    test('控制条不含 Icons.compare 按钮', () {
      expect(controlsThemes().contains('Icons.compare'), isFalse,
          reason: '着色器对比按钮应移出桌面 / 移动控制条');
    });
    test('_toggleShaderCompare 方法与 C 快捷键接线保留', () {
      expect(
          src.contains('Future<void> _toggleShaderCompare() async {'), isTrue,
          reason: '_toggleShaderCompare 方法必须保留（右键菜单 + 快捷键引用）');
      final String callback = actionCallback('toggleShaderCompare', 'volumeUp');
      final int gate = callback.indexOf('_runWhenImmersiveAllowsFullControls');
      final int toggle = callback.indexOf('_toggleShaderCompare()');
      expect(gate, greaterThanOrEqualTo(0),
          reason: 'C 快捷键 action 必须先走沉浸模式 full-controls gate');
      expect(toggle, greaterThan(gate),
          reason: 'C 快捷键 action 通过 gate 后必须调用 _toggleShaderCompare');
    });
  });

  group('② 音轨 / 字幕源菜单可滚动（TODO-274 迁到 side panel）', () {
    String panelBody(String startSig) {
      final int start = src.indexOf(startSig);
      expect(start, greaterThanOrEqualTo(0), reason: '需有 $startSig');
      // 各 side-panel builder 方法体到下一个方法/builder 之前。用 `\n  Widget ` /
      // `\n  Future` / `\n  void ` 作为下一成员边界的近似终点（取最近者）。
      final List<int> ends = <int>[
        src.indexOf('\n  Widget ', start + startSig.length),
        src.indexOf('\n  Future', start + startSig.length),
        src.indexOf('\n  void ', start + startSig.length),
        src.indexOf('\n  List<', start + startSig.length),
        src.indexOf('\n  double ', start + startSig.length),
      ].where((int i) => i > start).toList();
      final int end =
          ends.isEmpty ? src.length : ends.reduce((a, b) => a < b ? a : b);
      return src.substring(start, end);
    }

    test('音轨菜单是可滚动 ListView side panel（_buildAudioTracksSidePanel）', () {
      final String show = sourceMember(src, 'void _showAudioTrackMenu(');
      expect(show, contains('_VideoSidePanelKind.audioTracks'),
          reason: '音轨菜单走 side panel');
      expect(show, contains('sourceSlot: sourceSlot'),
          reason: '音轨菜单应把触发 slot 传给 side panel');
      final String body =
          panelBody('Widget _buildAudioTracksSidePanel(VideoPlayerController');
      expect(body.contains('ListView.builder('), isTrue,
          reason: '音轨面板须用可滚动 ListView.builder');
    });

    test('字幕源菜单是可滚动 side panel（_buildSubtitleSourcesSidePanel）', () {
      expect(
          RegExp(r'_showVideoSidePanel\(\s*_VideoSidePanelKind\.subtitleSources')
              .hasMatch(src),
          isTrue,
          reason: '字幕源菜单走 side panel');
      final String body = panelBody(
          'Widget _buildSubtitleSourcesSidePanel(VideoPlayerController');
      expect(body.contains('ListView.builder(') || body.contains('ListView('),
          isTrue,
          reason: '字幕源面板须可滚动（条目多时不裁底）');
    });
  });

  group('③ 倍速入口是紧凑浮层；无触发源时必须有可见 fallback', () {
    test('_showSpeedMenu 方法保留（右键菜单 / 可配置按钮引用）并按触发源选择可见路径', () {
      // TODO-560/BUG-325 起倍速入口要跟随触发按钮所在 slot，签名扩成
      // `{LayerLink? popoverLink, VideoControlSlot? sourceSlot}`；守卫只锁方法头前缀
      // （含 popoverLink 触发源形参），对未来追加形参鲁棒，不再硬编码闭合签名。
      const String speedMenuSig = 'void _showSpeedMenu({LayerLink? popoverLink';
      expect(src.contains(speedMenuSig), isTrue,
          reason: '_showSpeedMenu 方法必须保留（右键菜单 / 可配置按钮仍引用）');
      expect(
          RegExp(r'void _showSpeedMenu\(\{LayerLink\? popoverLink, '
                  r'VideoControlSlot\? sourceSlot\}\)')
              .hasMatch(src),
          isTrue,
          reason: 'BUG-325：倍速入口须接收触发 slot（sourceSlot）以让浮层跟随按钮');
      final String show = sourceMember(src, speedMenuSig);
      expect(
          RegExp(r'_toggleControlPopover\(\s*_VideoControlPopoverKind\.speed')
              .hasMatch(show),
          isTrue,
          reason: 'TODO-438：带触发源的倍速入口应打开或固定锚点轻浮层');
      expect(show.contains('if (popoverLink == null)'), isTrue,
          reason: '右键菜单等无锚点入口不能触发不可见 follower');
      expect(
          RegExp(r'_showVideoSidePanel\(\s*_VideoSidePanelKind\.speed')
              .hasMatch(show),
          isTrue,
          reason: '无触发源入口应保留可见 fallback，而不是打开无锚点浮层');
      expect(
          src.contains('item(Icons.speed, t.video_setting_speed, '
              '_showSpeedMenu)'),
          isTrue,
          reason: '右键菜单倍速项仍走 _showSpeedMenu');
    });
  });
}

String sourceMember(String src, String startSig) {
  final int start = src.indexOf(startSig);
  expect(start, greaterThanOrEqualTo(0), reason: '需有 $startSig');
  final List<int> ends = <int>[
    src.indexOf('\n  Widget ', start + startSig.length),
    src.indexOf('\n  Future', start + startSig.length),
    src.indexOf('\n  void ', start + startSig.length),
    src.indexOf('\n  List<', start + startSig.length),
    src.indexOf('\n  double ', start + startSig.length),
  ].where((int i) => i > start).toList();
  final int end =
      ends.isEmpty ? src.length : ends.reduce((int a, int b) => a < b ? a : b);
  return src.substring(start, end);
}
