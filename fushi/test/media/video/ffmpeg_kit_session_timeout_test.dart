import 'dart:async';

import 'package:ffmpeg_kit_flutter/return_code.dart';
import 'package:ffmpeg_kit_flutter/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/ffmpeg_kit_backend.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';

/// BUG-2542：移动端 ffmpeg-kit 后端的**每一次** method channel 往返都必须在时间
/// 预算内。
///
/// 从前 `.timeout()` 只套在完成回调的 `Completer` 上，而启动
/// （`executeWithArgumentsAsync`，内含 init/createSession/asyncExecute 三次往返）、
/// 超时分支里的 `cancel`、以及收尾的 `getReturnCode` / `getOutput` 都是裸 await。
/// 任一不回包，`run()` 就**永不返回** → 片段导出/制卡的「进行中」标志永久为真 →
/// 之后每次点击都撞在防重入门上，用户看到的是「点了没反应，连失败提示都没有」。
///
/// 这里对每个挂死阶段各跑一条：断言调用**会返回**（而不是永久 pending），返回的
/// 是失败结果，且 `output` 指明卡在哪个阶段（旧实现恒返回空串，把唯一的线索也
/// 抹掉了）。
void main() {
  // 每条都给极短的注入超时，测试本身在毫秒级完成；真正被钉死的是「有上限」这个
  // 不变式，而不是某个具体秒数。
  const Duration tiny = Duration(milliseconds: 20);

  test('启动不回包：在预算内返回 start 阶段失败，而不是永久挂住', () async {
    bool cancelled = false;
    final Future<FfmpegRunResult> pending = runKitFfmpegSession(
      // 永不完成：模拟 native loader 卡死 / ABI 不匹配 / 插件未注册。
      start: (void Function() onComplete) => Completer<Session>().future,
      timeout: const Duration(minutes: 5),
      startTimeout: tiny,
      executable: 'ffmpeg-kit',
      cancelSession: (int id) async => cancelled = true,
    );

    final FfmpegRunResult result = await pending;
    expect(result.isSuccess, isFalse);
    expect(result.returnCode, isNull);
    expect(result.output, contains('start'),
        reason: 'output 必须指明卡在启动阶段，旧实现恒为空串');
    expect(cancelled, isFalse,
        reason: '拿不到 session 就没有 sessionId，不能退化成无参 cancel 误杀并发会话（BUG-905）');
  });

  test('启动超时取 min(主预算, startTimeout)：主预算更短时由它说话', () async {
    final FfmpegRunResult result = await runKitFfmpegSession(
      start: (void Function() onComplete) => Completer<Session>().future,
      // 主预算比 startTimeout 更短——不该等满 startTimeout。
      timeout: tiny,
      startTimeout: const Duration(minutes: 5),
      executable: 'ffmpeg-kit',
      cancelSession: (int id) async {},
    );
    expect(result.output, contains('start'));
  });

  test('会话不完成：返回 execute 阶段失败，并只精确取消本次 session', () async {
    final List<int> cancelledIds = <int>[];
    final FfmpegRunResult result = await runKitFfmpegSession(
      // 启动成功，但完成回调永不触发（ffmpeg 真的卡住）。
      start: (void Function() onComplete) async => _FakeSession(sessionId: 42),
      timeout: tiny,
      executable: 'ffmpeg-kit',
      cancelSession: (int id) async => cancelledIds.add(id),
    );

    expect(result.isSuccess, isFalse);
    expect(result.output, contains('execute'));
    expect(cancelledIds, <int>[42], reason: '只取消本次 session，绝不碰并发会话（BUG-905）');
  });

  test('取消本身不回包：仍在预算内返回 execute 失败（超时机制不能被 cancel 挂住）', () async {
    final FfmpegRunResult result = await runKitFfmpegSession(
      start: (void Function() onComplete) async => _FakeSession(sessionId: 7),
      timeout: tiny,
      epilogueTimeout: tiny,
      executable: 'ffmpeg-kit',
      // cancel 永不返回：这正是「超时机制被自己要取消的东西挂住」的形状。
      cancelSession: (int id) => Completer<void>().future,
    );
    expect(result.isSuccess, isFalse);
    expect(result.output, contains('execute'));
  });

  test('收尾 getReturnCode 不回包：返回 epilogue 阶段失败', () async {
    final FfmpegRunResult result = await runKitFfmpegSession(
      start: (void Function() onComplete) async {
        // 会话正常完成，但读退出码的往返挂住。
        onComplete();
        return _FakeSession(sessionId: 1, hangReturnCode: true);
      },
      timeout: const Duration(seconds: 5),
      epilogueTimeout: tiny,
      executable: 'ffmpeg-kit',
      cancelSession: (int id) async {},
    );
    expect(result.isSuccess, isFalse);
    expect(result.output, contains('epilogue'));
  });

  test('收尾 getOutput 不回包：返回 epilogue 阶段失败', () async {
    final FfmpegRunResult result = await runKitFfmpegSession(
      start: (void Function() onComplete) async {
        onComplete();
        return _FakeSession(sessionId: 1, hangOutput: true);
      },
      timeout: const Duration(seconds: 5),
      epilogueTimeout: tiny,
      executable: 'ffmpeg-kit',
      cancelSession: (int id) async {},
    );
    expect(result.isSuccess, isFalse);
    expect(result.output, contains('epilogue'));
  });

  test('一切正常：退出码与合并日志照旧回传（超时收敛没改成功路径）', () async {
    final FfmpegRunResult result = await runKitFfmpegSession(
      start: (void Function() onComplete) async {
        onComplete();
        return _FakeSession(sessionId: 3, returnCode: 0, output: 'frame= 12');
      },
      timeout: const Duration(seconds: 5),
      executable: 'ffmpeg-kit',
      cancelSession: (int id) async {},
    );
    expect(result.isSuccess, isTrue);
    expect(result.returnCode, 0);
    expect(result.output, 'frame= 12');
    expect(result.executable, 'ffmpeg-kit');
  });

  test('非零退出码照旧回传（不被当成超时）', () async {
    final FfmpegRunResult result = await runKitFfmpegSession(
      start: (void Function() onComplete) async {
        onComplete();
        return _FakeSession(
          sessionId: 4,
          returnCode: 1,
          output: 'Unknown encoder',
        );
      },
      timeout: const Duration(seconds: 5),
      executable: 'ffmpeg-kit',
      cancelSession: (int id) async {},
    );
    expect(result.isSuccess, isFalse);
    expect(result.returnCode, 1);
    expect(result.output, 'Unknown encoder');
  });
}

/// 只实现本驱动真正会调的三个 [Session] 成员（`getSessionId` / `getReturnCode` /
/// `getOutput`），其余经 `noSuchMethod` 兜住——被调到就是驱动越界了。
class _FakeSession implements Session {
  _FakeSession({
    required this.sessionId,
    this.returnCode,
    this.output = '',
    this.hangReturnCode = false,
    this.hangOutput = false,
  });

  final int sessionId;
  final int? returnCode;
  final String output;
  final bool hangReturnCode;
  final bool hangOutput;

  @override
  int? getSessionId() => sessionId;

  @override
  Future<ReturnCode?> getReturnCode() {
    if (hangReturnCode) return Completer<ReturnCode?>().future;
    final int? rc = returnCode;
    return Future<ReturnCode?>.value(rc == null ? null : ReturnCode(rc));
  }

  @override
  Future<String?> getOutput() {
    if (hangOutput) return Completer<String?>().future;
    return Future<String?>.value(output);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError(
      '会话驱动只应调用 getSessionId / getReturnCode / getOutput，'
      '实际调用了 ${invocation.memberName}',
    );
  }
}
