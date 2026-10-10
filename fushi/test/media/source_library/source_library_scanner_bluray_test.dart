// 蓝光盘入库的合集对号（PR #1604 审查）：合集不能只按盘名全局对号。
//
// 盘名在无 META 时就是目录名，而压制 / 抓取出来的盘目录名极常见是 `DISC1` / `BDROM`
// / `Vol.1`——一个系列多卷就是 `S1/DISC1/BDMV` 与 `S2/DISC1/BDMV`。若第二张盘被对到
// 第一张的合集上，两张盘的 `00001.mpls` 基身份相同被判「已是成员」、第一张独有的标题
// 被移出，每次重扫按盘顺序把成员翻一遍。这里用真 Drift 库 + 真临时目录铺两张同名盘
// 走完整条扫描，钉住「各自一条合集、重扫成员不动」。

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/bluray/bluray_library_title.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:path/path.dart' as p;

import '../video/bluray_fixture.dart';

/// 立刻失败的 ffmpeg 后端：导入路径不该起 ffmpeg，起了也不能等真超时。
class _NoFfmpeg implements FfmpegBackend {
  /// 查询类命令（BUG-2938 新增原语）：本假件不区分，交给 [run]。
  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) =>
      run(args, timeout);

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async =>
      const FfmpegRunResult(returnCode: 1, output: 'stub');

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) async =>
      const FfmpegRunResult(returnCode: 1, output: 'stub');
}

FushiDatabase _memDb() => FushiDatabase.forTesting(NativeDatabase.memory());

Future<SourceLibraryRow> _videoSource(FushiDatabase db, String root) async {
  final int id = await db.insertMediaSource(
    MediaSourcesCompanion.insert(
      label: 'Vids',
      mediaKind: 'video',
      rootPath: root,
      createdAt: 1000,
    ),
  );
  return (await db.getMediaSourceById(id))!;
}

/// 在 [root] 下铺一张盘：每个 [clips] 一条整段用满的标题，时长取 [secondsOf]
/// （缺省 1500 秒）。
void _writeDisc(
  String root,
  List<String> clips, {
  Map<String, int> secondsOf = const <String, int>{},
}) {
  for (final String dir in <String>['PLAYLIST', 'CLIPINF', 'STREAM']) {
    Directory(p.join(root, 'BDMV', dir)).createSync(recursive: true);
  }
  for (int i = 0; i < clips.length; i++) {
    final String clip = clips[i];
    const int start = 45000 * 4;
    final int seconds = secondsOf[clip] ?? 1500;
    File(
      p.join(root, 'BDMV', 'PLAYLIST', '0000${i + 1}.mpls'),
    ).writeAsBytesSync(
      buildMplsFixture(
        playItems: <FixturePlayItem>[
          FixturePlayItem(
            clipId: clip,
            inTimeTicks: start,
            outTimeTicks: start + 45000 * seconds,
          ),
        ],
        marks: const <FixtureMark>[
          FixtureMark(playItemIndex: 0, timestampTicks: start),
        ],
      ),
    );
    File(p.join(root, 'BDMV', 'CLIPINF', '$clip.clpi')).writeAsBytesSync(
      buildClpiFixture(
        presentationStartTicks: start,
        presentationEndTicks: start + 45000 * seconds,
      ),
    );
    File(
      p.join(root, 'BDMV', 'STREAM', '$clip.m2ts'),
    ).writeAsBytesSync(Uint8List(4096));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('scan_bluray_');
    setFfmpegBackendForTesting(_NoFfmpeg());
    AppPaths.debugResetDocumentsLayoutCache();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async => switch (call.method) {
            'getApplicationDocumentsDirectory' => p.join(tmp.path, 'documents'),
            'getTemporaryDirectory' => p.join(tmp.path, 'systemp'),
            'getApplicationSupportDirectory' => p.join(tmp.path, 'support'),
            _ => null,
          },
        );
  });
  tearDown(() {
    setFfmpegBackendForTesting(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    AppPaths.debugResetDocumentsLayoutCache();
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<Map<String, Set<String>>> membersByCollection(FushiDatabase db) async {
    final VideoBookRepository repo = VideoBookRepository(db);
    final Map<String, Set<String>> result = <String, Set<String>>{};
    for (final MediaCollectionRow c in await repo.getAllMediaCollections()) {
      if (c.collectionType != 'playlist') continue;
      final Set<String> paths = <String>{};
      for (final MediaCollectionItemRow item in await repo.getCollectionItems(
        c.id,
      )) {
        final VideoBookRow? row = await repo.getByBookUid(item.entryKey);
        if (row != null) paths.add(p.normalize(row.videoPath));
      }
      result[c.name] = paths;
    }
    return result;
  }

  test('两张目录同名的盘各自一条合集，重扫成员不互相吞', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final String disc1 = p.join(tmp.path, 'S1', 'DISC1');
    final String disc2 = p.join(tmp.path, 'S2', 'DISC1');
    // 第一张三条标题、第二张两条：同名对号时第二张会把第一张独有的 00003 移出。
    _writeDisc(disc1, <String>['00011', '00012', '00013']);
    _writeDisc(disc2, <String>['00021', '00022']);

    final SourceLibraryScanner scanner = SourceLibraryScanner(db);
    final SourceScanSummary first = await scanner.scan(
      await _videoSource(db, tmp.path),
    );
    expect(first.succeeded, isTrue, reason: first.error ?? '');

    final Map<String, Set<String>> members = await membersByCollection(db);
    expect(members.keys, unorderedEquals(<String>['DISC1', 'DISC1 (S2)']));
    expect(members['DISC1'], <String>{
      for (final String n in <String>['00001', '00002', '00003'])
        p.normalize(p.join(disc1, 'BDMV', 'PLAYLIST', '$n.mpls')),
    });
    expect(members['DISC1 (S2)'], <String>{
      for (final String n in <String>['00001', '00002'])
        p.normalize(p.join(disc2, 'BDMV', 'PLAYLIST', '$n.mpls')),
    });

    // 重扫：对回各自的合集，成员一条不动、不新建第三条。
    final SourceScanSummary second = await scanner.scan(
      await _videoSource(db, tmp.path),
    );
    expect(second.succeeded, isTrue, reason: second.error ?? '');
    final Map<String, Set<String>> again = await membersByCollection(db);
    expect(again, members);
  });

  // 原盘菜单首版（2026-10-08）给「只能从菜单进入的特典」手写建行：没有来源、不进盘
  // 合集、名字写成「盘目录名 · 00003」。刮削的每道入口都按来源挑条目，这一行在结构
  // 上永远刮不到（用户：「这个都是bd了，为什么还能没刮削出来」）。
  group('原盘菜单进入的特典按扫描导入的规则入库', () {
    late FushiDatabase db;
    late SourceLibraryRow source;
    late String disc;
    late String bonus;

    setUp(() async {
      db = _memDb();
      disc = p.join(tmp.path, 'Kaguya', 'DISC2');
      // 两条正片 + 一条 60 秒特典：特典低于相对时长下限，扫描不选它。
      _writeDisc(
        disc,
        <String>['00011', '00012', '00013'],
        secondsOf: const <String, int>{'00013': 60},
      );
      bonus = p.join(disc, 'BDMV', 'PLAYLIST', '00003.mpls');
      source = await _videoSource(db, tmp.path);
      final SourceScanSummary scan = await SourceLibraryScanner(
        db,
      ).scan(source);
      expect(scan.succeeded, isTrue, reason: scan.error ?? '');
    });
    tearDown(() => db.close());

    Future<Set<String>> discMembers() async =>
        (await membersByCollection(db))['DISC2']!;

    test('补来源、进盘合集、名字取盘名；重复调用幂等', () async {
      expect(await discMembers(), isNot(contains(p.normalize(bonus))));

      final VideoBookRow row = (await ensureBlurayTitleInLibrary(db, bonus))!;
      expect(row.sourceId, source.id);
      expect(row.title, 'DISC2 - 00003');
      expect(await discMembers(), contains(p.normalize(bonus)));

      final VideoBookRow again = (await ensureBlurayTitleInLibrary(db, bonus))!;
      expect(again.bookUid, row.bookUid);
      final List<VideoBookRow> onBonus = <VideoBookRow>[
        for (final VideoBookRow b in await VideoBookRepository(db).listAll())
          if (p.equals(b.videoPath, bonus)) b,
      ];
      expect(onBonus, hasLength(1));
    });

    test('重扫不把菜单进过的特典移出盘合集', () async {
      await ensureBlurayTitleInLibrary(db, bonus);
      final SourceScanSummary rescan = await SourceLibraryScanner(
        db,
      ).scan(source);
      expect(rescan.succeeded, isTrue, reason: rescan.error ?? '');
      expect(await discMembers(), contains(p.normalize(bonus)));
      final VideoBookRow row = (await VideoBookRepository(
        db,
      ).findByVideoPath(bonus))!;
      expect(row.sourceId, source.id);
    });

    test('首版建出的无来源孤儿行自愈：补来源、进合集、改回盘名', () async {
      final VideoBookRepository repo = VideoBookRepository(db);
      await repo.saveVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'video/00003 (8)',
          title: 'DISC2 · 00003',
          videoPath: bonus,
          importedAt: const Value<int?>(1),
        ),
      );
      final VideoBookRow healed = (await ensureBlurayTitleInLibrary(
        db,
        bonus,
      ))!;
      expect(healed.bookUid, 'video/00003 (8)');
      expect(healed.sourceId, source.id);
      expect(healed.title, 'DISC2 - 00003');
      expect(await discMembers(), contains(p.normalize(bonus)));
    });

    test('用户改过的标题不被覆盖', () async {
      final VideoBookRepository repo = VideoBookRepository(db);
      await repo.saveVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'video/00003',
          title: '制作特辑',
          videoPath: bonus,
          importedAt: const Value<int?>(1),
        ),
      );
      final VideoBookRow row = (await ensureBlurayTitleInLibrary(db, bonus))!;
      expect(row.title, '制作特辑');
    });
  });
}
