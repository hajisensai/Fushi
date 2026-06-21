import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

/// 源码守卫（TODO-388 / TODO-604 / TODO-635）：屏幕左 / 右浮动 rail 按钮吃「界面大小」+「主题」，
/// 与其它控件一致。
///
/// 历史回归：rail 按钮硬编码 `Colors.black` 背景 + `Colors.white` 图标，且 [IconButton]
/// 不传 `iconSize` → 永远默认 24px、既不随 appUiScale 缩放也不随主题色变（与底栏 / 顶栏 /
/// 侧边锁按钮不一致）。修复后图标尺寸走 [_videoControlIconSize]（base × _videoUiScale），
/// 图标色走 [_videoChromeColorScheme] 的 `cs.primary`。
///
/// TODO-635：用户要求去掉 rail 按钮外层圆形半透明背景（`Material(surface@0.55)`），
/// 只留裸图标浮在画面上（IconButton 自带 InkWell 涟漪，不丢点击反馈）。守卫断言 rail
/// 体内不再有 surface@0.55 的 Material 圆底 / CircleBorder。
///
/// TODO-604：图标色从 `cs.onSurface`（中性前景）改为 `cs.primary`（主题强调色），与底栏 /
/// 顶栏按钮的 `buttonBarButtonColor: cs.primary` 同源——此前侧浮条按钮看上去「没吃到主题
/// 配色」、与底 / 顶栏不一致。
void main() {
  // TODO-590 batch16: _buildVideoSideRailFor / _videoWithSubtitlePanel 都已搬到
  // video_hibiki/layout.part.dart，故读「主壳 + 全部 part」合并语料；两锚点在 part 内相邻
  // （中间仅夹 _mergeRailSafeAreaPadding），合并语料保持原顺序，rail 体切片范围不变。
  late String src;
  setUpAll(() {
    src = readVideoHibikiSource();
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

  test('rail 图标走主题强调色（不再硬编码黑白）', () {
    final String body = railForBody();
    expect(body.contains('_videoChromeColorScheme(context)'), isTrue,
        reason: 'rail 应取 _videoChromeColorScheme（随主题着色）');
    expect(body.contains('color: cs.primary'), isTrue,
        reason:
            'rail 图标应用主题强调色 cs.primary（与底 / 顶栏 buttonBarButtonColor 同源，TODO-604）');
    expect(body.contains('Colors.black.withValues(alpha: 0.42)'), isFalse,
        reason: 'rail 不应再硬编码黑色背景（TODO-388）');
    expect(body.contains('color: Colors.white'), isFalse,
        reason: 'rail 不应再硬编码白色图标（TODO-388）');
  });

  // TODO-635：去掉 rail 按钮外层圆形半透明 `Material(surface@0.55)` 背景，只留裸
  // 图标浮在画面上（IconButton 自带 InkWell 涟漪，不丢点击反馈）。防回潮守卫：rail
  // 体内不得再出现 surface@0.55 的 Material 圆底，也不得用 CircleBorder 圆形容器。
  test('TODO-635：rail 按钮无 surface@0.55 圆形 Material 背景', () {
    final String body = railForBody();
    expect(body.contains('cs.surface.withValues(alpha: 0.55)'), isFalse,
        reason: 'TODO-635：rail 按钮不应再包 surface@0.55 的 Material 圆底（用户要求去背景）');
    expect(body.contains('shape: const CircleBorder()'), isFalse,
        reason: 'TODO-635：rail 按钮不应再用 CircleBorder 圆形背景容器');
  });
}
