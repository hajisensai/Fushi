import 'package:flutter_test/flutter_test.dart';
import 'video_hibiki_page_source_corpus.dart';

/// BUG-370 源码守卫：视频就绪（`_applyLoad` 成功 setState）后必须重申沉浸隐藏系统栏
/// （移动端 `_applyVideoImmersiveMode`）。
///
/// 根因：沉浸模式在 `initState` 只申一次，而**远端视频**要先 await 网络流地址 + 下字幕
/// 才 load，controller 就绪得晚——若 immersiveSticky 在等待期被系统/用户触屏临时唤回
/// 导航栏，首个带进度条的帧会读到非零 `MediaQuery.viewPadding.bottom`
/// （`_videoBottomSystemInset`），把进度条/字幕整体抬高（本地 load 快、过了窗口故正常）。
/// 修复：controller 就绪即重隐导航栏，让 inset 回零、几何归位。对称惠及本地远端。
///
/// media_kit + 真实播放跑不了 headless，故锁源码结构不变量。
void main() {
  late String src;
  setUpAll(() {
    src = readVideoHibikiSource();
  });

  test('_applyLoad 成功 setState 后重申 _applyVideoImmersiveMode', () {
    // 锚 _applyLoad 成功路径的 setState 块到方法尾部一带，断言其中重申沉浸模式。
    final int setStateIdx = src.indexOf('_failed = false;');
    expect(setStateIdx, greaterThanOrEqualTo(0),
        reason: '需有 _applyLoad 成功路径的 _failed = false');
    final int refocusIdx = src.indexOf('_refocusVideo();', setStateIdx);
    expect(refocusIdx, greaterThan(setStateIdx),
        reason: '需有就绪后的 _refocusVideo 锚点');
    // 重申沉浸模式应紧随就绪 setState / refocus 之后、在窗口纵横比同步之前。
    final int immersiveIdx =
        src.indexOf('unawaited(_applyVideoImmersiveMode());', refocusIdx);
    expect(immersiveIdx, greaterThan(refocusIdx),
        reason: 'BUG-370：视频就绪后必须重申 _applyVideoImmersiveMode（远端 inset 归位）');
    final int aspectLockIdx =
        src.indexOf('_syncWindowAspectRatioLock();', refocusIdx);
    expect(aspectLockIdx, greaterThan(immersiveIdx),
        reason: '重申沉浸模式应在就绪后、窗口纵横比同步前');
  });
}
