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
        ),
        isTrue,
        reason: '恢复落定在 0.5 后 reflow 单步归 0，必须判非自愿并复位，不得落库章首',
      );
    });

    test('分页模式恒 false——有 snap/lock 保护，归零不裸奔', () {
      expect(
        readerContinuousProgressSnapIsInvoluntary(
          continuousMode: false,
          priorProgress: 0.5,
          newProgress: 0.0,
          hasCommittedAnchor: true,
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
        ),
        isTrue,
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
  });
}
