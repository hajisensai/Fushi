import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_font_loader.dart';

/// 在飞去重（`_inFlight`）只能复用**成功**的结果。
///
/// 背景：`resolveAndLoadAll` 从串行 for 改成 `Future.wait` 之后，同一 family 的
/// 并发条目靠 `_inFlight[family]` 共享一个 future。但那张表里存的是 future 本身，
/// 成功和失败一视同仁——而 `_loadedFamilies.add(family)` 只在装载成功后才执行，
/// 所以在串行年代「第一个同名条目失败」**不会**污染后续条目：A 装 P1 失败返回
/// null，B 照常去装自己的 P2。改成共享 future 后，B 拿到 A 的 null 就直接返回，
/// **P2 永不被尝试**，family 整条不可用，UI/字幕/游戏文本一起回落到主题字体。
///
/// 触发条件不窄：`resolveAllHealth` 内部就是 `Future.wait`（同一条链的条目全部
/// 同时在飞），AppModel 又把 appUiFonts / videoSubtitleFonts / gameLookupFonts
/// 三条链并发跑，而「跨链同名家族」正是 `_inFlight` 存在的理由。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('同一 family：第一个文件坏掉不得让第二个文件不被尝试', () async {
    final Directory dir =
        await Directory.systemTemp.createTemp('font_inflight_');
    addTearDown(() => dir.delete(recursive: true));

    // `.woff` 走 FontDecoder.woffToSfnt，垃圾字节必定解不出 sfnt → 确定性失败，
    // 不依赖 FontLoader 对畸形字节的行为。
    final File broken = File('${dir.path}/broken.woff');
    await broken.writeAsBytes(List<int>.filled(64, 0x41));

    // 真字体：仓库自带的 Material Symbols（flutter test 的 cwd 是 fushi/ 包根）。
    const String good = 'assets/fonts/MaterialSymbolsRounded.ttf';
    expect(File(good).existsSync(), isTrue,
        reason: '测试依赖这份随包字体存在；它被挪走时本用例必须显式失败');

    // family 名带时间戳：`_loadedFamilies` 是进程级静态表，复用名字会让第二次
    // 运行在入口就短路，用例退化成恒真。
    final String family =
        'InflightProbe${DateTime.now().microsecondsSinceEpoch}';

    final List<String> families =
        await AppFontLoader.resolveAndLoadAll(<Map<String, dynamic>>[
      <String, dynamic>{'name': family, 'path': broken.path},
      <String, dynamic>{'name': family, 'path': good},
    ]);

    expect(families, <String>[family],
        reason: '第一个条目失败只说明那个文件不行；第二个同名条目必须照常被尝试，'
            '否则整个 family 因为一个坏文件而不可用');
  });
}
