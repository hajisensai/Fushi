import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';
import 'package:fushi/src/pages/implementations/reader_pdf_page.dart';

/// 阅读器页面层三条时钟 / 计数判据的纯函数语义（页面把判据抽成顶层纯函数，
/// 页面接线由 `test/pages/reader_study_clock_gate_guard_static_test.dart` 源码守卫钉死）。
///
///  * [studyClockMayRun]（BUG-2171 / BUG-2170）：手动暂停 / 生命周期停表 / 面板压住
///    正文三枚旗任一为真都不许起表；
///  * [restoreSeedResetsReadCharge]（BUG-2168）：只有播种值真正前跳才清零令牌桶；
///  * [pdfPagesNewlyReached]（BUG-2184）：PDF 只计首次越过会话最高页的页数。
void main() {
  group('studyClockMayRun：时钟可跑的统一判据', () {
    test('三旗全清才可跑', () {
      expect(
        studyClockMayRun(
          manualPause: false,
          lifecycleStopped: false,
          modalDepth: 0,
        ),
        isTrue,
      );
    });

    test('手动暂停 → 不可跑（BUG-2171 旧 _ensureStudyClock 只看这一枚）', () {
      expect(
        studyClockMayRun(
          manualPause: true,
          lifecycleStopped: false,
          modalDepth: 0,
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
        ),
        isFalse,
        reason: 'BUG-2171：生命周期已 stop 的时钟不能被跟随翻章 / 进度刷新重新 start',
      );
    });

    test('面板 / 弹层 / 全页路由压住正文 → 不可跑；嵌套计数归零才可跑（BUG-2170）', () {
      expect(
        studyClockMayRun(
          manualPause: false,
          lifecycleStopped: false,
          modalDepth: 1,
        ),
        isFalse,
      );
      expect(
        studyClockMayRun(
          manualPause: false,
          lifecycleStopped: false,
          modalDepth: 2,
        ),
        isFalse,
        reason: '有声书面板里再开导入对话框：外层未关不得续表',
      );
    });

    test('多旗叠加：任一为真即不可跑（回前台但面板仍开着不续表）', () {
      expect(
        studyClockMayRun(
          manualPause: false,
          lifecycleStopped: false,
          modalDepth: 1,
        ),
        isFalse,
      );
      expect(
        studyClockMayRun(
          manualPause: true,
          lifecycleStopped: true,
          modalDepth: 1,
        ),
        isFalse,
      );
    });
  });

  group('restoreSeedResetsReadCharge：恢复播种是否清零令牌桶（BUG-2168）', () {
    test('播种值前跳（首次进入 / 前进跨章 / 跳转）→ 清零', () {
      expect(
        restoreSeedResetsReadCharge(currentWatermark: 0, seeded: 1200),
        isTrue,
      );
      expect(
        restoreSeedResetsReadCharge(currentWatermark: 5000, seeded: 9000),
        isTrue,
      );
    });

    test('播种值等于水位（重排 / 宽变 / 模式切换的原位恢复）→ 保留额度', () {
      expect(
        restoreSeedResetsReadCharge(currentWatermark: 5000, seeded: 5000),
        isFalse,
        reason: '改字号后紧跟的正常翻页不得因额度被砍光而整页漏计',
      );
    });

    test('播种值低于水位（回读已读章）→ 保留额度', () {
      expect(
        restoreSeedResetsReadCharge(currentWatermark: 5000, seeded: 3000),
        isFalse,
      );
    });
  });

  group('pdfPagesNewlyReached：PDF 页数只计首次越过会话最高页（BUG-2184）', () {
    test('全新打开（无存档，水位 -1）翻到首页计 1 页', () {
      expect(pdfPagesNewlyReached(pageIndex: 0, sessionMaxPageIndex: -1), (
        newPages: 1,
        maxPageIndex: 0,
      ));
    });

    test('顺序前翻每页计 1；跳目录前跳 N 页计 N 页', () {
      expect(pdfPagesNewlyReached(pageIndex: 1, sessionMaxPageIndex: 0), (
        newPages: 1,
        maxPageIndex: 1,
      ));
      expect(pdfPagesNewlyReached(pageIndex: 6, sessionMaxPageIndex: 1), (
        newPages: 5,
        maxPageIndex: 6,
      ));
    });

    test('往回翻 / 回到已读页不计，水位不下调', () {
      expect(pdfPagesNewlyReached(pageIndex: 3, sessionMaxPageIndex: 6), (
        newPages: 0,
        maxPageIndex: 6,
      ));
      expect(pdfPagesNewlyReached(pageIndex: 6, sessionMaxPageIndex: 6), (
        newPages: 0,
        maxPageIndex: 6,
      ));
    });

    test('续读：水位预置到存档页，恢复落到存档页不计、越过才计', () {
      const int restored = 41;
      expect(
        pdfPagesNewlyReached(
          pageIndex: restored,
          sessionMaxPageIndex: restored,
        ),
        (newPages: 0, maxPageIndex: restored),
        reason: '恢复到存档页不是读了 0..41',
      );
      expect(
        pdfPagesNewlyReached(
          pageIndex: restored + 1,
          sessionMaxPageIndex: restored,
        ),
        (newPages: 1, maxPageIndex: restored + 1),
      );
    });
  });
}
