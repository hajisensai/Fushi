import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/cover_ui/cover_aspect_probe.dart';
import 'package:hibiki/src/media/video/cover_ui/landscape_cover_image.dart';
import 'package:hibiki/src/media/video/cover_ui/portrait_cover_image.dart';

import '../helpers/source_guard.dart';

/// TODO-2426 守卫：两个槽向封面组件收敛到同一内核，且**只**收敛到该收敛的地方。
///
/// 结论（依据见 PR 说明）：`PortraitCoverImage` 与 `LandscapeCoverImage` **不合并**
/// —— 它们的渲染分支是两种槽位的真实产品差异（overlays 层序 / 前景 alignment +
/// padding / 模糊强度 / 合槽分支要不要包 Stack），硬合会把差异变成一堆构造参数和
/// `overlays.isEmpty ? ... : ...` 特例。真正重复的是「取图片宽高比」那段逐字相同的
/// [ImageStream] 状态机，那部分抽成 [CoverAspectProbe]。
///
/// 这组守卫锁两件事：
/// 1. 状态机不许再各写一份（回归 = 两侧生命周期/首帧策略再次漂开）；
/// 2. 「横图」阈值只有一个真相源（此前两处各写一个 `1.2`，改一个不带动另一个），
///    但竖槽自己的 0.85 是**不同的判据**，收敛不得把它一并抹平。
void main() {
  const String probePath =
      'lib/src/media/video/cover_ui/cover_aspect_probe.dart';
  const List<String> componentPaths = <String>[
    'lib/src/media/video/cover_ui/portrait_cover_image.dart',
    'lib/src/media/video/cover_ui/landscape_cover_image.dart',
  ];

  group('共享内核', () {
    test('两个组件的 State 都 with CoverAspectProbe', () {
      for (final String path in componentPaths) {
        final String src = File(path).readAsStringSync();
        expect(containsCodeLine(src, 'with CoverAspectProbe<'), isTrue,
            reason: '$path 必须复用共享的宽高比探测内核，不得自建');
        expect(containsCodeLine(src, 'ImageProvider probedImageOf('), isTrue,
            reason: '$path 必须实现 probedImageOf，前景与探测共用同一 provider');
      }
    });

    test('组件文件里不得再各自实现 ImageStream 状态机', () {
      // 这些符号是状态机自身的零件；它们只该出现在 cover_aspect_probe.dart 里。
      const List<String> machineParts = <String>[
        'ImageStreamListener(',
        'ImageStream? ',
        'addListener(',
        'removeListener(',
        'void didChangeDependencies()',
        'void dispose()',
      ];
      for (final String path in componentPaths) {
        final String src = File(path).readAsStringSync();
        for (final String part in machineParts) {
          expect(containsCodeLine(src, part), isFalse,
              reason: '$path 又自建了状态机零件「$part」——两侧生命周期会再次漂开');
        }
      }
      final String probe = File(probePath).readAsStringSync();
      for (final String part in machineParts) {
        expect(containsCodeLine(probe, part), isTrue,
            reason: '状态机零件「$part」必须留在共享内核里，否则上面的禁止判据是空转');
      }
    });
  });

  group('阈值真相源', () {
    test('横图阈值三处同值，且组件里不得再写裸字面量', () {
      expect(PortraitCoverImage.landscapeAspectThreshold,
          kCoverLandscapeAspectThreshold);
      expect(LandscapeCoverImage.landscapeAspectThreshold,
          kCoverLandscapeAspectThreshold);
      for (final String path in componentPaths) {
        final String src = File(path).readAsStringSync();
        expect(containsCodeLine(src, 'landscapeAspectThreshold = 1.2'), isFalse,
            reason: '$path 又把 1.2 抄了一份——改一处不会带动另一处');
        expect(
            containsCodeLine(src,
                'landscapeAspectThreshold = kCoverLandscapeAspectThreshold'),
            isTrue,
            reason: '$path 的横图阈值必须指向唯一真相源');
      }
    });

    test('压暗色同值，且竖槽自己的 0.85 判据必须保留（不是该收敛的东西）', () {
      expect(LandscapeCoverImage.backdropDimColor, kCoverBackdropDimColor);
      expect(PortraitCoverImage.portraitAspectThreshold, 0.85);
      expect(
          PortraitCoverImage.portraitAspectThreshold ==
              kCoverLandscapeAspectThreshold,
          isFalse,
          reason: '竖槽默认判据（w/h > 0.85 才垫底）与横图判据是两个不同的东西，'
              '收敛不得把它一并抹成 1.2');
    });

    test('两侧模糊强度**有意**不同，收敛不得把它抹平', () {
      // 宽幅槽的垫底被放大约 4.5 倍，同样 sigma 相对画面显得太锐（组件注释有记）。
      expect(LandscapeCoverImage.backdropBlurSigma, 28);
      expect(PortraitCoverImage.backdropBlurSigma, 14);
    });
  });

  group('内核行为：换 provider 的生命周期', () {
    Future<Uint8List> pngBytes(int width, int height) async {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawRect(
        ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        ui.Paint()..color = const ui.Color(0xFF3355FF),
      );
      final ui.Image image =
          await recorder.endRecording().toImage(width, height);
      final ByteData? data =
          await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    }

    const Key fgKey = Key('probe_foreground');

    /// 装上 [provider]；[decode] 为真时等真实解码完成（尺寸回调已应用）。
    Future<void> pumpWith(
      WidgetTester tester,
      MemoryImage provider, {
      required bool decode,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 100,
              height: 150,
              child: PortraitCoverImage(image: provider, imageKey: fgKey),
            ),
          ),
        ),
      );
      if (decode) {
        await tester.runAsync<void>(
          () => precacheImage(provider, tester.element(find.byKey(fgKey))),
        );
      }
      await tester.pump();
    }

    BoxFit? fitOf(WidgetTester tester) =>
        tester.widget<Image>(find.byKey(fgKey)).fit;

    testWidgets('换成另一朝向的图，解码完成后槽向判定跟着切换', (WidgetTester tester) async {
      final Uint8List portraitBytes =
          (await tester.runAsync<Uint8List>(() => pngBytes(20, 30)))!;
      final Uint8List landscapeBytes =
          (await tester.runAsync<Uint8List>(() => pngBytes(32, 18)))!;

      await pumpWith(tester, MemoryImage(portraitBytes), decode: true);
      expect(fitOf(tester), BoxFit.cover);
      expect(find.byType(ImageFiltered), findsNothing);

      await pumpWith(tester, MemoryImage(landscapeBytes), decode: true);
      expect(fitOf(tester), BoxFit.contain,
          reason: '换成横图后竖槽必须切到垫底 + contain（监听要重新挂到新 stream）');
      expect(find.byType(ImageFiltered), findsOneWidget);
    });

    testWidgets('换 provider 的那一帧必须先丢掉旧宽高比，不能拿上一张图的朝向渲染',
        (WidgetTester tester) async {
      final Uint8List landscapeBytes =
          (await tester.runAsync<Uint8List>(() => pngBytes(32, 18)))!;
      final Uint8List otherBytes =
          (await tester.runAsync<Uint8List>(() => pngBytes(21, 31)))!;

      await pumpWith(tester, MemoryImage(landscapeBytes), decode: true);
      expect(fitOf(tester), BoxFit.contain, reason: '前置条件：横图进竖槽走垫底');

      // 新 provider 尚未解码：此刻宽高比必须是「未知」，按合槽 cover 渲染。
      // 若 didUpdateWidget 忘了把旧宽高比清空，这一帧会拿上一张图的朝向渲染，
      // 用户看到的是「换了图，垫底/裁切却还按旧图来」，直到新图解码完才跳变。
      await pumpWith(tester, MemoryImage(otherBytes), decode: false);
      expect(fitOf(tester), BoxFit.cover,
          reason: '换图未解码完的过渡帧必须回到「尺寸未知 = 合槽 cover」');
      expect(find.byType(ImageFiltered), findsNothing);
    });
  });
}
