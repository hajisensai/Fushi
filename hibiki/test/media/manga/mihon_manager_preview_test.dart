import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi_core/fushi_core.dart';

/// 扩展「装之前先试用」的生命周期不变量。
///
/// 这个功能唯一的安全承诺不是「没跑代码」——预览必须真跑扩展代码，否则拿不到
/// 任何内容（Mihon 扩展是代码不是配置）。承诺是**不留痕迹**：
/// 预览不写 `manga_extensions` / `manga_online_sources`，不写受信任签名表，
/// 放弃时把落地的 APK 删干净。本文件守的就是这条线。
///
/// Android 特有的那一步（`installPrivateExtension` 把文件放进 `filesDir/exts`，
/// 放弃时 `uninstallPrivateExtension` 删掉）在宿主平台上跑不到——`Platform.isAndroid`
/// 恒为 false，也无法在单测里伪造。所以这里守的是**平台无关的那部分**：库里零
/// 痕迹、temp 文件按 keep 语义处置、拒绝对已安装扩展预览、崩溃标记会被清理。
void main() {
  late Directory root;
  late FushiDatabase database;
  late _PreviewRuntime runtime;
  late MihonManager manager;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('hibiki-mihon-preview-');
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    runtime = _PreviewRuntime();
    manager = MihonManager(
      database: database,
      rootDirectory: root,
      runtime: runtime,
    );
    await manager.initialise();
  });

  tearDown(() async {
    manager.dispose();
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<MihonInstallProposal> prepare(List<int> bytes) async {
    final File apk = File('${root.path}${Platform.pathSeparator}fixture.apk');
    await apk.writeAsBytes(bytes, flush: true);
    return manager.prepareLocalInstall(apk.path);
  }

  test('预览拿得到源，但库里一点痕迹都不留', () async {
    final MihonPreviewSession session = await manager.beginPreview(
      await prepare(<int>[1, 2, 3]),
    );

    expect(session.sources, hasLength(1));
    expect(session.sources.single.name, 'Fixture source');
    // 扩展引用指向 staged 的那份文件，不是 extensions/ 下的常驻路径。
    expect(session.extension.packageName, 'org.example.fixture');

    // 这三张表是「已安装」的唯一真相源：一条都不能多。
    expect(await database.getMangaExtensions(), isEmpty);
    expect(await database.getMangaOnlineSources(), isEmpty);
    expect(await database.isMangaSignerTrusted('aabb'), isFalse);
    // manager 的内存视图同样不该出现它，否则会渗进「浏览」视图。
    expect(manager.installed, isEmpty);
    expect(manager.sources, isEmpty);

    await manager.endPreview(session, keep: false);
  });

  test('放弃预览会把 staged 的 APK 删干净', () async {
    final MihonInstallProposal proposal = await prepare(<int>[1, 2, 3]);
    final MihonPreviewSession session = await manager.beginPreview(proposal);
    expect(await File(proposal.tempPath).exists(), isTrue);

    await manager.endPreview(session, keep: false);

    expect(
      await File(proposal.tempPath).exists(),
      isFalse,
      reason: '放弃后不该留下最大 100 MiB 的半成品',
    );
    expect(await _stagedApks(root), isEmpty);
  });

  test('接受预览会保留 staged 的 APK 给 commitInstall 复用', () async {
    final MihonInstallProposal proposal = await prepare(<int>[1, 2, 3]);
    final MihonPreviewSession session = await manager.beginPreview(proposal);

    await manager.endPreview(session, keep: true);

    expect(
      await File(proposal.tempPath).exists(),
      isTrue,
      reason: 'keep 语义就是「接着要装」，删了 commitInstall 就没东西可搬',
    );
    // 但仍然只是 staged：在 commitInstall 之前，库里依旧什么都没有。
    expect(await database.getMangaExtensions(), isEmpty);
  });

  test('预览完接着安装，走的是同一份文件且真的落库', () async {
    final MihonInstallProposal proposal = await prepare(<int>[1, 2, 3]);
    final MihonPreviewSession session = await manager.beginPreview(proposal);
    await manager.endPreview(session, keep: true);

    await manager.commitInstall(proposal, trustSigner: true);

    final MangaExtensionRow? row =
        await database.getMangaExtension('org.example.fixture');
    expect(row, isNotNull);
    expect(row!.versionCode, 1);
    expect(await database.getMangaOnlineSources(), hasLength(1));
    expect(await database.isMangaSignerTrusted('aabb'), isTrue);
    expect(
      await _stagedApks(root),
      isEmpty,
      reason: 'commitInstall 应该把 staged 文件搬走或删掉，不留残骸',
    );
  });

  test('已安装的扩展不给预览（会顶掉用户正在用的那份）', () async {
    final MihonInstallProposal first = await prepare(<int>[1, 2, 3]);
    await manager.commitInstall(first, trustSigner: true);

    runtime.versionCode = 2;
    final MihonInstallProposal update = await prepare(<int>[4, 5, 6]);
    await expectLater(
      manager.beginPreview(update),
      throwsA(
        isA<MihonRuntimeException>().having(
          (MihonRuntimeException error) => error.code,
          'code',
          'PREVIEW_ALREADY_INSTALLED',
        ),
      ),
    );
  });

  test('扩展一个源都不给时预览失败，且不留残骸', () async {
    runtime.emptySources = true;
    final MihonInstallProposal proposal = await prepare(<int>[1, 2, 3]);

    await expectLater(
      manager.beginPreview(proposal),
      throwsA(
        isA<MihonRuntimeException>().having(
          (MihonRuntimeException error) => error.code,
          'code',
          'NO_SOURCES',
        ),
      ),
    );

    expect(await File(proposal.tempPath).exists(), isFalse);
    expect(await _previewMarker(root).exists(), isFalse);
    expect(await database.getMangaExtensions(), isEmpty);
  });

  test('取消安装提案会把已下载的 APK 丢掉', () async {
    final MihonInstallProposal proposal = await prepare(<int>[1, 2, 3]);
    expect(await File(proposal.tempPath).exists(), isTrue);

    await manager.discardProposal(proposal);

    expect(await File(proposal.tempPath).exists(), isFalse);
  });

  test('上次进程在预览中途被杀，下次启动清掉标记和半成品', () async {
    // 直接伪造崩溃现场：标记还在、staged APK 还在、库里没有对应记录。
    manager.dispose();
    final File marker = _previewMarker(root);
    await marker.parent.create(recursive: true);
    await marker.writeAsString('org.example.orphan', flush: true);
    final File staged = File(
      '${root.path}${Platform.pathSeparator}tmp'
      '${Platform.pathSeparator}extension-deadbeef.apk.part',
    );
    await staged.writeAsBytes(<int>[9], flush: true);

    manager = MihonManager(
      database: database,
      rootDirectory: root,
      runtime: runtime,
    );
    await manager.initialise();

    expect(
      await marker.exists(),
      isFalse,
      reason: '标记不清掉，下次预览同一个包时判断孤儿的依据就是脏的',
    );
    expect(
      await staged.exists(),
      isFalse,
      reason: '半成品 APK 每个最大 100 MiB，崩一次留一个',
    );
  });
}

File _previewMarker(Directory root) => File(
      '${root.path}${Platform.pathSeparator}tmp'
      '${Platform.pathSeparator}preview-pending',
    );

Future<List<FileSystemEntity>> _stagedApks(Directory root) async {
  final Directory tmp = Directory(
    '${root.path}${Platform.pathSeparator}tmp',
  );
  if (!await tmp.exists()) return const <FileSystemEntity>[];
  return tmp
      .list()
      .where(
        (FileSystemEntity entity) => entity.path.endsWith('.apk.part'),
      )
      .toList();
}

class _PreviewRuntime extends Fake implements MihonRuntime {
  int versionCode = 1;
  bool emptySources = false;

  @override
  Future<MihonExtensionInspection> inspectExtension(String apkPath) async =>
      MihonExtensionInspection(
        packageName: 'org.example.fixture',
        name: 'Fixture extension',
        versionCode: versionCode,
        versionName: '1.6.$versionCode',
        libVersion: '1.6',
        signerSha256: 'aabb',
        sourceClasses: const <String>['FixtureSource'],
      );

  @override
  Future<String> installPrivateExtension(String apkPath) async => apkPath;

  @override
  Future<void> uninstallPrivateExtension(String packageName) async {}

  @override
  Future<List<MihonSource>> listSources(
    MihonExtensionRef extension, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    if (emptySources) return const <MihonSource>[];
    return const <MihonSource>[
      MihonSource(
        extensionPackage: 'org.example.fixture',
        id: '9223372036854775807',
        name: 'Fixture source',
        language: 'en',
        baseUrl: 'https://source.example',
      ),
    ];
  }

  @override
  Future<void> invalidateExtension(String packageName) async {}

  @override
  Future<void> dispose() async {}
}
