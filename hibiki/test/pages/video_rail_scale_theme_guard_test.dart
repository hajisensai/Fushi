import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（TODO-388 / TODO-604）：屏幕左 / 右浮动 rail 按钮吃「界面大小」+「主题」，
/// 与其它控件一致。
///
/// 历史回归：rail 按钮硬编码 `Colors.black` 背景 + `Colors.white` 图标，且 [IconButton]
/// 不传 `iconSize` → 永远默认 24px、既不随 appUiScale 缩放也不随主题色变（与底栏 / 顶栏 /
/// 侧边锁按钮不一致）。修复后图标尺寸走 [_videoControlIconSize]（base × _videoUiScale），
/// 背景走 [_videoChromeColorScheme] 的 `cs.surface`。
///
/// TODO-604：图标色从 `cs.onSurface`（中性前景）改为 `cs.primary`（主题强调色），与底栏 /
/// 顶栏按钮的 `buttonBarButtonColor: cs.primary` 同源——此前侧浮条按钮看上去「没吃到主题
/// 配色」、与底 / 顶栏不一致。
void main() {
  final File page =
      File('lib/src/pages/implementations/video_hibiki_page.dart');

  late String src;
  setUpAll(() {
    expect(page.existsSync(), isTrue, reason: '视频页源文件应存在');
    src = page.readAsStringSync();
  });

  String railForBody() {
    final int start = src.indexOf('Widget _buildVideoSideRailFor(');
    expect(start, greaterThan(0), reason: '应有 _buildVideoSideRailFor');
    final int end = src.indexOf('Widget _videoWithSubtitlePanel(', start);
    expect(end, greaterThan(start));
    return src.substring(start, end);
  }

  test('rail 图标尺寸走 _videoControlIconSize（吃 appUiScale，不再默认 24px）', () {
    final String body = railForBody();
    expect(body.contains('iconSize: _videoControlIconSize'), isTrue,
        reason:
            'rail IconButton 必须显式传 iconSize: _videoControlIconSize（吃缩放，TODO-388）');
  });

  test('rail 背景 / 图标走主题色（不再硬编码黑白）', () {
    final String body = railForBody();
    expect(body.contains('_videoChromeColorScheme(context)'), isTrue,
        reason: 'rail 应取 _videoChromeColorScheme（随主题着色）');
    expect(body.contains('cs.surface.withValues(alpha: 0.55)'), isTrue,
        reason: 'rail 背景应用主题 surface（与侧边锁按钮同源）');
    expect(body.contains('color: cs.primary'), isTrue,
        reason:
            'rail 图标应用主题强调色 cs.primary（与底 / 顶栏 buttonBarButtonColor 同源，TODO-604）');
    expect(body.contains('Colors.black.withValues(alpha: 0.42)'), isFalse,
        reason: 'rail 不应再硬编码黑色背景（TODO-388）');
    expect(body.contains('color: Colors.white'), isFalse,
        reason: 'rail 不应再硬编码白色图标（TODO-388）');
  });
}
