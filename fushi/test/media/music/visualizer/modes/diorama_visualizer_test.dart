import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_camera_path.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_camera_rig.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_particles.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_scene.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_scene_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_sequencer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_tuning.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_visualizer.dart';

import '../visualizer_test_helpers.dart';

const double _eps = 1e-6;

DioramaLineCharacter _char(
  List<double> notes, {
  bool chorus = false,
  bool section = false,
}) => DioramaLineCharacter(
  noteSeconds: notes,
  isChorus: chorus,
  sectionStart: section,
);

void main() {
  group('路径与坐标系', () {
    test('每句一帧，始终向前（-z），基向量正交单位', () {
      final List<DioramaFrame> frames = buildDioramaPath(40, 12345);
      expect(frames, hasLength(40));
      for (int i = 0; i < frames.length; i++) {
        final DioramaFrame f = frames[i];
        expect(f.forward.z, lessThan(0));
        expect(f.forward.length, closeTo(1, 1e-9));
        expect(f.right.length, closeTo(1, 1e-9));
        expect(f.up.length, closeTo(1, 1e-9));
        expect(f.forward.dot(f.right).abs(), lessThan(1e-9));
        expect(f.forward.dot(f.up).abs(), lessThan(1e-9));
        if (i > 0) {
          expect(
            f.position.distanceTo(frames[i - 1].position),
            closeTo(dioramaStepDistance, 1e-9),
          );
        }
      }
      // 同种子同路径
      expect(buildDioramaPath(40, 12345)[17].position.x, frames[17].position.x);
    });

    test('文字摆放：weave=0 收成居中、水平、不偏航', () {
      final DioramaTextPlacement p = dioramaTextPlacement(5, 99, 0);
      expect(p.offsetR, 0);
      expect(p.offsetU, 0);
      expect(p.roll, 0);
      expect(p.yaw, 0);
      expect(p.scale, inInclusiveRange(0.82, 1.28));
    });

    test('读头横移：tanh 饱和，不超过允许幅度', () {
      expect(resolveDioramaReadHeadTruck(0.5, 4, 3), closeTo(0, 1e-12));
      final double far = resolveDioramaReadHeadTruck(1, 20, 3);
      expect(far.abs(), lessThan((3 - 10).abs() + _eps));
      expect(resolveDioramaReadHeadTruck(1, 0, 3), 0);
    });
  });

  group('运镜', () {
    final List<DioramaLineCharacter> lines = <DioramaLineCharacter>[
      for (int i = 0; i < 60; i++)
        _char(
          i % 5 == 0
              ? <double>[2.0]
              : List<double>.filled(i % 3 == 0 ? 10 : 4, i.isEven ? 0.2 : 0.5),
          chorus: i % 7 < 2,
          section: i % 8 == 0,
        ),
    ];

    test('确定性，且整首用到多种运镜', () {
      final Set<DioramaShotKind> kinds = <DioramaShotKind>{};
      for (int i = 0; i < lines.length; i++) {
        final DioramaShotKind a = dioramaShotFor(
          i,
          lines,
          7,
          DioramaSubMode.normal,
        );
        expect(dioramaShotFor(i, lines, 7, DioramaSubMode.normal), a);
        kinds.add(a);
      }
      expect(kinds.length, greaterThanOrEqualTo(6));
    });

    test('moveScale=0 回到中性跟随机位', () {
      for (final DioramaShotKind k in DioramaShotKind.values) {
        final DioramaShotOffset o = resolveDioramaShotOffset(
          k,
          progress: 0.37,
          wordProgress: 0.6,
          hero: dioramaHeroDistance,
          lift: dioramaCameraLift,
          seed: 3,
          lineIndex: 4,
          moveScale: 0,
        );
        expect(o.right, closeTo(0, _eps), reason: k.name);
        expect(o.up, closeTo(dioramaCameraLift, _eps), reason: k.name);
        expect(o.back, closeTo(dioramaHeroDistance, _eps), reason: k.name);
      }
    });

    test('推进：开始远、结束近', () {
      double back(double p) => resolveDioramaShotOffset(
        DioramaShotKind.pushIn,
        progress: p,
        wordProgress: p,
        hero: dioramaHeroDistance,
        lift: dioramaCameraLift,
        seed: 1,
        lineIndex: 0,
        moveScale: 1,
      ).back;
      expect(back(0), greaterThan(back(1)));
    });

    test('停留回正：3 秒内为 1，8 秒后为 0', () {
      expect(resolveDioramaHoldSettle(2.9), 1);
      expect(resolveDioramaHoldSettle(5.5), inExclusiveRange(0, 1));
      expect(resolveDioramaHoldSettle(8.1), 0);
    });

    test('风格预设：平静更慢更小，激烈更快更大', () {
      final DioramaMotionParams calm = resolveDioramaMotionParams(
        cameraSpeed: 1,
        motionAmount: 1,
        audioReactivity: 1,
        subMode: DioramaSubMode.calm,
      );
      final DioramaMotionParams wild = resolveDioramaMotionParams(
        cameraSpeed: 1,
        motionAmount: 1,
        audioReactivity: 1,
        subMode: DioramaSubMode.chaotic,
      );
      expect(calm.moveScale, lessThan(wild.moveScale));
      expect(calm.smoothTime, greaterThan(wild.smoothTime));
      // 越界值被夹回范围
      final DioramaMotionParams clamped = resolveDioramaMotionParams(
        cameraSpeed: 99,
        motionAmount: 99,
        audioReactivity: -1,
        subMode: DioramaSubMode.normal,
      );
      expect(clamped.smoothTime, closeTo(0.42 / 1.85, 1e-12));
      expect(clamped.audioLevel, 0);
    });
  });

  group('阵列', () {
    test('每种运镜的阵列都避开文字与相机轨道、在文字平面后面', () {
      final DioramaFrame frame = buildDioramaPath(10, 42)[3];
      for (final DioramaShotKind shot in DioramaShotKind.values) {
        final DioramaTextPlacement p = dioramaTextPlacement(3, 42, 1);
        final List<DioramaShapePlacement> pieces = buildDioramaFormation(
          3,
          42,
          shot,
          frame,
          p,
        );
        expect(pieces, isNotEmpty, reason: shot.name);
        for (final DioramaShapePlacement s in pieces) {
          final DioramaVec rel = s.position - frame.position;
          final double r = rel.dot(frame.right) - p.offsetR;
          final double u = rel.dot(frame.up) - p.offsetU;
          final double d = rel.dot(frame.forward);
          expect(d, greaterThanOrEqualTo(1 - 1e-6), reason: shot.name);
          expect(
            math.sqrt(r * r + u * u),
            greaterThanOrEqualTo(2.8 - 1e-6),
            reason: shot.name,
          );
        }
      }
    });

    test('跨句相撞时早的句子赢；长廊模式不出点云', () {
      const DioramaVec at = DioramaVec(0, 0, -10);
      DioramaCluster cluster(int line) => DioramaCluster(
        shape: const DioramaShapePlacement(
          kind: DioramaShapeKind.sphere,
          position: at,
          scale: 0.5,
          stretchY: 1,
          colorSlot: 0,
          isFar: false,
        ),
        sourceLine: line,
        particleSeed: line,
      );
      const DioramaGeometryVisibility clouds = DioramaGeometryVisibility(
        enabled: true,
        corridor: false,
        strands: true,
        blobs: true,
        ribbons: true,
        rings: true,
      );
      final List<DioramaCluster> kept = dioramaSelectVisibleClusters(
        <DioramaCluster>[cluster(1), cluster(2)],
        clouds,
      );
      expect(kept.map((DioramaCluster c) => c.sourceLine), <int>[1]);
      // 同一句不算相撞
      expect(
        dioramaSelectVisibleClusters(<DioramaCluster>[
          cluster(1),
          cluster(1),
        ], clouds),
        hasLength(2),
      );
      const DioramaGeometryVisibility corridor = DioramaGeometryVisibility(
        enabled: true,
        corridor: true,
        strands: true,
        blobs: true,
        ribbons: true,
        rings: true,
      );
      expect(
        dioramaSelectVisibleClusters(<DioramaCluster>[cluster(1)], corridor),
        isEmpty,
      );
      const DioramaGeometryVisibility noBlobs = DioramaGeometryVisibility(
        enabled: true,
        corridor: false,
        strands: true,
        blobs: false,
        ribbons: true,
        rings: true,
      );
      expect(
        dioramaSelectVisibleClusters(<DioramaCluster>[cluster(1)], noBlobs),
        isEmpty,
      );
    });

    test('点阵：数量不超预算，法线是单位向量', () {
      for (final DioramaShapeKind k in DioramaShapeKind.values) {
        final DioramaSurface s = dioramaSurface(k, 288, 2.2);
        expect(s.count, inInclusiveRange(1, 288 * 2), reason: k.name);
        expect(s.radius, greaterThan(0));
        for (int i = 0; i < s.count; i += 7) {
          final double l = math.sqrt(
            s.normals[i * 3] * s.normals[i * 3] +
                s.normals[i * 3 + 1] * s.normals[i * 3 + 1] +
                s.normals[i * 3 + 2] * s.normals[i * 3 + 2],
          );
          expect(l, closeTo(1, 1e-5), reason: k.name);
        }
      }
    });

    test('尘埃：同一句永远写出同样的点，环形槽互不覆盖', () {
      final DioramaFrame f = buildDioramaPath(4, 1)[1];
      final Float32List fa = Float32List(dioramaMoteWindowLines * 8 * 3);
      final Float32List fb = Float32List(dioramaMoteWindowLines * 8 * 3);
      dioramaWriteMoteLine(fa, f, 5, 4, 2, 9);
      dioramaWriteMoteLine(fb, f, 5, 4, 2, 9);
      expect(fa, fb);
      // 只写自己的槽
      final int slot = dioramaMoteSlot(5) * 8 * 3;
      for (int i = 0; i < fa.length; i++) {
        if (i < slot || i >= slot + 8 * 3) expect(fa[i], 0);
      }
      expect(dioramaMoteSlot(5), isNot(dioramaMoteSlot(6)));
      expect(dioramaMoteSlot(-1), dioramaMoteWindowLines - 1);
    });
  });

  group('文字生命周期 / 取景 / 跟唱能量', () {
    test('文字距离生命周期两端为 0', () {
      expect(dioramaTextLife(45), 0);
      expect(dioramaTextLife(10), 1);
      expect(dioramaTextLife(0.5), 0);
    });

    test('几何生命周期：远处出生、近处溶掉', () {
      expect(resolveDioramaShapeLife(30), 0);
      expect(resolveDioramaShapeLife(10), 1);
      expect(resolveDioramaShapeLife(1), 0);
    });

    test('取景缩放夹在 [0.28, 1]', () {
      expect(
        dioramaFrameFitScale(0.1, dioramaHeroDistance, dioramaFovDeg, 1.7),
        1,
      );
      expect(
        dioramaFrameFitScale(1000, dioramaHeroDistance, dioramaFovDeg, 1.7),
        dioramaMinFitScale,
      );
    });

    test('渐变能量：唱前 0、保持 1、回落到 0', () {
      expect(dioramaGradientEnergy(0.9, 1, 2), 0);
      expect(dioramaGradientEnergy(1.5, 1, 2), closeTo(0.5, 1e-9));
      expect(dioramaGradientEnergy(2.2, 1, 2), 1);
      expect(dioramaGradientEnergy(2 + 0.35 + 1.8 + 0.01, 1, 2), 0);
    });

    test('邻行透明度：过去暗、未来更暗、远了为 0', () {
      expect(dioramaNeighborLineOpacity(-1), 0.3);
      expect(dioramaNeighborLineOpacity(1), 0.34);
      expect(dioramaNeighborLineOpacity(4), 0);
      expect(dioramaOutgoingLineOpacity(0), 0.7);
    });
  });

  group('场景行与走廊段', () {
    test('CJK 每字一个单元，拉丁每词一个，区间对得上排版文字', () {
      final List<DioramaSceneLine> lines = buildDioramaSceneLines(
        LyricVisualizerRuntime(sampleWordTimeline()),
      );
      expect(lines, hasLength(3));
      expect(lines[0].units.map((DioramaUnit u) => u.text), <String>[
        '夜',
        '空',
        'に',
        '光',
      ]);
      expect(lines[1].units.map((DioramaUnit u) => u.text), <String>[
        'Hello',
        'bright',
        'world',
      ]);
      for (final DioramaSceneLine l in lines) {
        for (final DioramaUnit u in l.units) {
          expect(l.layoutText.substring(u.charStart, u.charEnd), u.text);
          expect(u.end, greaterThanOrEqualTo(u.start));
        }
      }
      // 长间奏后的那句是段落开头
      expect(lines[2].character.sectionStart, isTrue);
      expect(lines[0].wordProgress(0.5), 0);
      expect(lines[0].wordProgress(1.15), inExclusiveRange(0, 0.5));
      expect(lines[0].wordProgress(10), 1);
    });

    test('行级歌词也能拆出单元', () {
      final List<DioramaSceneLine> lines = buildDioramaSceneLines(
        LyricVisualizerRuntime(sampleLineTimeline()),
      );
      expect(lines[0].units, hasLength(7));
      expect(lines[1].units.length, greaterThan(5));
    });

    test('追加 / 解析 / 原地换词 / 修剪', () {
      final DioramaSequencer seq = DioramaSequencer();
      final List<DioramaSceneLine> a = buildDioramaPhantomLines();
      final DioramaSegment s1 = seq.append(
        seed: 1,
        lines: a,
        round: 0,
        placementOrigin: DioramaVec.zero,
      );
      expect(seq.totalLines, dioramaInstrumentalFrames);
      final DioramaVec off = dioramaPickTransitionOffset(1, 1);
      expect(off.length, closeTo(dioramaTransitionDistance, 1e-9));
      expect(off.z, lessThan(0));
      final DioramaSegment s2 = seq.append(
        seed: 2,
        lines: a.sublist(0, 10),
        round: 0,
        placementOrigin: off,
      );
      expect(s2.globalStart, dioramaInstrumentalFrames);
      final DioramaResolvedLine? r = seq.resolve(dioramaInstrumentalFrames + 3);
      expect(r?.segment, same(s2));
      expect(r?.localIndex, 3);
      expect(r!.frame.position.distanceTo(off), greaterThan(0));
      seq.updateActiveLines(a.sublist(0, 20));
      expect(s2.span, 20);
      expect(s2.linesEpoch, 1);
      expect(seq.totalLines, dioramaInstrumentalFrames + 20);
      seq.prune(dioramaInstrumentalFrames + 5);
      expect(seq.segments, <DioramaSegment>[s2]);
      expect(s1.key, isNot(s2.key));
    });

    test('飞行缓动：两端速度为 0', () {
      expect(dioramaTransitionEase(0), 0);
      expect(dioramaTransitionEase(1), 1);
      expect(dioramaTransitionEase(0.001), lessThan(1e-6));
    });
  });

  group('相机', () {
    test('lookAt 后 -Z 指向目标；正前方的点投到画面中心', () {
      const DioramaVec eye = DioramaVec(1, 2, 3);
      const DioramaVec target = DioramaVec(-4, 0, -7);
      final DioramaQuat q = DioramaQuat.lookAt(eye, target, DioramaVec.worldUp);
      final DioramaVec fwd = q.rotate(const DioramaVec(0, 0, -1));
      final DioramaVec want = (target - eye).normalized;
      expect(fwd.distanceTo(want), lessThan(1e-9));
      final DioramaCamera cam = DioramaCamera(
        position: eye,
        orientation: q,
        width: 800,
        height: 600,
      );
      final (double x, double y, double d) = cam.project(target);
      expect(x, closeTo(400, 1e-6));
      expect(y, closeTo(300, 1e-6));
      expect(d, closeTo((target - eye).length, 1e-9));
    });

    test('四元数 slerp 两端与基变换', () {
      final DioramaQuat a = DioramaQuat.axisAngle(
        const DioramaVec(0, 1, 0),
        0.3,
      );
      final DioramaQuat b = DioramaQuat.axisAngle(
        const DioramaVec(0, 1, 0),
        1.3,
      );
      final DioramaQuat m = a.slerp(b, 0.5);
      final DioramaQuat expected = DioramaQuat.axisAngle(
        const DioramaVec(0, 1, 0),
        0.8,
      );
      expect(m.w, closeTo(expected.w, 1e-9));
      expect(m.y, closeTo(expected.y, 1e-9));
      final DioramaFrame f = buildDioramaPath(3, 5)[1];
      final DioramaQuat q = dioramaFrameQuaternion(f);
      expect(
        q.rotate(const DioramaVec(1, 0, 0)).distanceTo(f.right),
        lessThan(1e-9),
      );
      expect(
        q.rotate(const DioramaVec(0, 0, 1)).distanceTo(-f.forward),
        lessThan(1e-9),
      );
    });

    test('相机最终落在读头后方并看向它（中性机位）', () {
      final DioramaSequencer seq = DioramaSequencer();
      final List<DioramaSceneLine> lines = buildDioramaSceneLines(
        LyricVisualizerRuntime(sampleWordTimeline()),
      );
      seq.append(
        seed: 4,
        lines: lines,
        round: 0,
        placementOrigin: DioramaVec.zero,
      );
      final DioramaCameraRig rig = DioramaCameraRig();
      final DioramaMotionParams m = resolveDioramaMotionParams(
        cameraSpeed: 1,
        motionAmount: 1,
        audioReactivity: 1,
        subMode: DioramaSubMode.normal,
      );
      final DioramaResolvedLine r = seq.resolve(1)!;
      final DioramaCamera cam = rig.step(
        resolved: r,
        now: 3.5,
        delta: 0,
        elapsed: 0,
        motion: m,
        animate: false,
        activeLineWidth: 3,
        transitionEpoch: 0,
        width: 1280,
        height: 720,
      );
      final DioramaTextPlacement p = dioramaTextPlacement(1, 4, m.weaveScale);
      final DioramaVec head = r.frame.compose(p.offsetR, p.offsetU, 0);
      final (double x, double y, double d) = cam.project(head);
      expect(d, greaterThan(dioramaHeroDistance * 0.8));
      expect(x, inInclusiveRange(0, 1280));
      expect(y, inInclusiveRange(0, 720));
    });
  });

  group('对比度', () {
    test('看不清的点色被推到够用的对比', () {
      const Color bg = Color(0xFF101010);
      final Color fixed = dioramaEnsureContrast(const Color(0xFF151515), bg);
      expect(dioramaContrastRatio(fixed, bg), greaterThanOrEqualTo(2.99));
      const Color ok = Color(0xFFFFCC00);
      expect(dioramaEnsureContrast(ok, bg), ok);
    });
  });

  group('场景状态机', () {
    LyricVisualizerContext ctxFor(
      FakeVisualizerClock clock, {
      required String song,
      LyricTimeline? tl,
    }) {
      final LyricVisualizerContext base = visualizerContextFor(
        dioramaVisualizerEntry,
        clock: clock,
        timeline: tl,
      );
      return LyricVisualizerContext(
        timeline: base.timeline,
        runtime: base.runtime,
        clock: clock,
        offsetMs: 0,
        playing: true,
        palette: base.palette,
        tuning: base.tuning,
        seed: lyricVisualizerSeedOf(song),
        motion: true,
      );
    }

    void paintAt(DioramaScene scene, int ms, double elapsed) {
      final ui.PictureRecorder rec = ui.PictureRecorder();
      scene.paint(
        Canvas(rec),
        const Size(1280, 720),
        LyricVisualizerTick(timeMs: ms, elapsed: elapsed),
      );
      rec.endRecording().dispose();
    }

    testWidgets('读头粘滞、切歌开新走廊并飞行、飞完结束', (WidgetTester tester) async {
      final FakeVisualizerClock clock = FakeVisualizerClock();
      final DioramaScene scene = DioramaScene()
        ..update(ctxFor(clock, song: 'a'));
      paintAt(scene, 500, 0.0);
      expect(scene.globalIndex, 0);
      paintAt(scene, 3600, 0.1);
      expect(scene.globalIndex, 1);
      // 间奏：停在上一句
      paintAt(scene, 8000, 0.2);
      expect(scene.globalIndex, 1);
      paintAt(scene, 12300, 0.3);
      expect(scene.globalIndex, 2);
      expect(scene.segmentCount, 1);
      expect(scene.transitioning, isFalse);
      // 换歌
      scene.update(ctxFor(clock, song: 'b', tl: sampleLineTimeline()));
      paintAt(scene, 600, 0.4);
      expect(scene.segmentCount, 2);
      expect(scene.transitioning, isTrue);
      expect(scene.globalIndex, 3);
      paintAt(scene, 700, 0.4 + dioramaTransitionDuration + 0.1);
      expect(scene.transitioning, isFalse);
      // 一路往后唱，旧走廊被修剪
      paintAt(scene, 3500, 4.0);
      paintAt(scene, 3600, 4.1);
      expect(scene.segmentCount, lessThanOrEqualTo(2));
      // 循环：回到开头触发回飞（不新增段）
      final int segs = scene.segmentCount;
      paintAt(scene, 600, 4.2);
      expect(scene.transitioning, isTrue);
      expect(scene.segmentCount, segs);
      scene.dispose();
    });
  });

  group('挂载冒烟', () {
    testWidgets('默认参数', (WidgetTester tester) async {
      await pumpVisualizerAcross(tester, dioramaVisualizerEntry);
    });

    testWidgets('非默认参数：长廊 + 渐变 + 当前字出窍 + 激烈 + 关辉光', (
      WidgetTester tester,
    ) async {
      await pumpVisualizerAcross(
        tester,
        dioramaVisualizerEntry,
        tuning: <String, Object?>{
          DioramaTuningKeys.geometryMode: 'corridor',
          DioramaTuningKeys.gradientEnabled: true,
          DioramaTuningKeys.soulActiveEnabled: true,
          DioramaTuningKeys.cameraStyle: 'chaotic',
          DioramaTuningKeys.particleGlowEnabled: false,
          DioramaTuningKeys.glowEnabled: false,
          DioramaTuningKeys.particleDensity: 1536.0,
          DioramaTuningKeys.moteCircumference: 48.0,
          DioramaTuningKeys.moteRadial: 4.0,
        },
      );
    });

    testWidgets('非默认参数：平静 + 只留圆环 + 关背景粒子', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        dioramaVisualizerEntry,
        tuning: <String, Object?>{
          DioramaTuningKeys.cameraStyle: 'calm',
          DioramaTuningKeys.geometryStrands: false,
          DioramaTuningKeys.geometryBlobs: false,
          DioramaTuningKeys.geometryRibbons: false,
          DioramaTuningKeys.showParticles: false,
          DioramaTuningKeys.soulEnabled: false,
          DioramaTuningKeys.audioReactivity: 0.0,
        },
      );
    });

    testWidgets('行级歌词', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        dioramaVisualizerEntry,
        timeline: sampleLineTimeline(),
      );
    });

    testWidgets('减弱动态效果', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        dioramaVisualizerEntry,
        motion: false,
        playing: false,
      );
    });

    testWidgets('窄屏', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        dioramaVisualizerEntry,
        size: const Size(390, 844),
      );
    });

    testWidgets('窄屏 + 行级长句', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        dioramaVisualizerEntry,
        size: const Size(390, 844),
        timeline: sampleLineTimeline(),
      );
    });

    testWidgets('纯音乐（没有歌词）', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        dioramaVisualizerEntry,
        timeline: const LyricTimeline(format: 'lrc', lines: <LyricLine>[]),
      );
    });
  });
}
