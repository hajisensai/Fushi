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
}

Future<File> _neverRuns({
  required Directory packDir,
  required ValueNotifier<double> progress,
  required ValueNotifier<int> receivedBytes,
  required CancelToken cancelToken,
}) async => throw StateError('本用例不该真去下载');
