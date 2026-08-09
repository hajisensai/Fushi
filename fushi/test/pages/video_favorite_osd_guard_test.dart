import 'package:flutter_test/flutter_test.dart';

import 'video_fushi_page_source_corpus.dart';
import '../helpers/source_guard.dart';

/// BUG-931：视频播放器里的两个 UX 契约，用源码扫描守卫锁死，防未来重构悄悄回退。
///
/// 1) 收藏快捷键（Ctrl+D → `_toggleFavoriteCurrentCue`）**不得**再调
///    `_pokeControlsVisible()`——那会派发合成 hover 唤醒 media_kit 控制条，把底栏
///    seekbar 进度条弹出来（用户报「碍眼」）。收藏结果提示走左上角 OSD 即可，不需要
///    显现控制条。注意 seek / 重播（`_replay*AndPokeControls`）**仍**保留 poke，因为
///    那些操作本就需要看进度，所以守卫只针对收藏这一处。
///
/// 2) 视频页所有短提示统一走左上角 OSD `_showOsd(...)`，**不得**再用底部全局
///    `FushiToast.show(...)`（桌面 `bottom:50` 居中 / 移动端 `ToastGravity.BOTTOM`）。
///    这样收藏加/移除、复制、无句可选、资源重链、需重启渲染等提示都落在屏幕左上角，
///    与字幕 / 锁定 / 画质切换的 OSD 一致。全局 `FushiToast` 本身不动（阅读器等其它
///    页面继续用底部 toast）。
///
/// 提取 `_toggleFavoriteCurrentCue` 方法体：从签名起，到下一个 2 空格缩进的成员声明
/// （`\n  Future<` / `\n  void `）为止。签名/邻接方法名变了这里会取到更大的窗口，
/// 断言只会更保守（更容易发现误加的 poke），不会漏。
String _methodBody(String src, String signature) {
  final int start = src.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0),
      reason: '找不到方法签名 `$signature`——视频页收藏入口被重命名了？请更新守卫。');
  final int bodyStart = start + signature.length;
  final RegExp nextMember = RegExp(r'\n  (Future<|void |bool |String |int )');
  final Match? next = nextMember.firstMatch(src.substring(bodyStart));
  final int end = next == null ? src.length : bodyStart + next.start;
  return src.substring(start, end);
}

void main() {
  group('BUG-931 视频收藏 OSD / 无进度条守卫', () {
    test('收藏快捷键不再唤起控制条进度条（_toggleFavoriteCurrentCue 无 _pokeControlsVisible）',
        () {
      final String src = readVideoFushiSource();
      final String body =
          _methodBody(src, 'Future<void> _toggleFavoriteCurrentCue() async {');
      expect(
        body.contains('_pokeControlsVisible'),
        isFalse,
        reason: 'BUG-931：收藏不得调 `_pokeControlsVisible()`，否则会把底栏进度条弹出来'
            '（碍眼）。收藏提示走 `_showOsd` 左上角即可。',
      );
      // 正向证据：收藏路径确实改走了左上角 OSD。
      expect(
        compactCode(body).contains(compactCode('_showOsd(t.no_sentence_selected,')),
        isTrue,
        reason: '收藏无句可选时应走左上角 `_showOsd`，不是底部 toast。',
      );
    });

    test('视频页所有短提示走左上角 OSD，全域无 FushiToast.show（底部 toast）', () {
      final String src = readVideoFushiSource();
      expect(
        src.contains('FushiToast.show'),
        isFalse,
        reason: 'BUG-931：视频页短提示统一走左上角 `_showOsd(...)`；出现 '
            '`FushiToast.show` 说明有提示回退到了屏幕底部。',
      );
      // 收藏加/移除确实用 OSD（防止有人把提示整个删掉来「绕过」守卫）。
      expect(compactCode(src).contains(compactCode('_showOsd(t.favorite_added,')),
          isTrue,
          reason: '收藏成功应走左上角 `_showOsd(t.favorite_added ...)`。');
      expect(compactCode(src).contains(compactCode('_showOsd(t.favorite_removed,')),
          isTrue,
          reason: '取消收藏应走左上角 `_showOsd(t.favorite_removed ...)`。');
    });
  });
}
