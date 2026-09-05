import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/onboarding/recommended_pack.dart';
import 'package:fushi/src/onboarding/recommended_pack_download_controller.dart';
import 'package:fushi/src/utils/misc/toast_severity.dart';
import 'package:path/path.dart' as p;

/// BUG-2097：推荐包下载的所有权从新手引导页的 State 上移到 app 级 controller。
///
/// 这里守的是「任务与视图脱钩」这件事本身：下载的开始、进度、结束、取消、失败
/// 全在 controller 里发生，发起它的页面死不死与它无关；下完之后**停在待导入**，
/// 因为导入要用户确认并重启进程，controller 不能替用户按下去。
void main() {
  late Directory packDir;

  setUp(() {
    packDir = Directory.systemTemp.createTempSync('recommended_pack_ctl');
  });

  tearDown(() {
    if (packDir.existsSync()) packDir.deleteSync(recursive: true);
  });

  File completedPackFile() {
    final File file = File(p.join(packDir.path, kRecommendedPackFileName));
    file.writeAsStringSync('pack');
    return file;
  }

  /// 单流续传的半截文件：`<包名>.part`，长度就是已下字节。
  File partialPackFile(int bytes) {
    final File file = File(
      p.join(packDir.path, '$kRecommendedPackFileName.part'),
    );
    file.writeAsBytesSync(List<int>.filled(bytes, 0));
    return file;
  }

  /// 分片路的半截：`.mpart` 是**预分配**到完整大小的，进度只在 `.mpart.json` 里。
  void partialMultiPartFiles({
    required int allocated,
    required List<int> parts,
  }) {
    File(
      p.join(packDir.path, '$kRecommendedPackFileName.mpart'),
    ).writeAsBytesSync(List<int>.filled(allocated, 0));
    final String entries = <String>[
      for (int i = 0; i < parts.length; i += 1) '"$i":${parts[i]}',
    ].join(',');
    File(
      p.join(packDir.path, '$kRecommendedPackFileName.mpart.json'),
    ).writeAsStringSync('{"parts":{$entries}}');
  }

  RecommendedPackDownloadController newController({
    required RecommendedPackDownloadRunner runner,
    List<String>? outcomes,
  }) {
    return RecommendedPackDownloadController(
      packDirectory: () => packDir,
      runner: runner,
      showOutcome: (String message, ToastSeverity severity) =>
          outcomes?.add(message),
    );
  }

  test('发起页消失后下载照跑完，停在「已下载待导入」并出提示', () async {
    final Completer<File> finish = Completer<File>();
    final List<String> outcomes = <String>[];
    final RecommendedPackDownloadController controller = newController(
      outcomes: outcomes,
      runner:
          ({
            required Directory packDir,
            required ValueNotifier<double> progress,
            required ValueNotifier<int> receivedBytes,
            required CancelToken cancelToken,
          }) {
            progress.value = 0.5;
            receivedBytes.value = 5 * 1024 * 1024 * 1024;
            return finish.future;
          },
    );
    addTearDown(controller.dispose);

    final Future<File?> started = controller.start();
    expect(controller.isDownloading, isTrue);
    expect(controller.progress.value, 0.5);

    // 「向导被 pop 掉」在这里就是「没有任何人再等这个 future」——任务照跑。
    finish.complete(completedPackFile());
    expect(await started, isNotNull);

    expect(controller.stage.value, RecommendedPackDownloadStage.downloaded);
    expect(controller.hasPendingImport, isTrue);
    expect(controller.isActive, isTrue);
    expect(controller.error.value, isNull);
    expect(outcomes, hasLength(1), reason: '后台下完必须有一次提示，否则 9.5 GB 下完屏幕上毫无变化');
  });

  test('用户取消不算失败：不写 error、不提示，阶段按磁盘回落', () async {
    final List<String> outcomes = <String>[];
    final RecommendedPackDownloadController controller = newController(
      outcomes: outcomes,
      runner:
          ({
            required Directory packDir,
            required ValueNotifier<double> progress,
            required ValueNotifier<int> receivedBytes,
            required CancelToken cancelToken,
          }) async {
            throw DioError(
              requestOptions: RequestOptions(path: '/pack'),
              type: DioErrorType.cancel,
            );
          },
    );
    addTearDown(controller.dispose);

    expect(await controller.start(), isNull);
    expect(controller.error.value, isNull);
    expect(outcomes, isEmpty);
    expect(controller.stage.value, RecommendedPackDownloadStage.idle);
  });

  test('真失败写 error 并提示，半截文件留着下次续传', () async {
    final List<String> outcomes = <String>[];
    final RecommendedPackDownloadController controller = newController(
      outcomes: outcomes,
      runner:
          ({
            required Directory packDir,
            required ValueNotifier<double> progress,
            required ValueNotifier<int> receivedBytes,
            required CancelToken cancelToken,
          }) async => throw const SocketException('connection reset'),
    );
    addTearDown(controller.dispose);

    expect(await controller.start(), isNull);
    expect(controller.error.value, contains('connection reset'));
    expect(outcomes, hasLength(1));
    expect(controller.stage.value, RecommendedPackDownloadStage.idle);
  });

  test('互斥：跑着的时候再点一次下载不会起第二个任务', () async {
    final Completer<File> finish = Completer<File>();
    int runs = 0;
    final RecommendedPackDownloadController controller = newController(
      runner:
          ({
            required Directory packDir,
            required ValueNotifier<double> progress,
            required ValueNotifier<int> receivedBytes,
            required CancelToken cancelToken,
          }) {
            runs += 1;
            return finish.future;
          },
    );
    addTearDown(controller.dispose);

    final Future<File?> first = controller.start();
    expect(await controller.start(), isNull);
    expect(runs, 1, reason: '两份下载会写同一个半截文件，必须互斥');

    finish.complete(completedPackFile());
    expect(await first, isNotNull);
  });

  test('进场收尾：磁盘上已下好的整包会被认成「待导入」', () async {
    final RecommendedPackDownloadController controller = newController(
      runner: _neverRuns,
    );
    addTearDown(controller.dispose);

    completedPackFile();
    await controller.prepareDiskState();
    expect(controller.stage.value, RecommendedPackDownloadStage.downloaded);
  });

  test('进场收尾：已导入过的包目录被删干净，阶段回 idle', () async {
    final RecommendedPackDownloadController controller = newController(
      runner: _neverRuns,
    );
    addTearDown(controller.dispose);

    completedPackFile();
    await controller.markImportStarted();
    await controller.prepareDiskState();

    expect(controller.stage.value, RecommendedPackDownloadStage.idle);
    expect(controller.isActive, isFalse);
    expect(
      RecommendedPackDownloader.hasCompletedFileIn(packDir),
      isFalse,
      reason: '导入完还留着 9.5 GB 的 zip 就是白占盘',
    );
  });

  test('进度文案：总大小未知时只报字节数，已知时带百分比', () {
    expect(
      recommendedPackProgressLabel(progress: 0, receivedBytes: 3 * 1024 * 1024),
      '3.0 MB',
    );
    expect(
      recommendedPackProgressLabel(
        progress: 0.34,
        receivedBytes: 3 * 1024 * 1024,
      ),
      '3.0 MB (34%)',
    );
  });
  // ── BUG-2165：磁盘有四种状态，状态机就得有四个阶段 ──────────────────────
  //
  // 在 `paused` 存在之前，「盘上躺着 3 GB 半截」与「盘上什么都没有」在 UI 层是
  // 同一个 `idle`：判据是 `isActive` 的可见入口全部不渲染，于是那 3 GB 既看不见
  // 也续不上（唯一入口是重开新手引导，而那条按钮还写着「下载 9.5 GB」、点下去
  // 进度从 0 起跳）。

  test('进场对盘：单流半截 → paused，并把已下字节读成进度', () async {
    partialPackFile(2048);
    final RecommendedPackDownloadController controller = newController(
      runner: _neverRuns,
    );
    addTearDown(controller.dispose);

    await controller.prepareDiskState();

    expect(controller.stage.value, RecommendedPackDownloadStage.paused);
    expect(controller.isPaused, isTrue);
    expect(controller.isActive, isTrue, reason: '可见入口的判据必须认得半截');
    expect(controller.receivedBytes.value, 2048);
  });

  test('进场对盘：分片半截读进度文件求和，不把预分配长度当已下', () async {
    // `.mpart` 预分配到 1 MB，实际只下了 300 字节。读文件长度会显示「已下 1 MB」。
    partialMultiPartFiles(allocated: 1024 * 1024, parts: <int>[100, 200]);
    final RecommendedPackDownloadController controller = newController(
      runner: _neverRuns,
    );
    addTearDown(controller.dispose);

    await controller.prepareDiskState();

    expect(controller.stage.value, RecommendedPackDownloadStage.paused);
    expect(controller.receivedBytes.value, 300);
  });

  test('进场对盘：盘上什么都没有才是 idle', () async {
    final RecommendedPackDownloadController controller = newController(
      runner: _neverRuns,
    );
    addTearDown(controller.dispose);

    await controller.prepareDiskState();

    expect(controller.stage.value, RecommendedPackDownloadStage.idle);
    expect(controller.isActive, isFalse);
  });

  test('用户取消后落到 paused（半截还在），并收起首页迷你条', () async {
    final RecommendedPackDownloadController controller = newController(
      runner:
          ({
            required Directory packDir,
            required ValueNotifier<double> progress,
            required ValueNotifier<int> receivedBytes,
            required CancelToken cancelToken,
          }) async {
            // 走真实形状：等令牌被置位，留下半截 `.part`，再按取消收场。
            await cancelToken.whenCancel;
            partialPackFile(4096);
            throw DioError(
              requestOptions: RequestOptions(path: '/pack'),
              type: DioErrorType.cancel,
            );
          },
    );
    addTearDown(controller.dispose);

    final Future<File?> pending = controller.start();
    controller.requestCancel();
    final File? file = await pending;

    expect(file, isNull);
    expect(controller.stage.value, RecommendedPackDownloadStage.paused);
    expect(controller.error.value, isNull, reason: '用户取消不是失败');
    expect(controller.receivedBytes.value, 4096);
    expect(
      controller.miniBarDismissed.value,
      isTrue,
      reason: '主动点取消 = 已经做过决定，那条常驻迷你条不该继续杵在每个页面底部',
    );
  });

  test('下载失败但半截还在 → paused + 保留失败原因（失败后必须还能重试）', () async {
    final RecommendedPackDownloadController controller = newController(
      runner:
          ({
            required Directory packDir,
            required ValueNotifier<double> progress,
            required ValueNotifier<int> receivedBytes,
            required CancelToken cancelToken,
          }) async {
            partialPackFile(8192);
            throw StateError('连接断了');
          },
    );
    addTearDown(controller.dispose);

    await controller.start();

    expect(controller.stage.value, RecommendedPackDownloadStage.paused);
    expect(controller.error.value, contains('连接断了'));
    expect(controller.isActive, isTrue, reason: '失败后整行消失 = 只能从 0 重下 9.5 GB');
  });

  test('续传从盘上已有的半截起跳，并重新放开迷你条', () async {
    partialPackFile(4096);
    final Completer<File> finish = Completer<File>();
    final RecommendedPackDownloadController controller = newController(
      runner:
          ({
            required Directory packDir,
            required ValueNotifier<double> progress,
            required ValueNotifier<int> receivedBytes,
            required CancelToken cancelToken,
          }) => finish.future,
    );
    addTearDown(controller.dispose);
    controller.dismissMiniBar();

    final Future<File?> pending = controller.start();

    expect(
      controller.receivedBytes.value,
      4096,
      reason: '归零会让刚点「继续下载」的用户看着 3.2 GB 变成 0 B',
    );
    expect(controller.miniBarDismissed.value, isFalse);

    finish.complete(completedPackFile());
    await pending;
  });
}

Future<File> _neverRuns({
  required Directory packDir,
  required ValueNotifier<double> progress,
  required ValueNotifier<int> receivedBytes,
  required CancelToken cancelToken,
}) async => throw StateError('本用例不该真去下载');
