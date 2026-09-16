import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';

/// 阅读器页面层时钟判据的纯函数语义（页面把判据抽成顶层纯函数，页面接线由
/// `test/pages/reader_study_clock_gate_guard_static_test.dart` 源码守卫钉死）。
///
///  * [studyClockMayRun]（BUG-2209 / BUG-2208）：手动暂停 / 生命周期停表 / 面板压住
///    正文三枚旗任一为真都不许起表。
///  * BUG-2558：后台 / 失焦期间「有声书真在出声」豁免生命周期停表（媒体中心后台听书
///    照常计时），暂停即回到停表；手动暂停仍一票否决。
///
/// EPUB 字数判据（原 BUG-2206 的 `restoreSeedResetsReadCharge` 令牌桶清零门）随标量
/// 水位一起拆除，2026-09-06 起走 `ReadUnitLedger`（翻走即计），坐标换算 / 原位恢复
/// 判据见 `reader_read_ledger_boundaries_test.dart`。
/// PDF 页数判据（原 BUG-2222 的 `pdfPagesNewlyReached` 标量水位）2026-09-06 起走
/// `ReadUnitLedger`（翻走即计），行为用例见 `reader_pdf_read_ledger_test.dart`。
void main() {
  group('studyClockMayRun：时钟可跑的统一判据', () {
    test('三旗全清才可跑', () {
      expect(
        studyClockMayRun(
          manualPause: false,
          lifecycleStopped: false,
          modalDepth: 0,
          audiobookPlaying: false,
        ),
        isTrue,
      );
    });

    test('手动暂停 → 不可跑（BUG-2209 旧 _ensureStudyClock 只看这一枚）', () {
      expect(
        studyClockMayRun(
          manualPause: true,
          lifecycleStopped: false,
          modalDepth: 0,
          audiobookPlaying: false,
        ),
        isFalse,
      );
    });

    test('切后台 / 桌面失焦 → 不可跑：后台听书跟随经 _ensureStudyClock 不得起表', () {
      expect(
        studyClockMayRun(
          manualPause: false,
          lifecycleStopped: true,
          modalDepth: 0,
          audiobookPlaying: false,
        ),
        isFalse,
        reason: 'BUG-2209：生命周期已 stop 的时钟不能被跟随翻章 / 进度刷新重新 start',
      );
    });

    test('面板 / 弹层 / 全页路由压住正文 → 不可跑；嵌套计数归零才可跑（BUG-2208）', () {
      expect(
        studyClockMayRun(
          manualPause: false,
          lifecycleStopped: false,
          modalDepth: 1,
          audiobookPlaying: false,
        ),
        isFalse,
      );
      expect(
        studyClockMayRun(
          manualPause: false,
          lifecycleStopped: false,
          modalDepth: 2,
          audiobookPlaying: false,
        ),
        isFalse,
        reason: '有声书面板里再开导入对话框：外层未关不得续表',
      );
    });

    test('BUG-2558：后台 + 有声书在播 → 可跑（媒体中心后台听书照常计时）', () {
      expect(
        studyClockMayRun(
          manualPause: false,
          lifecycleStopped: true,
          modalDepth: 0,
          audiobookPlaying: true,
        ),
        isTrue,
        reason: '锁屏 / 切后台 / 桌面 Alt+Tab 后音频继续播 = 用户在听书学习',
      );
    });

    test('BUG-2558：后台把有声书停了 → 立刻回到不可跑', () {
      expect(
        studyClockMayRun(
          manualPause: false,
          lifecycleStopped: true,
          modalDepth: 0,
          audiobookPlaying: false,
        ),
        isFalse,
        reason: 'BUG-2209 防的「熄屏 / 挂起墙钟被一次性计入」仍成立：没在播就不计',
      );
    });

    test('BUG-2558：后台听书豁免不看 modalDepth（从有声书面板点播再锁屏）', () {
      expect(
        studyClockMayRun(
          manualPause: false,
          lifecycleStopped: true,
          modalDepth: 2,
          audiobookPlaying: true,
        ),
        isTrue,
        reason: '屏幕已关 / 窗口已切走时面板不可见，这条语义不成立',
      );
    });

    test('BUG-2558：手动暂停对后台听书仍一票否决', () {
      expect(
        studyClockMayRun(
          manualPause: true,
          lifecycleStopped: true,
          modalDepth: 0,
          audiobookPlaying: true,
        ),
        isFalse,
        reason: '用户点了计时器暂停就是不想计，播放态不该把它顶回来',
      );
    });

    test('BUG-2558：前台不看播放态——面板压着正文听书仍按 BUG-2208 停表', () {
      expect(
        studyClockMayRun(
          manualPause: false,
          lifecycleStopped: false,
          modalDepth: 1,
          audiobookPlaying: true,
        ),
        isFalse,
      );
      expect(
        studyClockMayRun(
          manualPause: false,
          lifecycleStopped: false,
          modalDepth: 0,
          audiobookPlaying: true,
        ),
        isTrue,
      );
    });

    test('多旗叠加：任一为真即不可跑（回前台但面板仍开着不续表）', () {
      expect(
        studyClockMayRun(
          manualPause: false,
          lifecycleStopped: false,
          modalDepth: 1,
          audiobookPlaying: false,
        ),
        isFalse,
      );
      expect(
        studyClockMayRun(
          manualPause: true,
          lifecycleStopped: true,
          modalDepth: 1,
          audiobookPlaying: false,
        ),
        isFalse,
      );
    });
  });
}
