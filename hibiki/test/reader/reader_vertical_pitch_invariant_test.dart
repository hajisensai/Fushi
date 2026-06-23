import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_content_styles.dart';

/// TODO-734 纯 Dart 代数守卫（仓库无 headless 浏览器，几何正确性靠代数影子覆盖）。
///
/// 竖排分页列高几何「成对」不变式：
///  - CSS column-width(px) = V − mt − mb − F − cT − cB
///    （ReaderContentStyles.verticalColumnContentHeight，唯一真相源）。
///  - JS getScrollContext 的 contentBox = viewportHeight − paddingTop − paddingBottom，
///    其中 viewportHeight=V、paddingTop=mt+cT、paddingBottom=mb+F+cB（镜像 CSS
///    padding-top/padding-bottom）。代入得 contentBox = V − mt − mb − F − cT − cB。
///
/// 故 columnWidth == contentBox（不变式 1）。pageStep = contentBox + gap(22) == realPitch
/// （保 TODO-729 防跳章）。
///
/// 漏出量（不变式 2）：列在视口里从 chrome-top-inset 处起画，列底边相对视口顶 =
/// cT + columnWidth。视口底部可用边界 = V − cB。默认页边距 mt=mb=0 时：
///   leak = (cT + columnWidth) − (V − cB) = −F  （≤ 0 恒成立，且与 cT/cB 无关）。
/// 即列底边永远比视口底高 F px（不漏字），无论字号 F 多大/多小。
void main() {
  const double viewportV = 800; // 任意视口高，代数不变式与具体 V 无关。
  const double gapPx = 22; // 固定 column-gap（TODO-729 不动）。
  const double bottomOverlapO = 22; // bottomOverlapPx，--page-height = V + O。

  /// JS 端竖排 contentBox 的代数影子：viewportHeight − paddingTop − paddingBottom，
  /// padding 与 CSS 模板逐项镜像（paddingTop=mt+cT，paddingBottom=mb+F+cB）。
  double jsContentBox({
    required double v,
    required double f,
    required double mt,
    required double mb,
    required double cT,
    required double cB,
  }) {
    final double paddingTop = mt + cT;
    final double paddingBottom = mb + f + cB;
    return v - paddingTop - paddingBottom;
  }

  group('TODO-734 竖排列高成对不变式（CSS column-width == JS contentBox）', () {
    test('不变式1：columnWidth == contentBox（采样 F × cT/cB 全组合）', () {
      for (final double f in const <double>[12, 22, 96, 128]) {
        for (final double cT in const <double>[0, 24, 48, 96]) {
          for (final double cB in const <double>[0, 24, 48, 96]) {
            const double mt = 0;
            const double mb = 0;
            final double columnWidth =
                ReaderContentStyles.verticalColumnContentHeight(
              viewportHeightPx: viewportV,
              fontSizePx: f,
              marginTopPx: mt,
              marginBottomPx: mb,
              chromeTopInsetPx: cT,
              chromeBottomInsetPx: cB,
            );
            final double contentBox = jsContentBox(
              v: viewportV,
              f: f,
              mt: mt,
              mb: mb,
              cT: cT,
              cB: cB,
            );
            expect(columnWidth, contentBox,
                reason:
                    'F=$f cT=$cT cB=$cB: CSS column-width 必须等于 JS contentBox，'
                    '否则 pageStep≠realPitch 复活跳章');
          }
        }
      }
    });

    test('pageStep == realPitch（contentBox + gap，保 TODO-729 防跳章）', () {
      for (final double f in const <double>[12, 22, 96, 128]) {
        final double columnWidth =
            ReaderContentStyles.verticalColumnContentHeight(
          viewportHeightPx: viewportV,
          fontSizePx: f,
          marginTopPx: 0,
          marginBottomPx: 0,
          chromeTopInsetPx: 0,
          chromeBottomInsetPx: 0,
        );
        final double pageStep = jsContentBox(
              v: viewportV,
              f: f,
              mt: 0,
              mb: 0,
              cT: 0,
              cB: 0,
            ) +
            gapPx;
        final double realPitch = columnWidth + gapPx;
        expect(pageStep, realPitch, reason: 'F=$f: pageStep 必须等于真实列周期');
      }
    });

    test('不变式2：漏出量 leak = −F ≤ 0 恒成立，且与 F/cT/cB 无关（不随 F 漂）', () {
      // 列底边相对视口顶 = cT + columnWidth；视口底可用 = V − cB；leak = 差值。
      for (final double f in const <double>[12, 22, 96, 128]) {
        for (final double cT in const <double>[0, 24, 48, 96]) {
          for (final double cB in const <double>[0, 24, 48, 96]) {
            final double columnWidth =
                ReaderContentStyles.verticalColumnContentHeight(
              viewportHeightPx: viewportV,
              fontSizePx: f,
              marginTopPx: 0,
              marginBottomPx: 0,
              chromeTopInsetPx: cT,
              chromeBottomInsetPx: cB,
            );
            final double columnBottomEdge = cT + columnWidth;
            final double viewportBottomUsable = viewportV - cB;
            final double leak = columnBottomEdge - viewportBottomUsable;
            expect(leak, -f,
                reason: 'F=$f cT=$cT cB=$cB: 漏出量必须恒等于 −F（列底边高于视口底 F px），'
                    '不随 cT/cB 漂移');
            expect(leak <= 0, isTrue, reason: 'F=$f: leak 必须 ≤ 0，绝不漏字进底栏');
          }
        }
      }
    });

    test('对照：若误用含 +bottomOverlap 的 --page-height 当基准，会漏出 (O−F)>0', () {
      // 这是 TODO-734 的根因复现：旧基准 = V + O。列底边 = cT + (V+O − F − cT − cB) =
      // V + O − F − cB；视口底可用 = V − cB；leak = O − F。F<22 时 leak>0 漏字。
      const double cT = 0;
      const double cB = 0;
      for (final double f in const <double>[12, 22, 96, 128]) {
        final double badColumnWidth =
            (viewportV + bottomOverlapO) - f - cT - cB;
        final double leak = (cT + badColumnWidth) - (viewportV - cB);
        expect(leak, bottomOverlapO - f,
            reason: 'F=$f: 旧基准漏出量 = O−F（证明根因），F<22 时为正即漏字');
      }
      // F=12 漏 10px、F=22 恰好 0（默认字号巧合不漏）、F>22 反而负（藏字）。
      expect(bottomOverlapO - 12, 10);
      expect(bottomOverlapO - 22, 0);
    });
  });
}
