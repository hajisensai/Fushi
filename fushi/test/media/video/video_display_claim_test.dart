import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_display_claim.dart';

/// BUG-2105 真值表：视频页对进程级显示态（移动端横屏锁 / 系统栏可见性回调 /
/// macOS 交通灯）的**所有者记账**。
///
/// 行为级复现要真设备方向系统 + 真 `pushReplacement` 过渡动画，headless 跑不了；
/// 把「该不该还原」抽成纯登记表后，「旧页 dispose 掀掉新页显示态」这条回归就能在
/// 单测里判红——判据只有一条：`release` 返回 true 当且仅当集合被它清空。
void main() {
  setUp(VideoDisplayClaim.resetForTest);
  tearDown(VideoDisplayClaim.resetForTest);

  group('VideoDisplayClaim 所有者记账 (BUG-2105)', () {
    test('首个认领者返回 true，后续认领者返回 false', () {
      final Object a = Object();
      final Object b = Object();
      expect(VideoDisplayClaim.claim(a), isTrue, reason: 'a 是首个持有者');
      expect(VideoDisplayClaim.claim(b), isFalse, reason: '已有人持有');
      expect(VideoDisplayClaim.ownerCount, 2);
      expect(VideoDisplayClaim.held, isTrue);
    });

    test('重复认领同一 owner 幂等，不会把计数刷成两份', () {
      final Object a = Object();
      expect(VideoDisplayClaim.claim(a), isTrue);
      expect(VideoDisplayClaim.claim(a), isFalse);
      expect(VideoDisplayClaim.ownerCount, 1);
      expect(VideoDisplayClaim.release(a), isTrue, reason: '一次释放就该清空');
      expect(VideoDisplayClaim.held, isFalse);
    });

    test('正常退页：唯一持有者释放 → 该还原', () {
      final Object a = Object();
      VideoDisplayClaim.claim(a);
      expect(VideoDisplayClaim.release(a), isTrue);
      expect(VideoDisplayClaim.ownerCount, 0);
    });

    test('换集顺序（新页 initState 先于旧页 dispose）：旧页释放不得还原', () {
      final Object oldPage = Object();
      final Object newPage = Object();
      VideoDisplayClaim.claim(oldPage);
      // pushReplacement：新页 initState 认领，随后旧页 dispose 才跑。
      VideoDisplayClaim.claim(newPage);
      expect(
        VideoDisplayClaim.release(oldPage),
        isFalse,
        reason: '新页仍持有 → 旧页 dispose 不得还原方向 / 系统栏回调 / 交通灯',
      );
      expect(VideoDisplayClaim.held, isTrue);
      // 新页最终退出时才还原。
      expect(VideoDisplayClaim.release(newPage), isTrue);
      expect(VideoDisplayClaim.held, isFalse);
    });

    test('连续换集三集：只有最后一页离开才还原', () {
      final List<Object> pages = <Object>[Object(), Object(), Object()];
      VideoDisplayClaim.claim(pages[0]);
      for (int i = 1; i < pages.length; i++) {
        VideoDisplayClaim.claim(pages[i]);
        expect(
          VideoDisplayClaim.release(pages[i - 1]),
          isFalse,
          reason: '第 $i 次换集：新页在册，旧页释放不得还原',
        );
      }
      expect(VideoDisplayClaim.release(pages.last), isTrue);
    });

    test('未认领过的 owner 释放返回 false（没设过就无权还原）', () {
      final Object held = Object();
      VideoDisplayClaim.claim(held);
      expect(VideoDisplayClaim.release(Object()), isFalse);
      expect(VideoDisplayClaim.ownerCount, 1, reason: '陌生 owner 的释放不得摘掉真实持有者');
      expect(VideoDisplayClaim.release(held), isTrue);
    });

    test('空表上释放返回 false，不把 held 翻真也不抛', () {
      expect(VideoDisplayClaim.release(Object()), isFalse);
      expect(VideoDisplayClaim.held, isFalse);
    });
  });
}
