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

    test('TODO-724 回归：有声书主动播放跟读期，同样的非自愿快照也放行（不拽回陈旧锚）', () {
      // 与「核心 bug 路径」数据完全相同（武装中 + 实质性塌缩 + 有锚），唯一差别是有声书在播。
      // 有声书逐句 reveal（含跨章落新章首）的进度变化由音频 cue 权威驱动，不是 WebView 自发
      // reflow 归零；若仍判非自愿，拦截器会把视口强拽回上一发 committedAnchor（跨章=上章陈旧锚，
      // 常是图片）= 「有声书跳图片」。故有声书跟读期一律放行。
      expect(
        readerContinuousProgressSnapIsInvoluntary(
          continuousMode: true,
          priorProgress: 0.5,
          newProgress: 0.0,
          hasCommittedAnchor: true,
          settleGuardArmed: true,
          audiobookActivelyFollowing: true,
        ),
        isFalse,
        reason: '有声书主动跟读期进度由 cue 权威驱动，必须放行——否则跨章 reveal 被拽回上章图片',
      );
    });

    test('TODO-724 对照：有声书未播（默认）时，同一快照仍判非自愿（不影响 718 reflow 拦截）', () {
      // 开书恢复期有声书未自动续播 audiobookActivelyFollowing=false → 与原行为一致，
      // reflow-zero 仍被拦截复位。证明 724 放行只挑「正在播」，不放过恢复期 reflow 归零。
      expect(
        readerContinuousProgressSnapIsInvoluntary(
          continuousMode: true,
          priorProgress: 0.5,
          newProgress: 0.0,
          hasCommittedAnchor: true,
          settleGuardArmed: true,
          audiobookActivelyFollowing: false,
        ),
        isTrue,
        reason: '有声书未播时默认行为不变——TODO-718 的 reflow-zero 拦截不受影响',
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

      // TODO-718：解武装路由旗只在「真实用户输入驱动」时置真（消费累积的 userDriven），
      // reflow/cue-reveal 程序化滚动 userDriven=false → 不解武装因果门。
      final String scrollBody =
          windowFrom(navigation, 'void _refreshProgressFromScroll() {', 2000);
      expect(
          scrollBody.contains(
              '_progressRefreshFromScroll = _scrollUserDrivenPending'),
          isTrue,
          reason: '解武装路由旗必须取自累积的用户输入驱动标志，'
              '而非「任何 scroll 都置真」（否则 reflow 归零误解武装 = TODO-718 回归）');
      expect(scrollBody.contains('_scrollUserDrivenPending = false'), isTrue,
          reason: '消费后必须清零累积标志');

      // TODO-718：_handleReaderScroll 必须接收 JS 算出的 userDriven 并累积。
      final String handleBody = windowFrom(
          navigation, 'void _handleReaderScroll(bool userDriven) {', 600);
      expect(
          handleBody
              .contains('if (userDriven) _scrollUserDrivenPending = true'),
          isTrue,
          reason: '_handleReaderScroll 必须按 JS 传入的 userDriven 累积，'
              '节流/coalesce 期只要一发用户驱动即记真');

      // TODO-724：拦截判据必须接入有声书主动跟读状态。
      final String refreshBody2 = windowFrom(
          navigation, 'Future<void> _refreshProgress() async {', 5200);
      expect(
          refreshBody2.contains('audiobookActivelyFollowing: '
              '_audiobookController?.isPlaying == true'),
          isTrue,
          reason: '判据必须接入有声书 isPlaying，跟读期放行不拽回陈旧锚（TODO-724）');

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

    test('TODO-718 根因：初次开书 + 样式重载的裸恢复路径也必须武装因果门', () {
      // 初次开书(从书架点开)走 webview.part.dart 的 _loadChapterDirectly 裸装章，**不经
      // _beginNavigation**；若不武装因果门，TODO-798 拦截器第一道门(!settleGuardArmed)恒放行 →
      // 连续模式恢复位置被 reflow 归零裸奔落库弹回章首(798/718 对初次开书无效的真因)。
      final String webview = File(
        'lib/src/pages/implementations/reader_hibiki/webview.part.dart',
      ).readAsStringSync();
      final int openIdx =
          webview.indexOf('_loadChapterDirectly(_currentChapter)');
      expect(openIdx, greaterThan(0), reason: '初次开书装章入口必须存在');
      // 武装必须紧邻在 _loadChapterDirectly 之前(同一 else 块内)。
      final String openWindow =
          webview.substring((openIdx - 400).clamp(0, webview.length), openIdx);
      expect(openWindow.contains('_continuousSettleGuardArmed = true'), isTrue,
          reason: '初次开书裸装章前必须武装因果门(对齐 _beginNavigation)，'
              '否则 TODO-798 拦截器对初次开书恒放行 → 弹回章首(TODO-718)');

      // 样式重载(改字号/字体)同样裸恢复，纵深防御也武装。
      final String chrome = File(
        'lib/src/pages/implementations/reader_hibiki/chrome.part.dart',
      ).readAsStringSync();
      final int reloadIdx = chrome.indexOf('reloadWithCurrentSettings:');
      expect(reloadIdx, greaterThan(0),
          reason: 'reloadWithCurrentSettings 必须存在');
      final String reloadWindow = chrome.substring(
          (reloadIdx - 400).clamp(0, chrome.length), reloadIdx);
      expect(
          reloadWindow.contains('_continuousSettleGuardArmed = true'), isTrue,
          reason: '样式重载裸恢复也武装因果门(纵深防御，B-3 窗超窗仍兜)');
    });
  });
}
