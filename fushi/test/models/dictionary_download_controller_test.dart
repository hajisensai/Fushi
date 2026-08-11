import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/dictionary_download_controller.dart';
import 'package:fushi/src/utils/misc/toast_severity.dart';

/// BUG-1499 / BUG-1500：词典下载任务所有权与取消语义。
///
/// 这些断言钉住的是**词典库不会被取消毁掉**：取消只可能落在下载传输和批量的本间
/// 边界，导入阶段（native 一次不可分割的 FFI 调用，内部「导新到 temp → 删旧 →
/// publish」）在任何路径下都取消不了。
void main() {
  DictionaryDownloadController newController(
    List<DictionaryDownloadOutcome> sink,
  ) {
    final DictionaryDownloadController controller =
        DictionaryDownloadController(showOutcome: sink.add);
    addTearDown(controller.dispose);
    return controller;
  }

  group('BUG-1500 互斥：手动下载与静默自动更新共用一把锁', () {
    test('已有任务在跑时第二次 run 被拒，第二个 body 一行都不执行', () async {
      final List<DictionaryDownloadOutcome> outcomes =
          <DictionaryDownloadOutcome>[];
      final DictionaryDownloadController controller = newController(outcomes);
      final Completer<void> hold = Completer<void>();
      bool secondBodyRan = false;

      final Future<bool> first = controller.run(
        initialMessage: 'first',
        body: (DictionaryDownloadJob job) async {
          await hold.future;
          return null;
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.isBusy, isTrue);

      final bool accepted = await controller.run(
        initialMessage: 'second',
        body: (DictionaryDownloadJob job) async {
          secondBodyRan = true;
          return null;
        },
      );

      expect(accepted, isFalse, reason: '并发写同一本词典会互删 import_temp');
      expect(secondBodyRan, isFalse);

      hold.complete();
      expect(await first, isTrue);
      expect(controller.isBusy, isFalse);
    });

    test('任务结束后锁释放，下一次 run 正常接受', () async {
      final List<DictionaryDownloadOutcome> outcomes =
          <DictionaryDownloadOutcome>[];
      final DictionaryDownloadController controller = newController(outcomes);

      expect(
        await controller.run(
          initialMessage: 'a',
          body: (DictionaryDownloadJob job) async => null,
        ),
        isTrue,
      );
      expect(
        await controller.run(
          initialMessage: 'b',
          body: (DictionaryDownloadJob job) async => null,
        ),
        isTrue,
      );
    });

    test('body 抛异常也要释放锁并复位阶段', () async {
      final List<DictionaryDownloadOutcome> outcomes =
          <DictionaryDownloadOutcome>[];
      final DictionaryDownloadController controller = newController(outcomes);

      await expectLater(
        controller.run(
          initialMessage: 'boom',
          body: (DictionaryDownloadJob job) async => throw StateError('boom'),
        ),
        throwsStateError,
      );
      expect(controller.isBusy, isFalse);
      expect(controller.phase.value, DictionaryDownloadPhase.idle);
    });
  });

  group('BUG-1499 取消：只在安全时点可达', () {
    test('下载阶段可取消：置位 cancelToken，并让批量在本间边界停', () async {
      final List<DictionaryDownloadOutcome> outcomes =
          <DictionaryDownloadOutcome>[];
      final DictionaryDownloadController controller = newController(outcomes);

      await controller.run(
        initialMessage: 'downloading',
        body: (DictionaryDownloadJob job) async {
          job.markDownloadPhase();
          expect(controller.canCancel, isTrue);
          expect(job.cancelToken.isCancelled, isFalse);

          controller.requestCancel();

          expect(job.cancelToken.isCancelled, isTrue,
              reason: '当前这次 dio.download 必须立刻断流');
          expect(job.isCancelled, isTrue, reason: '批量循环靠它在下一本开始前停下');
          expect(controller.canCancel, isFalse, reason: '取消过一次后按钮要变灰');
          return null;
        },
      );
    });

    test('导入阶段取消不可达：requestCancel 是 no-op，cancelToken 不被置位', () async {
      final List<DictionaryDownloadOutcome> outcomes =
          <DictionaryDownloadOutcome>[];
      final DictionaryDownloadController controller = newController(outcomes);

      await controller.run(
        initialMessage: 'importing',
        body: (DictionaryDownloadJob job) async {
          job.markImportPhase();

          expect(controller.canCancel, isFalse,
              reason: 'native 导入是一次不可分割的 FFI 调用，C++ 侧零 abort flag');

          controller.requestCancel();

          expect(
            job.cancelToken.isCancelled,
            isFalse,
            reason: '导入内部是「导新到 temp → 删旧 → publish」，'
                '中途硬中断能落在「删旧之后」，把用户已有的词典毁掉',
          );
          expect(job.isCancelled, isFalse, reason: '导入期的误点不该连带停掉后面几本');
          return null;
        },
      );
    });

    test('下载阶段取消后进入导入阶段：按钮保持灰，批量停止标志保持置位', () async {
      final List<DictionaryDownloadOutcome> outcomes =
          <DictionaryDownloadOutcome>[];
      final DictionaryDownloadController controller = newController(outcomes);

      await controller.run(
        initialMessage: 'downloading',
        body: (DictionaryDownloadJob job) async {
          job.markDownloadPhase();
          controller.requestCancel();
          // 这一本恰好已经下完了 → 导入照跑到底，词典库落成完整状态。
          job.markImportPhase();

          expect(controller.canCancel, isFalse);
          expect(job.isCancelled, isTrue, reason: '下一本不能再开始');
          return null;
        },
      );
    });

    test('每次 run 重置取消状态，上一轮的取消不会污染下一轮', () async {
      final List<DictionaryDownloadOutcome> outcomes =
          <DictionaryDownloadOutcome>[];
      final DictionaryDownloadController controller = newController(outcomes);

      await controller.run(
        initialMessage: 'first',
        body: (DictionaryDownloadJob job) async {
          job.markDownloadPhase();
          controller.requestCancel();
          return null;
        },
      );

      await controller.run(
        initialMessage: 'second',
        body: (DictionaryDownloadJob job) async {
          job.markDownloadPhase();
          expect(job.isCancelled, isFalse);
          expect(job.cancelToken.isCancelled, isFalse);
          expect(controller.canCancel, isTrue);
          return null;
        },
      );
    });

    test('isCancellation 只认 dio 的取消，真失败仍算失败', () {
      final RequestOptions options = RequestOptions(path: '/x');
      expect(
        DictionaryDownloadController.isCancellation(
          DioError(requestOptions: options, type: DioErrorType.cancel),
        ),
        isTrue,
      );
      expect(
        DictionaryDownloadController.isCancellation(
          DioError(
              requestOptions: options, type: DioErrorType.connectionTimeout),
        ),
        isFalse,
      );
      expect(
        DictionaryDownloadController.isCancellation(StateError('nope')),
        isFalse,
      );
    });
  });

  group('BUG-1499 后台化：结果不依赖发起它的页面还活着', () {
    test('body 返回的 outcome 由 controller 自己送出', () async {
      final List<DictionaryDownloadOutcome> outcomes =
          <DictionaryDownloadOutcome>[];
      final DictionaryDownloadController controller = newController(outcomes);

      await controller.run(
        initialMessage: 'x',
        body: (DictionaryDownloadJob job) async =>
            const DictionaryDownloadOutcome(
          message: 'done',
          severity: ToastSeverity.success,
        ),
      );

      expect(outcomes, hasLength(1));
      expect(outcomes.single.message, 'done');
      expect(outcomes.single.severity, ToastSeverity.success);
    });

    test('outcome 为 null 时不打扰用户（静默自动更新走这条）', () async {
      final List<DictionaryDownloadOutcome> outcomes =
          <DictionaryDownloadOutcome>[];
      final DictionaryDownloadController controller = newController(outcomes);

      await controller.run(
        initialMessage: 'x',
        body: (DictionaryDownloadJob job) async => null,
      );

      expect(outcomes, isEmpty);
    });

    test('任务跑完把进度状态清干净，状态行不会留下残影', () async {
      final List<DictionaryDownloadOutcome> outcomes =
          <DictionaryDownloadOutcome>[];
      final DictionaryDownloadController controller = newController(outcomes);

      await controller.run(
        initialMessage: 'x',
        body: (DictionaryDownloadJob job) async {
          job.message.value = 'downloading 30MB';
          job.progress.value = 0.7;
          return null;
        },
      );

      expect(controller.phase.value, DictionaryDownloadPhase.idle);
      expect(controller.message.value, isEmpty);
      expect(controller.progress.value, 0);
    });
  });
}
