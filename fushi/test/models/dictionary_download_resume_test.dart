import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/dictionary_download_controller.dart';
import 'package:fushi/src/models/dictionary_download_resume.dart';
import 'package:fushi/src/utils/misc/toast_severity.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// 可编排的接管下载：[onWait] 决定 `wait` 的结局（写文件 / 抛错 / 挂住）。
class _FakeAdopted implements AdoptedDictionaryDownload {
  _FakeAdopted(this.handoff, this.onWait);

  @override
  final DictionaryDownloadHandoff handoff;
  final Future<void> Function(
    void Function(int received, int total) onReceiveProgress,
    CancelToken? cancelToken,
  )
  onWait;
  int waitCalls = 0;
  int discardCalls = 0;

  @override
  Future<void> wait({
    required void Function(int received, int total) onReceiveProgress,
    CancelToken? cancelToken,
  }) {
    waitCalls++;
    return onWait(onReceiveProgress, cancelToken);
  }

  @override
  Future<void> discard() async => discardCalls++;
}

/// 一次导入调用的记录。
typedef _ImportCall = ({
  String path,
  String content,
  DictionaryImportRecipe recipe,
  Dictionary? replaceTarget,
});

/// BUG-3887 续：iOS 进程被系统回收后，新进程接手上一个进程的在途词典下载。
///
/// 三种情形各自钉住：在途任务接上进度跑完后走原导入、进程不在时已经交付的文件直接
/// 导入、没人要的记录（配方坏了 / 替换目标已删）取消并删文件。取消 / 失败归因 /
/// 镜像回退与新下载同一套语义。
void main() {
  late Directory tempDir;
  late List<DictionaryDownloadOutcome> outcomes;
  late List<_ImportCall> imports;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dict_resume_test');
    outcomes = <DictionaryDownloadOutcome>[];
    imports = <_ImportCall>[];
    dictionaryDownloadTransport = null;
  });

  tearDown(() {
    dictionaryDownloadTransport = null;
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  DictionaryDownloadController newController() {
    final DictionaryDownloadController controller =
        DictionaryDownloadController(showOutcome: outcomes.add);
    addTearDown(controller.dispose);
    return controller;
  }

  final Dictionary installed = Dictionary(
    name: 'JMdict [2026-10-01]',
    formatKey: 'yomichan',
    order: 0,
  );

  Future<void> recordingImporter({
    required File file,
    required ValueNotifier<String> progressNotifier,
    required DictionaryImportRecipe recipe,
    required Dictionary? replaceTarget,
  }) async {
    imports.add((
      path: file.path,
      content: file.readAsStringSync(),
      recipe: recipe,
      replaceTarget: replaceTarget,
    ));
  }

  ResumableDictionaryImport? resolve(DictionaryDownloadHandoff handoff) =>
      resumableDictionaryImportFor(
        handoff: handoff,
        installed: <Dictionary>[installed],
        importer: recordingImporter,
      );

  DictionaryDownloadHandoff handoffFor(
    DictionaryImportRecipe recipe, {
    List<String> candidates = const <String>['https://a.example/x.zip'],
    int candidateIndex = 0,
  }) => DictionaryDownloadHandoff(
    url: candidates.first,
    candidates: candidates,
    candidateIndex: candidateIndex,
    destPath: '${tempDir.path}${Platform.pathSeparator}x.zip',
    payload: recipe.toPayload(),
  );

  const DictionaryImportRecipe installRecipe = DictionaryImportRecipe.install(
    name: 'JMdict',
    sourceOverride: <String, String>{'downloadUrl': 'https://a.example/x.zip'},
  );
  final DictionaryImportRecipe updateRecipe = DictionaryImportRecipe.update(
    name: 'JMdict',
    replaceTargetName: installed.name,
    sourceOverride: const <String, String>{'isUpdatable': 'true'},
    forceReplaceExisting: true,
  );

  test('重启后接管在途任务：接上进度等它跑完，再按配方走原导入，暂存文件删掉', () async {
    final DictionaryDownloadController controller = newController();
    final DictionaryDownloadHandoff handoff = handoffFor(updateRecipe);
    final Completer<void> finish = Completer<void>();
    final _FakeAdopted adopted = _FakeAdopted(handoff, (
      void Function(int, int) onReceiveProgress,
      CancelToken? cancelToken,
    ) async {
      onReceiveProgress(50, 100);
      await finish.future;
      File(handoff.destPath).writeAsStringSync('zip');
    });

    final Future<void> resuming = controller.resumeAdoptedDownloads(
      adopted: <AdoptedDictionaryDownload>[adopted],
      resolve: resolve,
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.phase.value, DictionaryDownloadPhase.downloading);
    expect(controller.progress.value, 0.5, reason: '接上的进度照常进进度条');
    expect(controller.canCancel, isTrue, reason: '接管的下载阶段同样可取消');

    finish.complete();
    await resuming;
    expect(adopted.waitCalls, 1);
    expect(imports, hasLength(1));
    expect(imports.single.path, handoff.destPath);
    expect(imports.single.content, 'zip');
    expect(imports.single.recipe.forceReplaceExisting, isTrue);
    expect(
      imports.single.replaceTarget,
      same(installed),
      reason: '更新必须替换原来那本，不能按 title 当成新增',
    );
    expect(File(handoff.destPath).existsSync(), isFalse);
    expect(outcomes.single.severity, ToastSeverity.success);
    expect(controller.isBusy, isFalse);
  });

  test('进程不在时系统已交付的文件：直接导入，不重新下载', () async {
    final DictionaryDownloadController controller = newController();
    final DictionaryDownloadHandoff handoff = handoffFor(installRecipe);
    File(handoff.destPath).writeAsStringSync('delivered');
    int transportCalls = 0;
    dictionaryDownloadTransport =
        ({
          required String url,
          required String destPath,
          required void Function(int, int) onReceiveProgress,
          CancelToken? cancelToken,
          DictionaryDownloadHandoff? handoff,
        }) async {
          transportCalls++;
        };
    final _FakeAdopted adopted = _FakeAdopted(
      handoff,
      (void Function(int, int) onReceiveProgress, CancelToken? token) async {},
    );

    await controller.resumeAdoptedDownloads(
      adopted: <AdoptedDictionaryDownload>[adopted],
      resolve: resolve,
    );
    expect(transportCalls, 0);
    expect(imports.single.content, 'delivered');
    expect(imports.single.replaceTarget, isNull, reason: '初装没有替换目标');
    expect(imports.single.recipe.sourceOverride, installRecipe.sourceOverride);
    expect(adopted.discardCalls, 0);
  });

  group('真孤儿：取消任务、删文件，不占锁、不导入', () {
    test('要替换的词典已被删掉', () async {
      final DictionaryDownloadController controller = newController();
      final _FakeAdopted adopted = _FakeAdopted(
        handoffFor(
          DictionaryImportRecipe.update(
            name: 'Gone',
            replaceTargetName: 'Gone [2026-01-01]',
            sourceOverride: const <String, String>{},
            forceReplaceExisting: true,
          ),
        ),
        (void Function(int, int) p, CancelToken? t) async =>
            fail('orphan must not be awaited'),
      );
      await controller.resumeAdoptedDownloads(
        adopted: <AdoptedDictionaryDownload>[adopted],
        resolve: resolve,
      );
      expect(adopted.discardCalls, 1);
      expect(adopted.waitCalls, 0);
      expect(imports, isEmpty);
      expect(outcomes, isEmpty, reason: '没人要的记录不该冒出一条 toast');
    });

    test('配方认不出来', () async {
      final DictionaryDownloadController controller = newController();
      final _FakeAdopted adopted = _FakeAdopted(
        const DictionaryDownloadHandoff(
          url: 'https://a.example/x.zip',
          candidates: <String>['https://a.example/x.zip'],
          candidateIndex: 0,
          destPath: '/nowhere/x.zip',
          payload: <String, Object?>{'kind': 'somethingElse'},
        ),
        (void Function(int, int) p, CancelToken? t) async =>
            fail('orphan must not be awaited'),
      );
      await controller.resumeAdoptedDownloads(
        adopted: <AdoptedDictionaryDownload>[adopted],
        resolve: resolve,
      );
      expect(adopted.discardCalls, 1);
      expect(imports, isEmpty);
    });
  });

  test('接管的任务以传输失败结束：按持久化的候选序列从下一个镜像续下', () async {
    final DictionaryDownloadController controller = newController();
    final DictionaryDownloadHandoff handoff = handoffFor(
      installRecipe,
      candidates: const <String>[
        'https://a.example/x.zip',
        'https://mirror1.example/x.zip',
        'https://mirror2.example/x.zip',
      ],
      candidateIndex: 1,
    );
    final List<DictionaryDownloadHandoff?> handoffs =
        <DictionaryDownloadHandoff?>[];
    final List<String> urls = <String>[];
    dictionaryDownloadTransport =
        ({
          required String url,
          required String destPath,
          required void Function(int, int) onReceiveProgress,
          CancelToken? cancelToken,
          DictionaryDownloadHandoff? handoff,
        }) async {
          urls.add(url);
          handoffs.add(handoff);
          File(destPath).writeAsStringSync('from mirror2');
        };
    final _FakeAdopted adopted = _FakeAdopted(
      handoff,
      (void Function(int, int) p, CancelToken? t) async => throw DioError(
        requestOptions: RequestOptions(path: handoff.candidate),
        type: DioErrorType.connectionError,
      ),
    );

    await controller.resumeAdoptedDownloads(
      adopted: <AdoptedDictionaryDownload>[adopted],
      resolve: resolve,
    );
    expect(urls, <String>['https://mirror2.example/x.zip']);
    expect(handoffs.single?.candidateIndex, 2, reason: '新任务照样可被下一个进程接管');
    expect(handoffs.single?.payload, handoff.payload);
    expect(imports.single.content, 'from mirror2');
  });

  test('接管的任务被服务器答复 404：不换镜像，报下载失败', () async {
    final DictionaryDownloadController controller = newController();
    final DictionaryDownloadHandoff handoff = handoffFor(
      installRecipe,
      candidates: const <String>[
        'https://a.example/x.zip',
        'https://mirror1.example/x.zip',
      ],
    );
    dictionaryDownloadTransport =
        ({
          required String url,
          required String destPath,
          required void Function(int, int) onReceiveProgress,
          CancelToken? cancelToken,
          DictionaryDownloadHandoff? handoff,
        }) async => fail('404 must not fall back to a mirror');
    final RequestOptions request = RequestOptions(path: handoff.candidate);
    final _FakeAdopted adopted = _FakeAdopted(
      handoff,
      (void Function(int, int) p, CancelToken? t) async => throw DioError(
        requestOptions: request,
        type: DioErrorType.badResponse,
        response: Response<void>(requestOptions: request, statusCode: 404),
      ),
    );

    await controller.resumeAdoptedDownloads(
      adopted: <AdoptedDictionaryDownload>[adopted],
      resolve: resolve,
    );
    expect(imports, isEmpty);
    expect(outcomes.single.severity, ToastSeverity.error);
  });

  test('用户在接管的下载阶段取消：不导入、不记失败', () async {
    final DictionaryDownloadController controller = newController();
    final DictionaryDownloadHandoff handoff = handoffFor(installRecipe);
    final _FakeAdopted adopted = _FakeAdopted(handoff, (
      void Function(int, int) p,
      CancelToken? token,
    ) async {
      await token!.whenCancel;
      throw token.cancelError!;
    });
    final Future<void> resuming = controller.resumeAdoptedDownloads(
      adopted: <AdoptedDictionaryDownload>[adopted],
      resolve: resolve,
    );
    await Future<void>.delayed(Duration.zero);
    controller.requestCancel();
    await resuming;
    expect(imports, isEmpty);
    expect(outcomes.single.severity, isNot(ToastSeverity.error));
  });

  test('已有任务在跑时什么都不放弃：记录留给下次启动', () async {
    final DictionaryDownloadController controller = newController();
    final Completer<void> hold = Completer<void>();
    final Future<bool> busy = controller.run(
      initialMessage: 'busy',
      body: (DictionaryDownloadJob job) async {
        await hold.future;
        return null;
      },
    );
    await Future<void>.delayed(Duration.zero);
    final _FakeAdopted adopted = _FakeAdopted(
      handoffFor(installRecipe),
      (void Function(int, int) p, CancelToken? t) async =>
          fail('must not attach while busy'),
    );
    await controller.resumeAdoptedDownloads(
      adopted: <AdoptedDictionaryDownload>[adopted],
      resolve: resolve,
    );
    expect(adopted.discardCalls, 0);
    expect(adopted.waitCalls, 0);
    hold.complete();
    await busy;
  });

  group('持久化格式往返', () {
    test('配方 payload 往返不丢字段', () {
      final DictionaryImportRecipe? back = DictionaryImportRecipe.fromPayload(
        updateRecipe.toPayload(),
      );
      expect(back?.replaceTargetName, installed.name);
      expect(back?.forceReplaceExisting, isTrue);
      expect(back?.sourceOverride, updateRecipe.sourceOverride);
    });

    test('接管描述往返；越界下标 / 缺字段解析为 null', () {
      final DictionaryDownloadHandoff handoff = handoffFor(
        installRecipe,
        candidates: const <String>['https://a/x', 'https://b/x'],
        candidateIndex: 1,
      );
      final DictionaryDownloadHandoff? back =
          DictionaryDownloadHandoff.tryParse(handoff.toJson());
      expect(back?.candidate, 'https://b/x');
      expect(back?.destPath, handoff.destPath);
      expect(back?.payload['name'], 'JMdict');
      expect(
        DictionaryDownloadHandoff.tryParse(<String, Object?>{
          ...handoff.toJson(),
          'candidateIndex': 2,
        }),
        isNull,
      );
      expect(
        DictionaryDownloadHandoff.tryParse(<String, Object?>{'url': 'x'}),
        isNull,
      );
    });
  });
}
