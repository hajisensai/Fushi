import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart'
    show readerContinuousProgressSnapIsInvoluntary;

/// TODO-798：连续/滚动模式书籍历史记录恒回章首（795/797 修了仍未修好）。
///
/// 真因（位置不连续，非时间窗）：连续模式裸 `window.scrollY` 退出再进恢复后，WebView
/// 自发 reflow 把 scrollY 瞬时归 0，归零 scroll 经 onReaderScroll → _refreshProgress 落库
/// 章首。既有两墙（JS _reanchorPending 旗 / Dart B-3 250ms 窗）都是时间边界的，归零晚到
/// （大章+图片首开 reflow 远超 250ms）就穿过 → 落库 progress≈0。
///
/// [readerContinuousProgressSnapIsInvoluntary] 用「上一发实质性非零 → 这一发单步塌缩到
/// 章首」判非自愿归零（与输入时序无关，故不误伤惯性甩动到真章首——那会逐帧递减上报）。
void main() {
  group('readerContinuousProgressSnapIsInvoluntary（非自愿 reflow 归零判据真值表）', () {
    test('连续模式：实质性位置单步塌缩到章首 + 有锚 → 判非自愿（核心 bug 路径）', () {
      expect(
        readerContinuousProgressSnapIsInvoluntary(
          continuousMode: true,
          priorProgress: 0.5,
          newProgress: 0.0,
          hasCommittedAnchor: true,
          settleGuardArmed: true,
        ),
        isTrue,
        reason: '恢复落定在 0.5 后（自发 settle 期·武装中）reflow 单步归 0，'
            '必须判非自愿并复位，不得落库章首',
      );
    });

    test('分页模式恒 false——有 snap/lock 保护，归零不裸奔', () {
      expect(
        readerContinuousProgressSnapIsInvoluntary(
          continuousMode: false,
          priorProgress: 0.5,
          newProgress: 0.0,
          hasCommittedAnchor: true,
          settleGuardArmed: true,
        ),
        isFalse,
      );
    });

    test('无已提交锚（首开尚无任何已提交位置）→ false，无从复位交正常路径', () {
      expect(
        readerContinuousProgressSnapIsInvoluntary(
          continuousMode: true,
          priorProgress: 0.5,
          newProgress: 0.0,
          hasCommittedAnchor: false,
          settleGuardArmed: true,
        ),
        isFalse,
      );
    });

    test('用户惯性甩动到章首：逐帧递减，到 0 那一发 prior 已≈0 → 不误判（B-4 栽跟头处）', () {
      // 甩动尾段连续两发：…→0.04→0.0。到 0 那一发的 prior=0.04 < minPrior → false。
      expect(
        readerContinuousProgressSnapIsInvoluntary(
          continuousMode: true,
          priorProgress: 0.04,
          newProgress: 0.0,
          hasCommittedAnchor: true,
          settleGuardArmed: true,
        ),
        isFalse,
        reason: '用户真滚到章首（含惯性甩动）逐帧上报，到 0 时 prior 已≈0，必须放行落库',
      );
    });

    test('用户从中段正常滚动（新进度未塌缩到章首）→ 放行落库', () {
      expect(
        readerContinuousProgressSnapIsInvoluntary(
          continuousMode: true,
          priorProgress: 0.5,
          newProgress: 0.45,
          hasCommittedAnchor: true,
          settleGuardArmed: true,
        ),
        isFalse,
      );
    });

    test('用户主动停在章首再退出（prior 已≈0）→ 放行，保住「真滑到章首仍能保存」', () {
      expect(
        readerContinuousProgressSnapIsInvoluntary(
          continuousMode: true,
          priorProgress: 0.0,
          newProgress: 0.0,
          hasCommittedAnchor: true,
          settleGuardArmed: true,
        ),
        isFalse,
        reason: '相邻保护②：用户真停在章首必须能保存章首，不能被一刀切禁止归零',
      );
    });

    test('边界：prior 恰在阈值、new 恰在章首 epsilon 内 → 判非自愿', () {
      expect(
        readerContinuousProgressSnapIsInvoluntary(
          continuousMode: true,
          priorProgress: 0.05,
          newProgress: 0.01,
          hasCommittedAnchor: true,
          settleGuardArmed: true,
        ),
        isTrue,
      );
    });

    test(
        '续修边界①：用户拖滚动条到章首（拖动途中已解武装）→ 放行，不被拽回'
        '（prior=0.15、new=0、有锚、settleGuardArmed=false）', () {
      // 桌面原生滚动条 thumb 快拖 / 点轨道跳章首：50ms 节流 + in-flight coalesce 采样
      // 追不上手速，到 0 那一发之前最后采到的 prior 停在 0.15（> minPrior 0.05），与
      // reflow 归零在数据层不可区分。但用户拖动途中的早发滚动已把因果门解武装
      // （settleGuardArmed=false）→ 因果门放行，用户停在章首不被复位拽回。
      expect(
        readerContinuousProgressSnapIsInvoluntary(
          continuousMode: true,
          priorProgress: 0.15,
          newProgress: 0.0,
          hasCommittedAnchor: true,
          settleGuardArmed: false,
        ),
        isFalse,
        reason: '用户已真滚过（解武装）→ 归零必是用户拖到章首，必须放行停在章首',
      );
    });

    test(
        '续修边界②：因果与门——同样的 prior=0.15→0，仍在自发 settle 期（武装中）'
        '则判非自愿（reflow 归零，复位）', () {
      // 与上一例数据层完全相同，唯一差别是 settleGuardArmed。证明因果门是真区分两类
      // 归零的判据（非靠 prior 阈值魔法）：武装中 = reflow，解武装 = 用户拖到章首。
      expect(
        readerContinuousProgressSnapIsInvoluntary(
          continuousMode: true,
          priorProgress: 0.15,
          newProgress: 0.0,
          hasCommittedAnchor: true,
          settleGuardArmed: true,
        ),
        isTrue,
        reason: '同一数据快照，武装中则属恢复后自发 reflow 归零，必须复位',
      );
    });

    test('续修边界③：核心 bug 快照在解武装后不再误判（与门否决）', () {
      // 用户滚过一次后晚到的图片 reflow 归零：已解武装 → 本判据不再兜（acceptable 取舍）。
      expect(
        readerContinuousProgressSnapIsInvoluntary(
          continuousMode: true,
          priorProgress: 0.5,
          newProgress: 0.0,
          hasCommittedAnchor: true,
          settleGuardArmed: false,
        ),
        isFalse,
        reason: '解武装后一律放行——不再误伤用户真滑到章首；晚到 reflow 由 JS 重锚路径兜',
      );
    });
  });

  group('TODO-798 接线守卫：判据 + 复位接进 _refreshProgress（落库之前）', () {
    final String navigation = File(
      'lib/src/pages/implementations/reader_hibiki/navigation.part.dart',
    ).readAsStringSync();

    String methodBody(String src, String signature) {
      final int idx = src.indexOf(signature);
      expect(idx, greaterThanOrEqualTo(0), reason: '找不到方法 $signature');
      final int end = src.indexOf('\n  }', idx);
      expect(end, greaterThan(idx), reason: '找不到方法 $signature 的体结尾');
      return src.substring(idx, end);
    }

    test('_refreshProgress 在落库前判非自愿归零，触发则复位锚 + return 不落库', () {
      final String body =
          methodBody(navigation, 'Future<void> _refreshProgress() async {');
      final int guardIdx =
          body.indexOf('readerContinuousProgressSnapIsInvoluntary');
      expect(guardIdx, greaterThanOrEqualTo(0),
          reason: '_refreshProgress 必须用位置不连续判据拦非自愿 reflow 归零');
      final int saveIdx =
          body.indexOf('_debouncedSavePosition(progress, charOffset)');
      expect(saveIdx, greaterThan(guardIdx),
          reason: '判据必须在 _debouncedSavePosition 之前——否则归零会先落库章首');
      expect(body.contains('scrollToCharOffsetInvocation'), isTrue,
          reason: '触发后必须根因式复位到已提交锚（不止跳过落库，还要把视口滚回），'
              '否则用户仍会看到弹回章首');
    });

    test('续修边界接线：因果门 settleGuardArmed 必须真传入判据', () {
      final String body =
          methodBody(navigation, 'Future<void> _refreshProgress() async {');
      expect(body.contains('settleGuardArmed: _continuousSettleGuardArmed'),
          isTrue,
          reason: '判据必须接入因果门字段 _continuousSettleGuardArmed，'
              '否则退回纯位置判据会误伤拖滚动条到章首');
    });

    // methodBody 的「双空格缩进闭合花括号」终止符在多行参数列表 / 嵌套闭包上会提前
    // 截断，故下面武装/解武装接线断言改用「从签名起的窗口」（与 diag-log 守卫同款窗口法）。
    String windowFrom(String src, String signature, int len) {
      final int idx = src.indexOf(signature);
      expect(idx, greaterThanOrEqualTo(0), reason: '找不到 $signature');
      final int end = (idx + len).clamp(0, src.length);
      return src.substring(idx, end);
    }

    test('续修边界接线：导航开启武装、用户首次真实滚动解武装', () {
      final String beginBody =
          windowFrom(navigation, 'void _beginNavigation({', 1500);
      expect(beginBody.contains('_continuousSettleGuardArmed = true'), isTrue,
          reason: '每次导航必须武装因果门（恢复落定后进入自发 settle 期）');

      final String scrollBody =
          windowFrom(navigation, 'void _refreshProgressFromScroll() {', 2000);
      expect(scrollBody.contains('_progressRefreshFromScroll = true'), isTrue,
          reason: '滚动驱动的 _refreshProgress 必须置路由旗，作解武装唯一候选来源');

      final String refreshBody = windowFrom(
          navigation, 'Future<void> _refreshProgress() async {', 5200);
      expect(
          refreshBody.contains('_continuousSettleGuardArmed = false'), isTrue,
          reason: '用户首次真实滚动（未判非自愿）必须解武装因果门');
      // 解武装必须门控在 fromUserScroll——否则恢复后首发轮询会误解武装致 reflow 裸奔。
      expect(
          refreshBody.contains('if (fromUserScroll && '
              '_continuousSettleGuardArmed)'),
          isTrue,
          reason: '解武装必须仅在用户滚动驱动路径，轮询/恢复不得解武装');
    });
  });
}
