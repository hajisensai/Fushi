import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/fushi_share.dart';
import 'package:share_plus/share_plus.dart';

/// TODO-1318 / BUG-608：验证 `FushiShare.shareFiles` 只走 share_plus 的
/// **非结果**方法通道（`shareFiles`），绝不走会命中 Android `ShareSuccessManager`
/// 回调状态机的**结果**通道（`shareFilesWithResult`），并带进程内防重入门。
///
/// 直接在方法通道层拦截（`dev.fluttercommunity.plus/share`），只依赖
/// flutter_test + share_plus，避免引入未声明依赖。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel =
      MethodChannel('dev.fluttercommunity.plus/share');
  final List<MethodCall> calls = <MethodCall>[];
  Completer<void>? gate;

  setUp(() {
    calls.clear();
    gate = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (MethodCall call) async {
      calls.add(call);
      if (gate != null) await gate!.future;
      return null;
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('只走非结果通道 shareFiles（绝不走 shareFilesWithResult 结果通道）', () async {
    await FushiShare.shareFiles(
      <XFile>[XFile('/tmp/pic.png', mimeType: 'image/png')],
      subject: 'pic',
    );
    expect(calls.length, 1);
    expect(calls.single.method, 'shareFiles',
        reason: '必须走非结果变体；shareFilesWithResult 会命中 ShareSuccessManager');
    expect(calls.single.method, isNot('shareFilesWithResult'));
    final Map<Object?, Object?> args =
        calls.single.arguments as Map<Object?, Object?>;
    expect(List<String>.from(args['paths']! as List<Object?>),
        <String>['/tmp/pic.png']);
    expect(List<String>.from(args['mimeTypes']! as List<Object?>),
        <String>['image/png']);
    expect(args['subject'], 'pic');
  });

  test('缺 mimeType 回退 */*（不收窄可分享目标）', () async {
    await FushiShare.shareFiles(<XFile>[XFile('/tmp/clip.mkv')]);
    final Map<Object?, Object?> args =
        calls.single.arguments as Map<Object?, Object?>;
    expect(List<String>.from(args['mimeTypes']! as List<Object?>),
        <String>['*/*']);
  });

  test('防重入：面板在途时第二次调用被丢弃，门复位后恢复', () async {
    gate = Completer<void>();
    // 第一次分享挂起（模拟系统面板尚未呈现完成）。
    final Future<void> first = FushiShare.shareFiles(
      <XFile>[XFile('/tmp/a.png', mimeType: 'image/png')],
    );
    await Future<void>.delayed(Duration.zero);
    expect(FushiShare.debugIsSharing, isTrue);

    // 重入调用必须被防重入门静默丢弃（不再触发平台调用）。
    await FushiShare.shareFiles(
      <XFile>[XFile('/tmp/b.png', mimeType: 'image/png')],
    );
    expect(calls.length, 1, reason: '重入调用必须被静默丢弃');

    // 放行第一次，门复位，后续分享恢复。
    gate!.complete();
    await first;
    expect(FushiShare.debugIsSharing, isFalse);

    await FushiShare.shareFiles(
      <XFile>[XFile('/tmp/c.png', mimeType: 'image/png')],
    );
    expect(calls.length, 2, reason: '门复位后分享应恢复');
  });

  test('空文件列表直接返回，不触发任何平台调用', () async {
    await FushiShare.shareFiles(<XFile>[]);
    expect(calls, isEmpty);
    expect(FushiShare.debugIsSharing, isFalse);
  });

  // ---- BUG-2064：iOS popover 锚点 ----
  //
  // share_plus 7.2.2 的 iOS 端（`FPPSharePlusPlugin.m`）把 text / uri / files
  // 三条路径汇进同一个 `+share:`，并在 popover 场景（iPad 必然、iPhone 横屏亦
  // 会）校验锚点 rect：`CGRectIsEmpty(origin)` 为真、或
  // `CGRectContainsRect(controller.view.frame, origin)` 为假，就直接抛
  // `PlatformException(error, sharePositionOrigin: argument must be set, ...)`。
  // 缺省 `sharePositionOrigin` 时 rect 就是 `CGRectZero`，两道校验必然不过。
  // 下面在方法通道层复刻这两道校验：只要分享入口漏传锚点，测试即红。

  /// 当前 view 的逻辑尺寸（= iOS 侧 `controller.view.frame` 的尺寸）。
  Size viewLogicalSize() {
    final FlutterView view = binding.platformDispatcher.views.first;
    return view.physicalSize / view.devicePixelRatio;
  }

  /// 从一次平台调用的参数里取回锚点 rect，并断言四个 key 都在。
  Rect originRectOf(MethodCall call) {
    final Map<Object?, Object?> args = call.arguments as Map<Object?, Object?>;
    for (final String key in const <String>[
      'originX',
      'originY',
      'originWidth',
      'originHeight',
    ]) {
      expect(args[key], isA<double>(),
          reason: '缺 $key 时 iOS 侧 originRect 退化为 CGRectZero，必抛 '
              'sharePositionOrigin 异常');
    }
    return Rect.fromLTWH(
      args['originX']! as double,
      args['originY']! as double,
      args['originWidth']! as double,
      args['originHeight']! as double,
    );
  }

  /// 复刻 iOS 侧两道校验。
  void expectValidIosAnchor(Rect origin, Size viewSize) {
    expect(origin.isEmpty, isFalse,
        reason: 'CGRectIsEmpty(origin) 为真会被 iOS 侧直接拒绝');
    final Rect viewRect = Offset.zero & viewSize;
    expect(
      viewRect.contains(origin.topLeft) &&
          viewRect.contains(origin.bottomRight),
      isTrue,
      reason: 'origin $origin 必须完全落在 source view $viewRect 内'
          '（CGRectContainsRect）',
    );
  }

  test('shareFiles 必带非空且落在 view 内的 iOS 锚点', () async {
    await FushiShare.shareFiles(
      <XFile>[XFile('/tmp/shot.jpg', mimeType: 'image/jpeg')],
    );
    expect(calls.single.method, 'shareFiles');
    expectValidIosAnchor(originRectOf(calls.single), viewLogicalSize());
  });

  test('shareText 必带非空且落在 view 内的 iOS 锚点', () async {
    await FushiShare.shareText('hello', subject: 'subject');
    expect(calls.single.method, 'share',
        reason: '文本分享同样走 iOS `+share:`，同样被校验锚点');
    final Map<Object?, Object?> args =
        calls.single.arguments as Map<Object?, Object?>;
    expect(args['text'], 'hello');
    expect(args['subject'], 'subject');
    expectValidIosAnchor(originRectOf(calls.single), viewLogicalSize());
  });

  test('shareText 空文本不触发平台调用（iOS 侧会以 Non-empty text expected 拒绝）',
      () async {
    await FushiShare.shareText('');
    expect(calls, isEmpty);
    expect(FushiShare.debugIsSharing, isFalse);
  });

  test('shareText 与 shareFiles 共用同一道防重入门', () async {
    gate = Completer<void>();
    final Future<void> first = FushiShare.shareText('first');
    await Future<void>.delayed(Duration.zero);
    expect(FushiShare.debugIsSharing, isTrue);

    await FushiShare.shareFiles(
      <XFile>[XFile('/tmp/a.png', mimeType: 'image/png')],
    );
    expect(calls.length, 1, reason: '面板在途时文件分享必须被同一道门丢弃');

    gate!.complete();
    await first;
    expect(FushiShare.debugIsSharing, isFalse);
  });

  group('sharePositionOriginForViewSize', () {
    test('正常尺寸下取 view 正中、非空、且完全被 view 包含', () {
      const Size viewSize = Size(874, 402);
      final Rect origin = FushiShare.sharePositionOriginForViewSize(viewSize);
      expect(origin.isEmpty, isFalse);
      expect(origin.center.dx, closeTo(437, 0.001));
      expect(origin.center.dy, closeTo(201, 0.001));
      final Rect viewRect = Offset.zero & viewSize;
      expect(viewRect.contains(origin.topLeft), isTrue);
      expect(viewRect.contains(origin.bottomRight), isTrue);
    });

    test('view 比锚点还小时锚点收缩，仍非空且不越界', () {
      const Size viewSize = Size(0.5, 0.25);
      final Rect origin = FushiShare.sharePositionOriginForViewSize(viewSize);
      expect(origin.isEmpty, isFalse);
      expect(origin.width, closeTo(0.5, 0.001));
      expect(origin.height, closeTo(0.25, 0.001));
      expect(origin.left, closeTo(0, 0.001));
      expect(origin.top, closeTo(0, 0.001));
    });

    test('非法尺寸退回合法的 1x1，绝不产出 CGRectZero', () {
      for (final Size viewSize in <Size>[
        Size.zero,
        const Size(-10, 100),
        const Size(double.nan, 100),
        const Size(double.infinity, double.infinity),
      ]) {
        final Rect origin = FushiShare.sharePositionOriginForViewSize(viewSize);
        expect(origin.isEmpty, isFalse, reason: '$viewSize 不得产出空 rect');
        expect(origin, const Rect.fromLTWH(0, 0, 1, 1), reason: '$viewSize');
      }
    });
  });

  // ---- BUG-2542：分享入口必须回报「面板到底有没有呈现」 ----
  //
  // 手机端的片段导出/备份导出/日志导出把产物落在 app 私有目录（不进相册、不注册
  // MediaStore），这次系统分享面板是用户取回文件的**唯一**通道。旧签名是
  // `Future<void>`，被防重入门丢弃时静默返回，调用方无从得知，于是照样弹「已保存」
  // ——面板没出现、相册里没有、私有目录进不去，文件等于凭空消失。
  group('分享结果回报（BUG-2542）', () {
    test('面板呈现成功返回 true', () async {
      expect(
        await FushiShare.shareFiles(
          <XFile>[XFile('/tmp/clip.mp4', mimeType: 'video/mp4')],
        ),
        isTrue,
      );
      expect(await FushiShare.shareText('hello'), isTrue);
    });

    test('被防重入门丢弃返回 false（不能让调用方误报成功）', () async {
      gate = Completer<void>();
      final Future<bool> first = FushiShare.shareFiles(
        <XFile>[XFile('/tmp/a.mp4', mimeType: 'video/mp4')],
      );
      await Future<void>.delayed(Duration.zero);
      expect(FushiShare.debugIsSharing, isTrue);

      expect(
        await FushiShare.shareFiles(
          <XFile>[XFile('/tmp/b.mp4', mimeType: 'video/mp4')],
        ),
        isFalse,
        reason: '重入被丢弃 → 必须回 false，否则调用方弹出假成功',
      );
      expect(await FushiShare.shareText('dropped'), isFalse);

      gate!.complete();
      expect(await first, isTrue);
      expect(FushiShare.debugIsSharing, isFalse);
    });

    test('空输入返回 false', () async {
      expect(await FushiShare.shareFiles(<XFile>[]), isFalse);
      expect(await FushiShare.shareText(''), isFalse);
      expect(calls, isEmpty);
    });
  });

  // 超时上限本身不做行为测试（真等 30 s 不可接受，且把常量暴露给测试会把「上限
  // 是多少」当成契约）。这里只钉「上限存在」这个不变式：两处平台调用都必须被
  // `.timeout(...)` 包住，否则平台不回包就会把 static 的 `_sharing` 永久钉在
  // true，全 App 此后每次分享都被静默丢弃（BUG-2542）。
  test('两处平台调用都套了超时上限（源码守卫）', () {
    final String source = File('lib/src/utils/misc/fushi_share.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    expect(
      RegExp(r'await Share\.share\([\s\S]*?\)\.timeout\(').hasMatch(source),
      isTrue,
      reason: 'shareText 的平台调用必须有超时上限',
    );
    expect(
      RegExp(r'await Share\.shareFiles\([\s\S]*?\)\.timeout\(')
          .hasMatch(source),
      isTrue,
      reason: 'shareFiles 的平台调用必须有超时上限',
    );
    expect(
      source.contains('static Future<bool> shareFiles') &&
          source.contains('static Future<bool> shareText'),
      isTrue,
      reason: '两个入口都必须回报面板是否呈现，不得退回 Future<void>',
    );
  });
}
