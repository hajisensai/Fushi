import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/hibiki_share.dart';
import 'package:share_plus/share_plus.dart';

/// TODO-1318 / BUG-608：验证 `HibikiShare.shareFiles` 只走 share_plus 的
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
    await HibikiShare.shareFiles(
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
    await HibikiShare.shareFiles(<XFile>[XFile('/tmp/clip.mkv')]);
    final Map<Object?, Object?> args =
        calls.single.arguments as Map<Object?, Object?>;
    expect(List<String>.from(args['mimeTypes']! as List<Object?>),
        <String>['*/*']);
  });

  test('防重入：面板在途时第二次调用被丢弃，门复位后恢复', () async {
    gate = Completer<void>();
    // 第一次分享挂起（模拟系统面板尚未呈现完成）。
    final Future<void> first = HibikiShare.shareFiles(
      <XFile>[XFile('/tmp/a.png', mimeType: 'image/png')],
    );
    await Future<void>.delayed(Duration.zero);
    expect(HibikiShare.debugIsSharing, isTrue);

    // 重入调用必须被防重入门静默丢弃（不再触发平台调用）。
    await HibikiShare.shareFiles(
      <XFile>[XFile('/tmp/b.png', mimeType: 'image/png')],
    );
    expect(calls.length, 1, reason: '重入调用必须被静默丢弃');

    // 放行第一次，门复位，后续分享恢复。
    gate!.complete();
    await first;
    expect(HibikiShare.debugIsSharing, isFalse);

    await HibikiShare.shareFiles(
      <XFile>[XFile('/tmp/c.png', mimeType: 'image/png')],
    );
    expect(calls.length, 2, reason: '门复位后分享应恢复');
  });

  test('空文件列表直接返回，不触发任何平台调用', () async {
    await HibikiShare.shareFiles(<XFile>[]);
    expect(calls, isEmpty);
    expect(HibikiShare.debugIsSharing, isFalse);
  });
}
