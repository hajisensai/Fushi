// BUG-1332：带 `\pos` 的字幕不避让控制条、画在暂停键之上。
//
// 用户片源真值（[Nekomoe kissaten&VCB-Studio] Tensei Oujo to Tensai Reijou no Mahou
// Kakumei，PlayResX 1280 / PlayResY 720）：
//
//   Dialogue: 0,0:00:41.35,0:00:44.48,OP_JP,,0,0,0,,{\an7\pos(461,672)\fad(250,250)\blur2}手
//
// y=672/720 = 93.3%，正是进度条那一条。旧实现里 `\pos` 分支直接走裸 Positioned 返回，
// controlsVisible / reserve 一概不参与——避让契约被挂在「定位分支」而不是「字幕层」上。
// 本组测试钉死：绝对定位分支与锚点分支（_paddingFor）共用同一条取下限避让语义。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki/src/media/video/video_subtitle_style.dart';

void main() {
  // 1080p 显示区 + 桌面控制条几何。
  const Size container = Size(1920, 1080);
  const double bottomReserve = kVideoControlsBottomReserve; // 56
  const double topReserve = 60;
  // 片源真值：\pos(461,672) 在 1280x720 画布 → 归一后落到 1080p 显示区。
  const Offset opCharPos =
      Offset(461 / 1280 * 1920, 672 / 720 * 1080); // dy=1008
  // OP_JP Fontsize 38（720 画布）→ 1080p 上约 57px 高的单字盒。
  const Size charBox = Size(57, 57);
  // \an7 = 左上锚点。
  const double an7Fx = 0;
  const double an7Fy = 0;

  Offset resolve({
    Offset pos = opCharPos,
    Size child = charBox,
    double anchorFx = an7Fx,
    double anchorFy = an7Fy,
    double dodgeProgress = 1,
    double top = topReserve,
    double bottom = bottomReserve,
  }) =>
      resolveAbsoluteCueOffset(
        pos: pos,
        container: container,
        child: child,
        anchorFx: anchorFx,
        anchorFy: anchorFy,
        topReserve: top,
        bottomReserve: bottom,
        dodgeProgress: dodgeProgress,
      );

  group('\\pos 绝对定位盒的 chrome 避让（BUG-1332）', () {
    test('控制条隐藏时逐像素等于作者 \\pos（不改变既有外观）', () {
      final Offset o = resolve(dodgeProgress: 0);
      expect(o.dy, closeTo(1008, 0.01), reason: '\\an7 顶锚：盒顶就落在 \\pos 的 y 上');
      expect(o.dx, closeTo(461 / 1280 * 1920, 0.01));
    });

    test('控制条可见时 OP 逐字歌词被抬到恰骑进度条上缘（用户报的原始失败路径）', () {
      final Offset o = resolve();
      // 作者位盒底 1008+57=1065 > 可用带底 1080-56=1024 → 上抬 41px。
      expect(o.dy + charBox.height,
          closeTo(container.height - bottomReserve, 0.01),
          reason: '盒底应恰骑控制条上缘，既不被压住也不飞');
      expect(o.dy, lessThan(1008), reason: '必须是上抬');
    });

    test('取下限而非加法：盒底没探进控制条带的 \\pos 字幕坐标一动不动', () {
      // 画面中部的招牌/特效：盒底 600+57 远在 1024 之上。
      final Offset o = resolve(pos: const Offset(300, 600));
      expect(o.dy, closeTo(600, 0.01),
          reason: '加法叠加会把它凭空多抬一个 reserve（TODO-161 顶飞回归）');
    });

    test('避让只上抬、绝不把字幕往下拽', () {
      // 一个已经很高的 \pos：避让后不得变大（变大=下移）。
      final Offset lifted = resolve(pos: const Offset(300, 100));
      expect(lifted.dy, lessThanOrEqualTo(100 + 0.01));
    });

    test('顶部 chrome 同契约：只下压到顶栏下缘，且不把低位盒往上顶', () {
      final Offset o = resolve(pos: const Offset(300, 5));
      expect(o.dy, closeTo(topReserve, 0.01),
          reason: '盒顶探进顶栏 → 压到其下缘（BUG-1069 同契约）');
      final Offset low = resolve(pos: const Offset(300, 500));
      expect(low.dy, closeTo(500, 0.01), reason: '顶栏避让不得把画面中部的盒往上顶');
    });

    test('控制条淡入淡出期在作者位与避让位之间插值（与 AnimatedPadding 同手感）', () {
      final Offset at0 = resolve(dodgeProgress: 0);
      final Offset at1 = resolve(dodgeProgress: 1);
      final Offset half = resolve(dodgeProgress: 0.5);
      expect(half.dy, closeTo((at0.dy + at1.dy) / 2, 0.01));
    });

    test('水平坐标恒为作者位——横向出屏另有根因（\\fn@ 竖排字体），不得用钳制掩盖', () {
      // 片源真值：{\an2\frz270\pos(10,360)} 竖排歌词，x 极小。
      final Offset o = resolve(
        pos: const Offset(10 / 1280 * 1920, 360 / 720 * 1080),
        anchorFx: 0.5,
        anchorFy: 1,
        child: const Size(700, 57),
      );
      expect(o.dx, closeTo(10 / 1280 * 1920 - 350, 0.01),
          reason: 'x 必须原样透传（含负值）；钳到屏内会把竖排字体未支持这个真 bug 盖住');
    });

    test('可用带比字幕盒还矮时顶部优先，结果确定不抖', () {
      final Offset o = resolve(
        pos: const Offset(300, 900),
        child: const Size(57, 1200),
        dodgeProgress: 1,
      );
      expect(o.dy, closeTo(topReserve, 0.01));
    });

    test('\\an 锚点比例参与作者位换算（\\an2 底居中）', () {
      final Offset o = resolve(
        pos: const Offset(960, 500),
        anchorFx: 0.5,
        anchorFy: 1,
        child: const Size(400, 60),
        dodgeProgress: 0,
      );
      expect(o.dx, closeTo(960 - 200, 0.01));
      expect(o.dy, closeTo(500 - 60, 0.01));
    });
  });

  group('源码守卫：避让契约不得随定位分支消失', () {
    final String src = File('lib/src/media/video/video_subtitle_overlay.dart')
        .readAsStringSync();

    test('\\pos 分支不得退回裸 Positioned（那正是 BUG-1332 的形状）', () {
      final int branch = src.indexOf('final Offset? posScreen = _posScreen(');
      expect(branch, greaterThanOrEqualTo(0), reason: '\\pos 定位分支应存在');
      final int branchEnd = src.indexOf('    // 无 \\pos：', branch);
      expect(branchEnd, greaterThan(branch));
      final String body = src.substring(branch, branchEnd);
      expect(body, contains('_absolutePositioned('),
          reason: '\\pos 分支必须走带避让的定位盒');
      expect(body, isNot(contains('FractionalTranslation')),
          reason: 'FractionalTranslation 在布局前定位、拿不到子盒尺寸，无法判断是否探进控制条');
    });

    test('绝对定位避让必须取下限（min/max），不得写成 reserve 加法', () {
      final int fn = src.indexOf('Offset resolveAbsoluteCueOffset(');
      expect(fn, greaterThanOrEqualTo(0));
      // 切到下一个顶层声明为止。不能用 '\n}' 找函数尾——具名参数列表的 '}) {' 也以 '}'
      // 开行，会把函数体整段切掉，守卫就永远只看参数签名（本测试首版即栽在这里）。
      final int fnEnd = src.indexOf('class _AbsoluteCueLayoutDelegate', fn);
      expect(fnEnd, greaterThan(fn));
      final String body = src.substring(fn, fnEnd);
      expect(body, contains('math.min(dodgedY, bandBottom - child.height)'),
          reason: '底部避让取下限：盒底骑控制条上缘');
      expect(body, contains('math.max(dodgedY, topReserve)'),
          reason: '顶部避让取下限（对称）');
      expect(body, isNot(contains('+ bottomReserve')),
          reason: '避让不能写成加法叠加（TODO-161 顶飞回归）');
    });
  });
}
