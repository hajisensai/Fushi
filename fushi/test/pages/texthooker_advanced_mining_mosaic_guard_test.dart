// galgame texthooker 页「高级制卡 → 打码」接线守卫。
//
// 对话框确认后以 `releaseWhenPayloadConsumed: true` 回点弹窗「+」，覆盖项随 fields 走；
// 打码必须：① 覆盖项在首个 await 之前同步读出；② 把对话框冻结的那一帧（预览 / 打码
// 用的同一张图）连同打码区域交给协调器——出卡图与预览同源。texthooker 页起真 app 才
// 有外部窗口会话，这条接线只能在源码层咬住；协调器侧的行为在
// `test/mining/gal_hook_mining_coordinator_test.dart` 的「高级制卡打码」组里真跑。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  late String src;
  setUpAll(
    () => src = File(
      'lib/src/pages/implementations/texthooker_page.dart',
    ).readAsStringSync(),
  );

  test('外部窗口模式给高级制卡一个静态截图分区，开窗当下冻结那一帧', () {
    final String body = compactCode(
      maskComments(
        methodBody(
          src,
          'Future<AdvancedMiningSections> buildAdvancedMiningSections(',
        ),
      ),
    );
    expect(
      body.contains('stillImage:AdvancedMiningStillImageSection('),
      isTrue,
    );
    expect(
      body.contains(
        'GalHookMiningCoordinator.instance.captureBoundWindowStill()',
      ),
      isTrue,
    );
    expect(
      body.contains('_advancedMiningStill=GalHookLineScreenshot('),
      isTrue,
    );
    expect(body.contains('mosaicForcesStill:!mode.isStill'), isTrue);
    // 历史台词：与协调器 staleScene 同一判据，对话框据此提示「不是那句当时的画面」。
    expect(
      body.contains('historical=live.isEmpty||live.last.id!=lineId;'),
      isTrue,
    );
    expect(body.contains('historicalLine:historical,'), isTrue);
  });

  test('外部窗口制卡 / 覆盖：覆盖项在首个 await 之前读出', () {
    for (final String signature in <String>[
      'Future<MinePopupResult> onMineEntry(',
      'Future<MinePopupResult> onUpdateEntry(',
    ]) {
      final String code = compactCode(maskComments(methodBody(src, signature)));
      final int read = code.indexOf(
        'overrides:MiningRequestOverrides.readFrom(fields)',
      );
      expect(read, isNonNegative, reason: '$signature 必须读覆盖项');
      // 外部窗口分支是 return 表达式里同步调用 _mineActiveLine，覆盖项作为实参在调用
      // 当下就读出（不在任何 await 之后）。
      final int call = code.indexOf('return_mineActiveLine(');
      expect(call, isNonNegative);
      expect(read, greaterThan(call));
      expect(code.substring(call, read).contains('await'), isFalse);
    }
  });

  test('打码区域与冻结帧在首个 await 之前取出，并交给协调器', () {
    final String code = compactCode(
      maskComments(methodBody(src, 'Future<MinePopupResult> _mineActiveLine(')),
    );
    final int firstAwait = code.indexOf('await');
    expect(code.indexOf('overrides?.mosaic'), inInclusiveRange(0, firstAwait));
    expect(
      code.indexOf(':_advancedMiningStill;'),
      inInclusiveRange(0, firstAwait),
    );
    expect(code.contains('mosaic:mosaic,previewStill:previewStill,'), isTrue);
  });
}
