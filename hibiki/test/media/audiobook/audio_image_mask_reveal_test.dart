import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-682 / TODO-1367 回归守卫（源码扫描）：有声书音频跟随读过某张图时，必须真正
/// 去掉该图的防剧透模糊遮罩（`blurred` 类），且揭开要持久（章节重载 / 布局切换不再
/// 重新遮罩）、对尚未 load 的懒图也生效。
///
/// 用户报「音频遇到图片没暂停，也没把图片遮罩去掉」。图片暂停判据（`__hoshiImageBetween`
/// + `onImageDetected`）本身健壮（对懒图也命中，BUG-007 契约）；真正失效的是揭遮罩：
/// 旧实现只 `querySelectorAll('img.blurred')` + `classList.remove`，两处根因——
///   ① 区间内插图常是 `loading=lazy` 离屏图，cue 跨过它时它还没 load、还没被
///      `_hoshiClassifyBlockImg` 加 `blurred` 类 -> 选择器抓不到 -> 随后图片暂停滚到它、
///      它才 load，`_hoshiBlurImage` 见 key 不在活集 -> 补加 `blurred` -> 暂停停在一张
///      仍模糊的图上（用户看到的「遮罩没去掉」）。
///   ② 就算当场揭掉也不持久：重跑 `_sharedInitImages` 无条件重加 `blurred`（TODO-1289
///      同款重遮罩）。
/// 修法与点击 / 手柄揭开对齐：登记稳定 reveal key 进「本会话已揭开」活集
/// （`__hoshiMarkImageRevealed`，令日后 load 时 `_hoshiBlurImage` 跳过遮罩）+ 当场去
/// `blurred` + 回传 `onImageRevealed` 持久。铁律不变：绝不重引 IntersectionObserver，
/// 不改动 `__hoshiImageBetween` 暂停判据。
///
/// 揭遮罩是 WebView 内 JS，真行为只能设备验证；此处锁定机制契约不被回退。
void main() {
  final String bridge = File(
    'lib/src/media/audiobook/audiobook_bridge.dart',
  ).readAsStringSync();
  final String pagination = File(
    'lib/src/reader/reader_pagination_scripts.dart',
  ).readAsStringSync();

  int slice(String src, String startMarker) {
    final int i = src.indexOf(startMarker);
    expect(i, greaterThan(-1), reason: '未找到锚点：$startMarker');
    return i;
  }

  test(
      'audio-follow unblur persists via onImageRevealed (TODO-1367 root cause 2)',
      () {
    final int rbIdx = slice(bridge, '__hoshiRevealBlurredBetween = function');
    final int rbEnd = bridge.indexOf('};', rbIdx);
    expect(rbEnd, greaterThan(rbIdx));
    final String fn = bridge.substring(rbIdx, rbEnd);
    expect(fn, contains("callHandler('onImageRevealed'"),
        reason: '音频揭遮罩须回传 onImageRevealed，与点击 / 手柄揭开同等持久，'
            '否则章节重载 / 布局切换重跑 _sharedInitImages 会重新遮罩（TODO-1289）');
    expect(fn, contains("classList.remove('blurred')"),
        reason: '已 load 的 blurred 图须当场去 blurred 类');
  });

  test(
      'audio-follow unblur marks lazy images revealed before they load '
      '(TODO-1367 root cause 1)', () {
    final int rbIdx = slice(bridge, '__hoshiRevealBlurredBetween = function');
    final int rbEnd = bridge.indexOf('};', rbIdx);
    final String fn = bridge.substring(rbIdx, rbEnd);
    // 扫描区间全部 img/svg（含尚未 load 的懒图，此刻没 blurred 类），而非仅 img.blurred。
    expect(fn, contains("querySelectorAll('img, svg')"),
        reason: '须扫描区间全部 img/svg（含未 load 懒图），仅 img.blurred 抓不到懒图');
    expect(fn, contains('window.__hoshiMarkImageRevealed'),
        reason: '须把读过图的 key 登记进活集，令日后懒图 load 时 _hoshiBlurImage 跳过遮罩');
    // 关闭图片模糊时前置守卫早退，绝不动懒加载 / DOM。
    expect(fn, contains("typeof window.__hoshiImageRevealKey !== 'function'"),
        reason: '图片模糊关闭时须早退 no-op（__hoshiImageRevealKey 仅 blurImages 注入）');
    // 跳过 gaiji 内联小图（它们从不 block-img 遮罩）。
    expect(fn, contains("contains('gaiji')"),
        reason: 'gaiji 内联小图不参与防剧透遮罩，遍历时须跳过');
  });

  test(
      'pagination scripts expose __hoshiMarkImageRevealed into live reveal set',
      () {
    expect(pagination, contains('window.__hoshiMarkImageRevealed = function'),
        reason: '_sharedInitImages 须暴露 __hoshiMarkImageRevealed 把 key 写进'
            '本会话已揭开活集 _hoshiRevealedKeys');
    // 该函数写入的活集必须与 _hoshiBlurImage 命中跳过读同一个 _hoshiRevealedKeys。
    final int markIdx =
        slice(pagination, '__hoshiMarkImageRevealed = function');
    final int markEnd = pagination.indexOf('};', markIdx);
    final String markFn = pagination.substring(markIdx, markEnd);
    expect(markFn, contains('_hoshiRevealedKeys[key] = true'),
        reason: '须写进 _hoshiRevealedKeys（_hoshiBlurImage 命中此集即跳过遮罩）');
  });

  test('crossed lazy image is eager-loaded before reveal so pause shows it',
      () {
    final int advIdx = slice(bridge, '__hoshiImagePauseAdvance = function');
    final int advEnd = bridge.indexOf('\n};', advIdx);
    expect(advEnd, greaterThan(advIdx));
    final String fn = bridge.substring(advIdx, advEnd);
    expect(fn, contains("crossed.getAttribute('loading') === 'lazy'"),
        reason: '命中插图是懒图时须处理（否则 reveal 落到 0 尺寸空位、暂停看不到图）');
    expect(fn, contains("crossed.setAttribute('loading', 'eager')"),
        reason: '须强制 eager 让懒图立即 load，reveal 落到真实图盒');
    // eager-load 仍在 reveal && pauseEnabled 门控内（TODO-724：关暂停绝不滚图）。
    final int gate = fn.indexOf('if (reveal && pauseEnabled)');
    final int eager = fn.indexOf("crossed.setAttribute('loading', 'eager')");
    expect(gate, greaterThan(-1));
    expect(eager, greaterThan(gate),
        reason: 'eager-load 须在 reveal && pauseEnabled 门控之内');
  });

  test(
      'image-pause detection untouched: no IntersectionObserver, judge intact '
      '(BUG-007 iron rule)', () {
    // 揭遮罩修复绝不重引视口 IntersectionObserver（离散翻页下永不触发）。
    expect(bridge, isNot(contains('new IntersectionObserver(')),
        reason: 'BUG-007 铁律：不得退回 IntersectionObserver 视口检测');
    // 暂停判据 __hoshiImageBetween + onImageDetected 契约保持（跨图就发）。
    expect(bridge, contains("callHandler('onImageDetected')"),
        reason: '暂停判据须保留：跨图即通知 Dart 暂停');
    final int betweenIdx = slice(bridge, '__hoshiImageBetween = function');
    final int betweenEnd = bridge.indexOf('};', betweenIdx);
    final String between = bridge.substring(betweenIdx, betweenEnd);
    expect(between, contains('compareDocumentPosition'),
        reason: '暂停判据仍用 compareDocumentPosition 锚点间判定');
  });
}
