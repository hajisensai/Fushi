// 入门预置卡组（反馈 abZh1VOGZ5：新手引导缺 Kaishi 1.5k）的「下载 → 导入」控制器：
// - 判重：连点只下一次；当前 profile 已有同名顶层牌组时不下载；导入还没结束时再点不重复入队。
// - 下载失败 / 取消：不入队、回到可重试状态。
// - 导入成功删掉下载的包；导入失败保留（重试不必重下）。
// - [srsStarterPackInstalled] 按未删除的同名顶层牌组判定。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_import_task.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_starter_pack_controller.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/starter/srs_starter_packs.dart';

import 'srs_test_support.dart';

final SrsStarterPack _pack = SrsStarterPack(
  id: 'demo',
  name: 'Demo deck',
  language: 'ja',
  cardCount: 3,
  deckName: 'Demo deck',
  version: '1',
  source: 'test',
  homepage: Uri.parse('https://example.com'),
  license: kSrsStarterLicenseUnspecified,
  url: Uri.parse('https://example.com/d.apkg'),
  sizeBytes: 4,
  sha256: '0000000000000000000000000000000000000000000000000000000000000000',
);

/// 可手动推进的假下载。
class _FakeDownload {
  final List<Completer<File>> calls = <Completer<File>>[];
  final List<SrsStarterDownloadCancelToken> tokens =
      <SrsStarterDownloadCancelToken>[];
  final List<void Function(int, int)> progress = <void Function(int, int)>[];

  Future<File> call({
    required SrsStarterPack pack,
    required Directory dir,
    required void Function(int received, int total) onProgress,
    required SrsStarterDownloadCancelToken cancel,
  }) {
    final Completer<File> c = Completer<File>();
    calls.add(c);
    tokens.add(cancel);
    progress.add(onProgress);
    return c.future;
  }
}

void main() {
  late Directory tmp;
  late FushiDatabase db;
  late SrsDbStore store;
  late SrsImportController imports;
  late List<Completer<SrsImportReport>> importRuns;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('srs_starter_ctrl_');
    final (FushiDatabase d, SrsDbStore s) = await openSrsTestStore();
    db = d;
    store = s;
    importRuns = <Completer<SrsImportReport>>[];
    imports = SrsImportController(
      onDataChanged: () {},
      runner:
          ({
            required SrsDbStore store,
            required SrsMediaStore media,
            required File file,
            required SrsAnkiImportOptions options,
            required void Function(double progress) onProgress,
            required bool Function() shouldStop,
          }) {
            final Completer<SrsImportReport> c = Completer<SrsImportReport>();
            importRuns.add(c);
            return c.future;
          },
    );
  });

  tearDown(() async {
    imports.dispose();
    await db.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  SrsStarterPackController controller(
    _FakeDownload download, {
    bool installed = false,
    bool importAvailable = true,
  }) {
    final SrsStarterPackController c = SrsStarterPackController(
      downloadDir: () async => tmp,
      isInstalled: (SrsStarterPack _) async => installed,
      enqueueImport: (SrsStarterPack pack, File file) async => importAvailable
          ? imports.enqueue(
              store: store,
              media: SrsMediaStore(tmp),
              file: file,
              displayName: pack.name,
            )
          : null,
      download: download.call,
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<File> packFile() async =>
      File('${tmp.path}${Platform.pathSeparator}demo.apkg')
        ..writeAsBytesSync(<int>[1, 2, 3, 4]);

  test('连点只下一次；导入结束前再点也不重复入队；导入成功删包', () async {
    final _FakeDownload download = _FakeDownload();
    final SrsStarterPackController c = controller(download);

    final Future<SrsStarterInstallResult> first = c.install(_pack);
    expect(await c.install(_pack), SrsStarterInstallResult.busy);
    await Future<void>.delayed(Duration.zero);
    expect(download.calls, hasLength(1));
    expect(c.stateOf(_pack.id).phase, SrsStarterPackPhase.downloading);

    download.progress.single(2, 4);
    expect(c.stateOf(_pack.id).fraction, 0.5);

    final File file = await packFile();
    download.calls.single.complete(file);
    expect(await first, SrsStarterInstallResult.started);
    expect(c.stateOf(_pack.id).phase, SrsStarterPackPhase.importing);
    expect(imports.tasks, hasLength(1));
    expect(imports.tasks.single.displayName, _pack.name);

    expect(await c.install(_pack), SrsStarterInstallResult.busy);
    expect(download.calls, hasLength(1));
    expect(imports.tasks, hasLength(1), reason: '导入没结束时不重复入队');

    await Future<void>.delayed(Duration.zero);
    importRuns.single.complete(SrsImportReport()..notesAdded = 3);
    await imports.tasks.single.result;
    // 删包是真实文件 IO：等控制器回到空闲（最多 5 秒）。
    for (int i = 0; i < 500; i++) {
      if (c.stateOf(_pack.id).phase == SrsStarterPackPhase.idle) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(c.stateOf(_pack.id).phase, SrsStarterPackPhase.idle);
    expect(await file.exists(), isFalse, reason: '导入成功后删掉下载的包');
  });

  test('当前 profile 已有该牌组：不下载', () async {
    final _FakeDownload download = _FakeDownload();
    final SrsStarterPackController c = controller(download, installed: true);
    expect(await c.install(_pack), SrsStarterInstallResult.alreadyInstalled);
    expect(download.calls, isEmpty);
    expect(imports.tasks, isEmpty);
  });

  test('下载失败：不入队，状态为失败，可重试', () async {
    final _FakeDownload download = _FakeDownload();
    final SrsStarterPackController c = controller(download);
    final Future<SrsStarterInstallResult> r = c.install(_pack);
    await Future<void>.delayed(Duration.zero);
    download.calls.single.completeError(
      const HttpException('download failed (503)'),
    );
    expect(await r, SrsStarterInstallResult.failed);
    expect(c.stateOf(_pack.id).phase, SrsStarterPackPhase.failed);
    expect(c.stateOf(_pack.id).error, isA<HttpException>());
    expect(imports.tasks, isEmpty);

    final Future<SrsStarterInstallResult> retry = c.install(_pack);
    await Future<void>.delayed(Duration.zero);
    expect(download.calls, hasLength(2), reason: '失败后能重试');
    download.calls.last.complete(await packFile());
    expect(await retry, SrsStarterInstallResult.started);
  });

  test('取消：触发取消开关，回到空闲，不入队', () async {
    final _FakeDownload download = _FakeDownload();
    final SrsStarterPackController c = controller(download);
    final Future<SrsStarterInstallResult> r = c.install(_pack);
    await Future<void>.delayed(Duration.zero);
    c.cancel(_pack.id);
    expect(download.tokens.single.isCancelled, isTrue);
    download.calls.single.completeError(const SrsStarterDownloadCancelled());
    expect(await r, SrsStarterInstallResult.cancelled);
    expect(c.stateOf(_pack.id).phase, SrsStarterPackPhase.idle);
    expect(imports.tasks, isEmpty);
  });

  test('导入入口不可用（复习模块关着）：失败，包保留', () async {
    final _FakeDownload download = _FakeDownload();
    final SrsStarterPackController c = controller(
      download,
      importAvailable: false,
    );
    final Future<SrsStarterInstallResult> r = c.install(_pack);
    await Future<void>.delayed(Duration.zero);
    final File file = await packFile();
    download.calls.single.complete(file);
    expect(await r, SrsStarterInstallResult.failed);
    expect(await file.exists(), isTrue);
  });

  test('导入失败：回到失败状态、保留包', () async {
    final _FakeDownload download = _FakeDownload();
    final SrsStarterPackController c = controller(download);
    final Future<SrsStarterInstallResult> r = c.install(_pack);
    await Future<void>.delayed(Duration.zero);
    final File file = await packFile();
    download.calls.single.complete(file);
    expect(await r, SrsStarterInstallResult.started);
    await Future<void>.delayed(Duration.zero);
    importRuns.single.completeError(
      const SrsImportException(SrsImportException.corrupt, 'bad'),
    );
    await expectLater(
      imports.tasks.single.result,
      throwsA(isA<SrsImportException>()),
    );
    await Future<void>.delayed(Duration.zero);
    expect(c.stateOf(_pack.id).phase, SrsStarterPackPhase.failed);
    expect(await file.exists(), isTrue, reason: '重试不必重下');
  });

  test('已安装判定：未删除的同名顶层牌组才算', () async {
    expect(await srsStarterPackInstalled(store, _pack), isFalse);
    final String parent = await store.createDeck('Parent');
    await store.createDeck(_pack.deckName, parentId: parent);
    expect(
      await srsStarterPackInstalled(store, _pack),
      isFalse,
      reason: '子牌组同名不算',
    );
    await store.createDeck(_pack.deckName);
    expect(await srsStarterPackInstalled(store, _pack), isTrue);
  });
}
