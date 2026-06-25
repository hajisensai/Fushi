import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart'
    show readerContinuousProgressSnapIsInvoluntary;

/// TODO-718/798 连续模式「退出再进恒回章首 / 位置不恢复」非自愿 reflow 归零判据。
///
/// 真因：连续模式裸 `window.scrollX/Y` 退出再进恢复后，WebView 自发 reflow 把滚动瞬时归 0，
/// 归零 scroll 经 onReaderScroll → _refreshProgress 落库章首。
///
/// 判据重设计（TODO-718·2026-06-25·删除 settleGuardArmed 因果门状态机）：旧版用「武装/解武装」
/// 状态机区分 reflow 归零 vs 用户拖到章首，但解武装信号被 B-3 settle 窗 / 拦截器前置 return 双重
/// 吞掉 → 门永 armed → 用户向前滚被反复拽回恢复锚、滚不出去、保存值停在开头。改为**无状态**：
/// 直接用本次刷新是否真用户输入驱动 [fromUserScroll]（JS 据最近 1000ms 内 touch/pointer/wheel/key
/// 算出；reflow/cue-reveal 程序化滚动恒 false）区分——用户真滚一律放行，程序化归零才复位。
void main() {
  group('readerContinuousProgressSnapIsInvoluntary（无状态非自愿 reflow 归零判据真值表）', () {
    test('程序化归零(fromUserScroll=false)：实质性塌缩到章首 + 有锚 → 判非自愿（核心 bug 路径）', () {
      expect(
        readerContinuousProgressSnapIsInvoluntary(
          continuousMode: true,
          priorProgress: 0.5,
          newProgress: 0.0,
          hasCommittedAnchor: true,
          fromUserScroll: false,
        ),
        isTrue,
        reason: '恢复落定在 0.5 后，非用户输入的 reflow 单步归 0 → 复位，不得落库章首',
      );
    });

    test('用户真滚(fromUserScroll=true)：同样塌缩到章首也放行（用户要去章首就去）', () {
      expect(
        readerContinuousProgressSnapIsInvoluntary(
          continuousMode: true,
          priorProgress: 0.5,
          newProgress: 0.0,
          hasCommittedAnchor: true,
          fromUserScroll: true,
        ),
        isFalse,
        reason: '用户真实输入驱动的滚动一律放行——无门无陷阱，用户能滚到任何位置含章首',
      );
    });

    test('分页模式恒 false——有 snap/lock 保护，归零不裸奔', () {
      expect(
        readerContinuousProgressSnapIsInvoluntary(
          continuousMode: false,
          priorProgress: 0.5,
          newProgress: 0.0,
          hasCommittedAnchor: true,
          fromUserScroll: false,
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
          fromUserScroll: false,
        ),
        isFalse,
      );
    });

    test('新进度未塌缩到章首（仍在正文）→ 放行落库', () {
      expect(
        readerContinuousProgressSnapIsInvoluntary(
          continuousMode: true,
          priorProgress: 0.5,
          newProgress: 0.45,
          hasCommittedAnchor: true,
          fromUserScroll: false,
        ),
        isFalse,
      );
    });

    test('上一发已≈0（prior<minPrior）→ 不误判（程序化也放行：非「实质性单步塌缩」）', () {
      expect(
        readerContinuousProgressSnapIsInvoluntary(
          continuousMode: true,
          priorProgress: 0.04,
          newProgress: 0.0,
          hasCommittedAnchor: true,
          fromUserScroll: false,
        ),
        isFalse,
        reason: 'prior 已≈0 不算实质性塌缩，放行（与原 minPrior 阈值语义一致）',
      );
    });

    test('边界：prior 恰在阈值、new 恰在章首 epsilon 内、fromUserScroll=false → 判非自愿', () {
      expect(
        readerContinuousProgressSnapIsInvoluntary(
          continuousMode: true,
          priorProgress: 0.05,
          newProgress: 0.01,
          hasCommittedAnchor: true,
          fromUserScroll: false,
        ),
        isTrue,
      );
    });

    test('TODO-724：有声书主动播放跟读期一律放行（不拽回陈旧锚=不跳图片）', () {
      // 与核心 bug 路径数据相同（程序化 + 塌缩 + 有锚），唯一差别是有声书在播：进度由音频 cue
      // 权威驱动（含跨章 reveal 落新章首），不是自发 reflow 归零，必须放行。
      expect(
        readerContinuousProgressSnapIsInvoluntary(
          continuousMode: true,
          priorProgress: 0.5,
          newProgress: 0.0,
          hasCommittedAnchor: true,
          fromUserScroll: false,
          audiobookActivelyFollowing: true,
        ),
        isFalse,
        reason: '有声书跟读期进度由 cue 权威驱动，放行——否则跨章 reveal 被拽回上章图片',
      );
    });

    test('TODO-724 对照：有声书未播时同一程序化快照仍判非自愿（不影响 718 reflow 拦截）', () {
      expect(
        readerContinuousProgressSnapIsInvoluntary(
          continuousMode: true,
          priorProgress: 0.5,
          newProgress: 0.0,
          hasCommittedAnchor: true,
          fromUserScroll: false,
          audiobookActivelyFollowing: false,
        ),
        isTrue,
      );
    });
  });

  group('TODO-718/798 接线守卫：判据(无状态) + 复位接进 _refreshProgress（落库之前）', () {
    final String navigation = File(
      'lib/src/pages/implementations/reader_hibiki/navigation.part.dart',
    ).readAsStringSync();
    final String page = File(
      'lib/src/pages/implementations/reader_hibiki_page.dart',
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
          reason: '_refreshProgress 必须用非自愿判据拦 reflow 归零');
      final int saveIdx =
          body.indexOf('_debouncedSavePosition(progress, charOffset)');
      expect(saveIdx, greaterThan(guardIdx),
          reason: '判据必须在 _debouncedSavePosition 之前——否则归零会先落库章首');
      expect(body.contains('scrollToCharOffsetInvocation'), isTrue,
          reason: '触发后必须复位到已提交锚（把视口滚回），否则用户仍会看到弹回章首');
    });

    test('判据接入无状态信号 fromUserScroll + 有声书 isPlaying（非旧因果门）', () {
      final String body =
          methodBody(navigation, 'Future<void> _refreshProgress() async {');
      expect(body.contains('fromUserScroll: fromUserScroll'), isTrue,
          reason: '判据必须接入 fromUserScroll（无状态用户输入信号）');
      expect(
          body.contains('audiobookActivelyFollowing: '
              '_audiobookController?.isPlaying == true'),
          isTrue,
          reason: '判据必须接入有声书 isPlaying（跟读期放行，TODO-724）');
    });

    test(
        'fromUserScroll 来自累积的真用户输入(_progressRefreshFromScroll = _scrollUserDrivenPending)',
        () {
      final String scrollBody =
          methodBody(navigation, 'void _refreshProgressFromScroll() {');
      expect(
          scrollBody.contains(
              '_progressRefreshFromScroll = _scrollUserDrivenPending'),
          isTrue,
          reason: '路由旗必须取自累积的用户输入驱动标志（reflow/cue-reveal=false）');
      final String handleBody =
          methodBody(navigation, 'void _handleReaderScroll(bool userDriven) {');
      expect(
          handleBody
              .contains('if (userDriven) _scrollUserDrivenPending = true'),
          isTrue,
          reason: '_handleReaderScroll 必须按 JS 传入的 userDriven 累积');
    });

    test('因果门状态机已彻底删除（不再有 _continuousSettleGuardArmed 字段/赋值）', () {
      // 旧状态机的解武装信号被前置 return 吞掉致用户卡在恢复锚——已用无状态判据取代。
      // 仅允许注释提及，不得有 `bool _continuousSettleGuardArmed` 声明或 `= true/false` 赋值。
      expect(page.contains('bool _continuousSettleGuardArmed'), isFalse,
          reason: '_continuousSettleGuardArmed 字段必须删除');
      expect(navigation.contains('_continuousSettleGuardArmed = true'), isFalse,
          reason: '不得再有因果门武装');
      expect(
          navigation.contains('_continuousSettleGuardArmed = false'), isFalse,
          reason: '不得再有因果门解武装');
    });
  });
}
