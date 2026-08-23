import 'package:flutter_test/flutter_test.dart';

import 'video_fushi_page_source_corpus.dart';

/// 源码守卫（BUG-106）：控制条自动隐藏时，鼠标光标也应隐藏。
/// media_kit 的 `MaterialDesktopVideoControlsThemeData.hideMouseOnControlsRemoval`
/// 默认 false（光标常驻）；必须显式设 true。media_kit headless 不可跑视频 widget，
/// 故在源码层钉死。
///
/// 源码守卫（TODO-056）：无操作后控制条自动隐藏的延迟（media_kit
/// `controlsHoverDuration`，默认 3 秒偏长）必须显式设成 2 秒。桌面与移动两套主题
/// 都要钉，全屏路由复用窗口侧主题实例故一并生效。
void main() {
  test('desktop controls theme hides mouse on controls removal (BUG-106)', () {
    // TODO-590 batch11：两套 controls 主题已搬到 controls_theme.part.dart，改读合并语料。
    // BUG-391 r4/r5（提交 1fc54c75a / f83d590e4）：桌面 theme 的
    // hideMouseOnControlsRemoval 从字面 `true` 改为
    // `!(_subtitleListVisible.value || _episodeListVisible.value)`——push-aside 字幕 /
    // 选集列表打开时不隐藏视频列光标（从源头消除跨列 none→basic 竞态），其余时间仍
    // 隐藏（默认 = true，保 BUG-106）。故守卫从字面 `: true` 收紧为「绑这两个列表
    // notifier 的否定表达式」，既钉住 BUG-106 默认隐藏语义，又钉住 BUG-391 的列表豁免。
    // BUG-1798：豁免项从两项变三项（查词浮层 [_lookupOverlayActive] 加入）。本守卫改为
    // **锁语义不锁字面**——断言「是 `!( ... )` 否定表达式」+「两个列表 notifier 都在里面」，
    // 不再要求豁免项恰好是那两个、也不再要求它们的排列顺序。否则每加一个正当豁免项都要
    // 改一次守卫，而守卫真正要守的是「默认隐藏 + 这两个列表必须豁免」这两条语义。
    final String src = readVideoFushiSource();
    final RegExp negatedExpr = RegExp(
      r'hideMouseOnControlsRemoval:\s*!\(([\s\S]*?)\),',
    );
    final RegExpMatch? m = negatedExpr.firstMatch(src);
    expect(m, isNotNull,
        reason: '桌面控制条隐藏时默认一并隐藏光标（BUG-106），'
            '取值必须是 `!( 豁免条件 )` 形式，仅在豁免条件成立时才不隐藏');
    final String exemptions = m!.group(1)!.replaceAll(RegExp(r'\s+'), '');
    expect(exemptions.contains('_subtitleListVisible.value'), isTrue,
        reason: 'BUG-391：字幕列表 push-aside 侧栏开启时必须豁免');
    expect(exemptions.contains('_episodeListVisible.value'), isTrue,
        reason: 'BUG-391 r5：选集列表与字幕列表机理相同，必须一并豁免');
    // 反向钉死：不得退回字面 `: true`（那会让 push-aside 列表开时仍隐藏光标，回归 BUG-391）。
    expect(src.contains('hideMouseOnControlsRemoval: true'), isFalse,
        reason: 'BUG-391：列表开时必须豁免，不能用字面 true');
  });

  test('controls auto-hide delay is 2 seconds in both themes (TODO-056)', () {
    // TODO-590 batch11：两套 controls 主题已搬到 controls_theme.part.dart，改读合并语料。
    final String src = readVideoFushiSource();
    // 桌面 + 移动两套主题各显式设 controlsHoverDuration = 2 秒。
    final int count = RegExp(
      r'controlsHoverDuration: const Duration\(seconds: 2\)',
    ).allMatches(src).length;
    expect(count, 2, reason: '桌面与移动控制主题都必须把自动隐藏延迟设成 2 秒（TODO-056）');
  });
}
