/// Apple 侧「系统自带 OCR」（Vision）原生半边的静态守卫。
///
/// 这半边**一条 Dart 测试都碰不到**：`system_ocr_manga_service_test.dart` 验的是
/// `parseSystemOcrPayload` 这个纯函数，注入的是 fake channel；Swift 那边写错什么，
/// 在本机（Windows）与 CI 的 Dart 测试里全都是绿的，要到真机上打开一本漫画才发现
/// ——而它的失败形态偏偏和「这页真没字」长得一模一样。所以这里逐条钉住那些
/// **错了不会报错**的地方。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String swift = File('apple/FushiSystemOcr.swift').readAsStringSync();
  final String dart =
      File('lib/src/ocr/system_ocr_channel.dart').readAsStringSync();
  final String iosDelegate =
      File('ios/Runner/AppDelegate.swift').readAsStringSync();
  final String macosDelegate =
      File('macos/Runner/AppDelegate.swift').readAsStringSync();

  test('channel 名与 Dart 侧常量逐字一致', () {
    // Dart 那边是 `MethodChannel('app.fushi.reader/system_ocr')`；两边对不上时
    // Dart 收到的是 MissingPluginException → isAvailable() 返回 false → 引擎选项
    // 静默消失，看起来就像「这个平台不支持」。
    expect(dart, contains("MethodChannel('app.fushi.reader/system_ocr')"));
    expect(swift, contains('"app.fushi.reader/system_ocr"'));
  });

  test('iOS 与 macOS 两侧都注册了，不许只接一半', () {
    // 只接一半正是这个仓库反复出现的那类非对称 bug（「设置页能用、导入弹层不能用」
    // 的同构体）：两个平台共用同一份 Swift，漏注册的那端没有任何编译期信号。
    expect(iosDelegate, contains('FushiSystemOcr.register(binaryMessenger:'));
    expect(macosDelegate, contains('FushiSystemOcr.register(binaryMessenger:'));
  });

  test('两个 Xcode 工程都把这份 Swift 登记进了编译（四处齐全）', () {
    // pbxproj 漏登记不会有任何报错：文件躺在磁盘上、不进 Sources phase，
    // `FushiSystemOcr` 就是个未定义符号——但那是在 macOS 上编译时才发现的，
    // 本机根本编不了 Apple 目标。
    for (final String path in <String>[
      'ios/Runner.xcodeproj/project.pbxproj',
      'macos/Runner.xcodeproj/project.pbxproj',
    ]) {
      final String pbx = File(path).readAsStringSync();
      expect(
        pbx,
        contains('path = ../../apple/FushiSystemOcr.swift;'),
        reason: '$path 缺 PBXFileReference',
      );
      expect(
        pbx,
        contains('/* FushiSystemOcr.swift in Sources */ = {isa = PBXBuildFile;'),
        reason: '$path 缺 PBXBuildFile',
      );
      // group children + Sources phase：两处引用各一次，加上上面两条定义，共四处。
      expect(
        '/* FushiSystemOcr.swift */,'.allMatches(pbx).length,
        1,
        reason: '$path 的 PBXGroup children 里应恰好登记一次',
      );
      expect(
        '/* FushiSystemOcr.swift in Sources */,'.allMatches(pbx).length,
        1,
        reason: '$path 的 PBXSourcesBuildPhase 里应恰好登记一次',
      );
    }
  });

  test('payload 键名与 Dart 侧解析器期望的一致', () {
    // 键名写错 → parseSystemOcrPayload 读到 0 → 退化矩形被丢弃 → 整页零行。
    for (final String key in <String>[
      '"width"',
      '"height"',
      '"lines"',
      '"text"',
      '"left"',
      '"top"',
      '"right"',
      '"bottom"',
    ]) {
      expect(swift, contains(key), reason: 'payload 缺键 $key');
    }
  });

  test('y 轴翻过来了：Vision 原点在左下，Dart / Android 在左上', () {
    // 这条是全文件最容易错且**最安静**的一处：不翻 y，整页透明文字层上下颠倒，
    // 点哪都查不到词，但不会有任何报错。
    expect(swift, contains('(1 - box.maxY)'));
    expect(swift, contains('(1 - box.minY)'));
    // 左右不翻。
    expect(swift, contains('box.minX * w'));
    expect(swift, contains('box.maxX * w'));
  });

  test('不发 vertical：竖排判定只有 Dart 那一套', () {
    // Vision 与 ML Kit 都不报竖排，Dart 按包围盒长宽比统一推断。Swift 这边自己
    // 猜一个发过去，等于同一件事有两套判据，两边还会给出不同答案。
    expect(swift, isNot(contains('"vertical":')));
    expect(dart, contains('rect.height > rect.width'));
  });

  test('语言不受支持单独报 MODEL_UNAVAILABLE，不冒充识别失败', () {
    // iOS 15 的 Vision 没有 CJK（那是 iOS 16 起的 revision 3）。报成
    // RECOGNIZE_FAILED 会让用户去怀疑图片，而该做的是换引擎。
    expect(swift, contains('code: "MODEL_UNAVAILABLE"'));
    expect(swift, contains('code: "RECOGNIZE_FAILED"'));
    expect(swift, contains('code: "INVALID_IMAGE"'));
    expect(dart, contains("error.code == 'MODEL_UNAVAILABLE'"));
    expect(swift, contains('supportedRecognitionLanguages()'));
  });

  test('用 CGImageSource 解码，且按 .up 送检——尺寸与坐标同一个方向', () {
    // UIImage / NSImage 会把 EXIF 方向应用进去，尺寸和坐标系就和 Android 的
    // BitmapFactory（rotation 0）对不上，同一本漫画两个平台的框会不一样。
    expect(swift, contains('CGImageSourceCreateWithData'));
    expect(swift, contains('orientation: .up'));
    expect(swift, isNot(contains('UIImage(')));
    expect(swift, isNot(contains('NSImage(')));
  });

  test('识别不占主线程，回调切回主线程', () {
    expect(swift, contains('DispatchQueue.main.async { result('));
    expect(swift, contains('queue.async'));
  });

  test('isAvailable 便宜作答：不做真识别、不触发下载', () {
    // Dart 侧会把这个答案缓存进一次能力探测（system_ocr_channel.dart 的接口文档）。
    final int start = swift.indexOf('case "isAvailable":');
    final int end = swift.indexOf('case "recognize":');
    expect(start, greaterThan(-1));
    expect(end, greaterThan(start));
    final String body = swift.substring(start, end);
    expect(body, contains('supportedLanguages()'));
    expect(body, isNot(contains('VNImageRequestHandler')));
    expect(body, isNot(contains('perform(')));
  });
}
