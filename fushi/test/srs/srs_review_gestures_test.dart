// 复习页卡面手势的纯判定：默认映射（= 加手势系统之前的行为）、两面可绑动作、「只留重来 /
// 良好」屏蔽、识别器开关、持久化格式（容错 / 向前兼容）、点按分区与滑动判定、页内载荷换算。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_review_gestures.dart';

void main() {
  const SrsReviewSide front = SrsReviewSide.front;
  const SrsReviewSide back = SrsReviewSide.back;

  group('默认映射', () {
    test('两面单击（任一分区）= 切换顶栏，其余一概不绑', () {
      final SrsReviewGestureMap m = SrsReviewGestureMap.defaults;
      for (final SrsReviewSide side in SrsReviewSide.values) {
        for (final SrsReviewGesture g in SrsReviewGesture.values) {
          expect(
            m.resolve(side, g, hideHardEasy: false),
            g.isTap
                ? SrsReviewGestureAction.toggleToolbar
                : SrsReviewGestureAction.none,
            reason: '$side $g',
          );
        }
      }
      expect(m.isDefault, isTrue);
    });

    test('默认不开双击 / 长按 / 滑动识别器：单击不被推迟、拖动与长按不被接管', () {
      for (final SrsReviewSide side in SrsReviewSide.values) {
        expect(
          SrsReviewGestureMap.defaults.arming(side, hideHardEasy: false),
          SrsCardGestureArming.none,
        );
      }
    });

    test('空串 / 坏 JSON / 非对象都回落默认', () {
      for (final String raw in <String>[
        '',
        '  ',
        '{',
        '[1,2]',
        '"x"',
        'null',
      ]) {
        expect(SrsReviewGestureMap.decode(raw), SrsReviewGestureMap.defaults);
      }
    });
  });

  group('两面可选动作', () {
    test('显示答案只在问题面，评分只在答案面', () {
      expect(
        SrsReviewGestureAction.choicesFor(front),
        contains(SrsReviewGestureAction.showAnswer),
      );
      expect(
        SrsReviewGestureAction.choicesFor(front),
        isNot(contains(SrsReviewGestureAction.rateGood)),
      );
      expect(
        SrsReviewGestureAction.choicesFor(back),
        containsAll(<SrsReviewGestureAction>[
          SrsReviewGestureAction.rateAgain,
          SrsReviewGestureAction.rateHard,
          SrsReviewGestureAction.rateGood,
          SrsReviewGestureAction.rateEasy,
        ]),
      );
      expect(
        SrsReviewGestureAction.choicesFor(back),
        isNot(contains(SrsReviewGestureAction.showAnswer)),
      );
    });

    test('绑到不许的一面抛错', () {
      expect(
        () => SrsReviewGestureMap.defaults.withBinding(
          front,
          SrsReviewGesture.swipeLeft,
          SrsReviewGestureAction.rateAgain,
        ),
        throwsArgumentError,
      );
    });

    test('两面互不影响', () {
      final SrsReviewGestureMap m = SrsReviewGestureMap.defaults
          .withBinding(
            front,
            SrsReviewGesture.tapRight,
            SrsReviewGestureAction.showAnswer,
          )
          .withBinding(
            back,
            SrsReviewGesture.tapRight,
            SrsReviewGestureAction.rateGood,
          );
      expect(
        m.resolve(front, SrsReviewGesture.tapRight, hideHardEasy: false),
        SrsReviewGestureAction.showAnswer,
      );
      expect(
        m.resolve(back, SrsReviewGesture.tapRight, hideHardEasy: false),
        SrsReviewGestureAction.rateGood,
      );
      expect(
        m.resolve(front, SrsReviewGesture.tapLeft, hideHardEasy: false),
        SrsReviewGestureAction.toggleToolbar,
      );
      expect(m.isDefault, isFalse);
    });
  });

  group('「只留重来 / 良好」', () {
    final SrsReviewGestureMap m = SrsReviewGestureMap.defaults
        .withBinding(
          back,
          SrsReviewGesture.swipeLeft,
          SrsReviewGestureAction.rateHard,
        )
        .withBinding(
          back,
          SrsReviewGesture.swipeRight,
          SrsReviewGestureAction.rateEasy,
        )
        .withBinding(
          back,
          SrsReviewGesture.swipeUp,
          SrsReviewGestureAction.rateGood,
        );

    test('绑在困难 / 简单上的手势什么都不做，重来 / 良好照常', () {
      expect(
        m.resolve(back, SrsReviewGesture.swipeLeft, hideHardEasy: true),
        SrsReviewGestureAction.none,
      );
      expect(
        m.resolve(back, SrsReviewGesture.swipeRight, hideHardEasy: true),
        SrsReviewGestureAction.none,
      );
      expect(
        m.resolve(back, SrsReviewGesture.swipeUp, hideHardEasy: true),
        SrsReviewGestureAction.rateGood,
      );
      expect(
        m.resolve(back, SrsReviewGesture.swipeLeft, hideHardEasy: false),
        SrsReviewGestureAction.rateHard,
      );
      // 存下来的绑定不变（关掉开关就恢复）。
      expect(
        m.actionFor(back, SrsReviewGesture.swipeLeft),
        SrsReviewGestureAction.rateHard,
      );
    });

    test('被屏蔽的轴不开识别器', () {
      expect(
        m.arming(back, hideHardEasy: true),
        const SrsCardGestureArming(swipeVertical: true),
      );
      expect(
        m.arming(back, hideHardEasy: false),
        const SrsCardGestureArming(swipeHorizontal: true, swipeVertical: true),
      );
      expect(m.arming(front, hideHardEasy: false), SrsCardGestureArming.none);
    });
  });

  group('持久化', () {
    test('往返', () {
      final SrsReviewGestureMap m = SrsReviewGestureMap.defaults
          .withBinding(
            front,
            SrsReviewGesture.doubleTap,
            SrsReviewGestureAction.showAnswer,
          )
          .withBinding(
            back,
            SrsReviewGesture.longPress,
            SrsReviewGestureAction.editNote,
          );
      final String raw = m.encode();
      final Map<String, dynamic> json = jsonDecode(raw) as Map<String, dynamic>;
      expect(json['v'], SrsReviewGestureMap.version);
      expect(
        (json['front'] as Map<String, dynamic>)['double_tap'],
        'show_answer',
      );
      expect((json['back'] as Map<String, dynamic>)['long_press'], 'edit_note');
      expect(SrsReviewGestureMap.decode(raw), m);
    });

    test('缺的 / 不认识的动作 / 这一面不许的动作取默认', () {
      final SrsReviewGestureMap m = SrsReviewGestureMap.decode(
        jsonEncode(<String, Object>{
          'v': 1,
          'front': <String, Object>{
            'tap_left': 'warp_drive',
            'tap_right': 'rate_good',
            'swipe_up': 'undo',
            'double_tap': 3,
          },
          'back': 'nope',
        }),
      );
      expect(
        m.actionFor(front, SrsReviewGesture.tapLeft),
        SrsReviewGestureAction.toggleToolbar,
      );
      expect(
        m.actionFor(front, SrsReviewGesture.tapRight),
        SrsReviewGestureAction.toggleToolbar,
        reason: '问题面不许评分',
      );
      expect(
        m.actionFor(front, SrsReviewGesture.swipeUp),
        SrsReviewGestureAction.undo,
      );
      expect(
        m.actionFor(front, SrsReviewGesture.doubleTap),
        SrsReviewGestureAction.none,
      );
      for (final SrsReviewGesture g in SrsReviewGesture.values) {
        expect(m.actionFor(back, g), SrsReviewGestureMap.defaultActionFor(g));
      }
    });

    test('更新版本写的值：认识的照读，不认识的手势名改别的映射后写回也不丢', () {
      final SrsReviewGestureMap m = SrsReviewGestureMap.decode(
        jsonEncode(<String, Object>{
          'v': 7,
          'front': <String, Object>{
            'swipe_left': 'undo',
            'triple_tap': 'show_answer',
          },
          'back': <String, Object>{'two_finger_tap': 'rate_good'},
        }),
      );
      expect(
        m.actionFor(front, SrsReviewGesture.swipeLeft),
        SrsReviewGestureAction.undo,
      );
      final SrsReviewGestureMap edited = m.withBinding(
        back,
        SrsReviewGesture.swipeUp,
        SrsReviewGestureAction.rateAgain,
      );
      final Map<String, dynamic> json =
          jsonDecode(edited.encode()) as Map<String, dynamic>;
      expect(
        (json['front'] as Map<String, dynamic>)['triple_tap'],
        'show_answer',
      );
      expect(
        (json['back'] as Map<String, dynamic>)['two_finger_tap'],
        'rate_good',
      );
      expect((json['back'] as Map<String, dynamic>)['swipe_up'], 'rate_again');
    });
  });

  group('点按分区', () {
    test('横向三等分', () {
      SrsTapZone z(double x) => srsTapZoneOf(x, left: 100, width: 300);
      expect(z(100), SrsTapZone.left);
      expect(z(199.9), SrsTapZone.left);
      expect(z(200), SrsTapZone.center);
      expect(z(299.9), SrsTapZone.center);
      expect(z(300), SrsTapZone.right);
      expect(z(399), SrsTapZone.right);
      expect(srsTapZoneOf(5, left: 0, width: 0), SrsTapZone.center);
      expect(srsTapGestureOf(SrsTapZone.left), SrsReviewGesture.tapLeft);
      expect(srsTapGestureOf(SrsTapZone.center), SrsReviewGesture.tapCenter);
      expect(srsTapGestureOf(SrsTapZone.right), SrsReviewGesture.tapRight);
    });
  });

  group('滑动判定', () {
    test('够远就算，方向按主轴', () {
      expect(
        srsClassifySwipe(const Offset(-120, 10), Offset.zero),
        SrsReviewGesture.swipeLeft,
      );
      expect(
        srsClassifySwipe(const Offset(120, -10), Offset.zero),
        SrsReviewGesture.swipeRight,
      );
      expect(
        srsClassifySwipe(const Offset(5, -130), Offset.zero),
        SrsReviewGesture.swipeUp,
      );
      expect(
        srsClassifySwipe(const Offset(-5, 130), Offset.zero),
        SrsReviewGesture.swipeDown,
      );
    });

    test('不够远、没甩快、斜着划都不算', () {
      expect(srsClassifySwipe(const Offset(-60, 0), Offset.zero), isNull);
      expect(
        srsClassifySwipe(const Offset(-120, 100), Offset.zero),
        isNull,
        reason: '主轴不到副轴 1.5 倍',
      );
      expect(
        srsClassifySwipe(const Offset(-30, 0), const Offset(-2000, 0)),
        isNull,
        reason: '甩得再快也要走过最小距离',
      );
    });

    test('快速甩动：距离不到提交线也算，但速度要与位移同向', () {
      expect(
        srsClassifySwipe(const Offset(-60, 0), const Offset(-900, 0)),
        SrsReviewGesture.swipeLeft,
      );
      expect(
        srsClassifySwipe(const Offset(-60, 0), const Offset(900, 0)),
        isNull,
        reason: '拉回去了',
      );
    });

    test('只按开着的轴判', () {
      expect(
        srsClassifySwipe(const Offset(-120, 0), Offset.zero, horizontal: false),
        isNull,
      );
      expect(
        srsClassifySwipe(const Offset(0, 130), Offset.zero, vertical: false),
        isNull,
      );
    });

    test('拖动预览：按主轴锁定位移，进度到提交线为 1', () {
      final ({SrsReviewGesture gesture, Offset offset, double progress})? p =
          srsSwipePreview(const Offset(-48, 6));
      expect(p!.gesture, SrsReviewGesture.swipeLeft);
      expect(p.offset, const Offset(-48, 0));
      expect(p.progress, closeTo(0.5, 1e-9));
      expect(srsSwipePreview(const Offset(-200, 0))!.progress, 1);
      expect(srsSwipePreview(const Offset(40, 40)), isNull);
      expect(srsSwipePreview(const Offset(0, 50), vertical: false), isNull);
    });
  });

  group('页内载荷', () {
    test('CSS 像素按平台视图尺寸换成逻辑像素，落点换成全局', () {
      final SrsCardGestureEvent? e = srsCardGestureFromPage(
        jsonEncode(<String, Object>{
          't': 'release',
          'x': 100,
          'y': 50,
          'dx': -200,
          'dy': 4,
          'vx': -1000,
          'vy': 0,
          'vw': 400,
          'vh': 300,
        }),
        viewWidth: 800,
        viewHeight: 600,
        toGlobal: (Offset local) => local + const Offset(10, 20),
      );
      expect(e!.kind, SrsCardGestureKind.release);
      expect(e.position, const Offset(210, 120));
      expect(e.delta, const Offset(-400, 8));
      expect(e.velocity, const Offset(-2000, 0));
    });

    test('不认识的载荷丢掉', () {
      Offset id(Offset o) => o;
      for (final Object? raw in <Object?>[
        null,
        3,
        'not json',
        '[]',
        '{"t":"explode"}',
      ]) {
        expect(
          srsCardGestureFromPage(
            raw,
            viewWidth: 1,
            viewHeight: 1,
            toGlobal: id,
          ),
          isNull,
        );
      }
      expect(
        srsCardGestureFromPage(
          '{"t":"tap","x":"a"}',
          viewWidth: 1,
          viewHeight: 1,
          toGlobal: id,
        )!.position,
        Offset.zero,
      );
    });
  });
}
