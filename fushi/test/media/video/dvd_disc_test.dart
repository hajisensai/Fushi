// DVD 入库的引擎层：IFO 解析、title 选片、成员路径、盘身份。全部用程序合成的最小
// IFO（`dvd_fixture.dart`），不碰商业盘。

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/dvd/dvd_disc.dart';
import 'package:fushi_engine/media/video/dvd/dvd_ifo.dart';
import 'package:path/path.dart' as p;

import 'dvd_fixture.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('dvd_disc_'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('IFO 解析', () {
    test('VMG：卷号 / 卷总数 / 标题表', () {
      final DvdVmgInfo vmg = parseDvdVmgIfo(
        buildVmgIfo(
          volumeNumber: 2,
          volumeCount: 3,
          titleSetCount: 2,
          titles: const <FixtureDvdTitle>[
            FixtureDvdTitle(titleSet: 1, vtsTitle: 1, chapters: 12),
            FixtureDvdTitle(titleSet: 2, vtsTitle: 1, chapters: 3),
          ],
        ),
      );
      expect(vmg.volumeNumber, 2);
      expect(vmg.volumeCount, 3);
      expect(vmg.titleSetCount, 2);
      expect(vmg.providerId, 'FUSHI-TEST');
      expect(
        vmg.titles.map((DvdTitleEntry t) => (t.titleNumber, t.titleSetNumber)),
        <(int, int)>[(1, 1), (2, 2)],
      );
      expect(vmg.titles.first.chapterCount, 12);
    });

    test('VTS：章节 → PGC 映射与 PGC 时长、cell 扇区', () {
      final DvdTitleSetInfo vts = parseDvdVtsIfo(
        buildVtsIfo(
          titles: const <FixtureDvdVtsTitle>[
            FixtureDvdVtsTitle(<int>[1, 1, 2]),
          ],
          pgcs: const <FixtureDvdPgc>[
            FixtureDvdPgc(<FixtureDvdCell>[FixtureDvdCell(600, 0, 99)]),
            FixtureDvdPgc(<FixtureDvdCell>[
              FixtureDvdCell(30, 100, 109),
              FixtureDvdCell(45, 110, 129),
            ]),
          ],
        ),
      );
      expect(vts.programChainNumbersForTitle(1), <int>[1, 2]);
      expect(vts.programChains[1]!.playbackTime, const Duration(seconds: 75));
      expect(vts.programChains[1]!.cells.last.firstSector, 110);
      expect(vts.programChains[1]!.cells.last.lastSector, 129);
    });

    test('BCD 时间码：25 fps 帧数折成毫秒；非 BCD 明确报错', () {
      final Uint8List b = Uint8List.fromList(<int>[
        0x01,
        0x23,
        0x45,
        0x40 | 0x10,
      ]);
      expect(
        decodeDvdTime(b, 0),
        const Duration(hours: 1, minutes: 23, seconds: 45, milliseconds: 400),
      );
      expect(
        () => decodeDvdTime(Uint8List.fromList(<int>[0x0A, 0, 0, 0]), 0),
        throwsA(isA<DvdIfoFormatException>()),
      );
    });

    test('损坏的 IFO 抛 DvdIfoFormatException，不越界不崩', () {
      expect(
        () => parseDvdVmgIfo(Uint8List(64)),
        throwsA(isA<DvdIfoFormatException>()),
      );
      final Uint8List vmg = buildVmgIfo(
        titles: const <FixtureDvdTitle>[
          FixtureDvdTitle(titleSet: 1, vtsTitle: 1, chapters: 1),
        ],
      );
      // 截断在 TT_SRPT 之前。
      expect(
        () => parseDvdVmgIfo(Uint8List.sublistView(vmg, 0, 1024)),
        throwsA(isA<DvdIfoFormatException>()),
      );
      final Uint8List vts = buildVtsIfo(
        titles: const <FixtureDvdVtsTitle>[
          FixtureDvdVtsTitle(<int>[3]),
        ],
        pgcs: const <FixtureDvdPgc>[
          FixtureDvdPgc(<FixtureDvdCell>[FixtureDvdCell(600, 0, 99)]),
        ],
      );
      // title 引用了不存在的 PGC 3。
      expect(() => parseDvdVtsIfo(vts), throwsA(isA<DvdIfoFormatException>()));
    });
  });

  group('选片', () {
    test('TV 盘：play-all 与厂标出局，四集按 title 号入选', () async {
      final String root = p.join(tmp.path, 'Show Vol.1');
      writeTvDvdFixture(root);
      final DvdDisc disc = (await readDvdDisc(root))!;
      expect(disc.titles.map((DvdTitle t) => t.titleNumber), <int>[2, 3, 4, 5]);
      expect(disc.titles.map((DvdTitle t) => t.name), <String>[
        'Show Vol.1 - 01',
        'Show Vol.1 - 02',
        'Show Vol.1 - 03',
        'Show Vol.1 - 04',
      ]);
      expect(disc.titles.first.duration, const Duration(minutes: 24));
      expect(disc.titles.every((DvdTitle t) => t.isMainFeature), isTrue);
      expect(
        disc.titles.first.titlePath,
        p.join(root, 'VIDEO_TS', 'TITLE_02.dvdtitle'),
      );
    });

    test('电影盘：正片入选、远短于正片的花絮出局；单条用盘名', () async {
      final String root = p.join(tmp.path, 'Movie');
      writeDvdFixture(
        root,
        titles: const <FixtureDvdTitle>[
          FixtureDvdTitle(titleSet: 1, vtsTitle: 1, chapters: 20),
          FixtureDvdTitle(titleSet: 2, vtsTitle: 1, chapters: 1),
        ],
        titleSets: const <FixtureDvdTitleSet>[
          FixtureDvdTitleSet(
            titles: <FixtureDvdVtsTitle>[
              FixtureDvdVtsTitle(<int>[1]),
            ],
            pgcs: <FixtureDvdPgc>[
              FixtureDvdPgc(<FixtureDvdCell>[FixtureDvdCell(6600, 0, 9999)]),
            ],
          ),
          FixtureDvdTitleSet(
            titles: <FixtureDvdVtsTitle>[
              FixtureDvdVtsTitle(<int>[1]),
            ],
            pgcs: <FixtureDvdPgc>[
              FixtureDvdPgc(<FixtureDvdCell>[FixtureDvdCell(180, 0, 99)]),
            ],
          ),
        ],
      );
      final DvdDisc disc = (await readDvdDisc(root))!;
      expect(disc.titles, hasLength(1));
      expect(disc.titles.single.name, 'Movie');
      expect(disc.titles.single.isMainFeature, isTrue);
      expect(disc.titles.single.chapterCount, 20);
    });

    test('同一内容的两个 title（同 PGC）合并，留章节多的', () {
      DvdTitleCandidate candidate(int number, int chapters) =>
          DvdTitleCandidate(
            entry: DvdTitleEntry(
              titleNumber: number,
              playbackType: 0,
              angleCount: 1,
              chapterCount: chapters,
              titleSetNumber: 1,
              titleSetTitleNumber: number,
              titleSetStartSector: 0,
            ),
            duration: const Duration(minutes: 90),
            cellIds: const <String>['v1:0-99', 'v1:100-199'],
          );
      final List<DvdTitle> titles = selectDvdTitles(
        <DvdTitleCandidate>[candidate(1, 1), candidate(2, 16)],
        discRootPath: '/d',
        discName: 'D',
      );
      expect(titles.map((DvdTitle t) => t.titleNumber), <int>[2]);
    });

    test('VTS 缺 title VOB：落在它上面的 title 出局，其余照常', () async {
      final String root = p.join(tmp.path, 'Half');
      writeDvdFixture(
        root,
        titles: const <FixtureDvdTitle>[
          FixtureDvdTitle(titleSet: 1, vtsTitle: 1, chapters: 1),
          FixtureDvdTitle(titleSet: 2, vtsTitle: 1, chapters: 1),
        ],
        titleSets: const <FixtureDvdTitleSet>[
          FixtureDvdTitleSet(
            titles: <FixtureDvdVtsTitle>[
              FixtureDvdVtsTitle(<int>[1]),
            ],
            pgcs: <FixtureDvdPgc>[
              FixtureDvdPgc(<FixtureDvdCell>[FixtureDvdCell(1500, 0, 99)]),
            ],
          ),
          FixtureDvdTitleSet(
            writeVob: false,
            titles: <FixtureDvdVtsTitle>[
              FixtureDvdVtsTitle(<int>[1]),
            ],
            pgcs: <FixtureDvdPgc>[
              FixtureDvdPgc(<FixtureDvdCell>[FixtureDvdCell(1500, 0, 99)]),
            ],
          ),
        ],
      );
      final DvdDisc disc = (await readDvdDisc(root))!;
      expect(disc.titles.map((DvdTitle t) => t.titleNumber), <int>[1]);
    });

    test('VIDEO_TS.IFO 坏了读 BUP；两份都坏明确报错', () async {
      final String root = p.join(tmp.path, 'Damaged');
      writeTvDvdFixture(root);
      final File ifo = File(p.join(root, 'VIDEO_TS', 'VIDEO_TS.IFO'));
      ifo.writeAsBytesSync(Uint8List(4096));
      expect((await readDvdDisc(root))!.titles, hasLength(4));

      File(
        p.join(root, 'VIDEO_TS', 'VIDEO_TS.BUP'),
      ).writeAsBytesSync(Uint8List(100));
      await expectLater(
        readDvdDisc(root),
        throwsA(isA<DvdIfoFormatException>()),
      );
    });

    test('不是盘返回 null', () async {
      expect(await readDvdDisc(tmp.path), isNull);
    });
  });

  group('成员路径', () {
    final String root = p.join('/lib', 'Show');

    test('title 路径能反推盘根与 title 号，背后的真实文件是 VIDEO_TS.IFO', () {
      final String path = dvdTitlePath(root, 7);
      expect(p.basename(path), 'TITLE_07.dvdtitle');
      expect(isDvdTitlePath(path), isTrue);
      expect(dvdDiscRootForTitlePath(path), p.normalize(root));
      expect(dvdTitleNumberForPath(path), 7);
      expect(
        dvdTitleBackingFilePath(path),
        p.join(p.normalize(root), 'VIDEO_TS', 'VIDEO_TS.IFO'),
      );
    });

    test('形状不对的路径一律不认', () {
      expect(dvdDiscRootForTitlePath('/lib/Show/TITLE_01.dvdtitle'), isNull);
      expect(
        dvdDiscRootForTitlePath('/lib/Show/VIDEO_TS/EXTRA.dvdtitle'),
        isNull,
      );
      expect(
        dvdDiscRootForTitlePath('/lib/Show/video_ts/TITLE_01.dvdtitle'),
        isNull,
      );
      expect(
        dvdTitleNumberForPath('/lib/Show/VIDEO_TS/TITLE_00.dvdtitle'),
        isNull,
      );
      expect(isDvdTitlePath('/lib/Show/VIDEO_TS/VTS_01_1.VOB'), isFalse);
    });

    test('规划层：认 VIDEO_TS/VIDEO_TS.IFO（目录精确大小写），摘整棵 VIDEO_TS', () {
      final List<String> roots = planDvdDiscRoots(<String>[
        '/lib/A/VIDEO_TS/VIDEO_TS.IFO',
        '/lib/A/VIDEO_TS/VTS_01_1.VOB',
        '/lib/B/VIDEO_TS/video_ts.ifo',
        '/lib/C/video_ts/VIDEO_TS.IFO',
        '/lib/D/VIDEO_TS/VTS_01_1.VOB',
      ]);
      expect(roots, <String>[p.normalize('/lib/A'), p.normalize('/lib/B')]);
      final Set<String> set = roots.toSet();
      expect(isInsideDvdDisc('/lib/A/VIDEO_TS/VTS_01_1.VOB', set), isTrue);
      expect(isInsideDvdDisc('/lib/A/extra.vob', set), isFalse);
      expect(isInsideDvdDisc('/lib/D/VIDEO_TS/VTS_01_1.VOB', set), isFalse);
    });
  });

  group('盘身份 DVDDiscID', () {
    test('前 10 个 IFO 依次取整块拼起来求 MD5', () {
      final Uint8List a = Uint8List(4096)..[0] = 1;
      final Uint8List b = Uint8List(2048 + 100)..[5] = 9;
      final String id = computeDvdDiscId(<Uint8List>[a, b]);
      final BytesBuilder expected = BytesBuilder()
        ..add(a)
        ..add(Uint8List.sublistView(b, 0, 2048));
      expect(id, md5.convert(expected.takeBytes()).toString());
    });

    test('文件夹盘：按 VIDEO_TS.IFO、VTS_01_0.IFO… 的顺序取', () async {
      final String root = p.join(tmp.path, 'Id');
      writeTvDvdFixture(root);
      final String id = await computeDvdDiscIdForDirectory(root);
      expect(
        id,
        computeDvdDiscId(<Uint8List>[
          File(p.join(root, 'VIDEO_TS', 'VIDEO_TS.IFO')).readAsBytesSync(),
          File(p.join(root, 'VIDEO_TS', 'VTS_01_0.IFO')).readAsBytesSync(),
        ]),
      );
      expect((await readDvdDisc(root))!.discId, id);
    });
  });

  test('多盘排序：同目录按卷号，再按目录名', () async {
    final String a = p.join(tmp.path, 'Box', 'Disc B');
    final String b = p.join(tmp.path, 'Box', 'Disc A');
    writeTvDvdFixture(a, volumeNumber: 1, volumeCount: 2);
    writeTvDvdFixture(b, volumeNumber: 2, volumeCount: 2);
    final List<DvdDisc> discs = <DvdDisc>[
      (await readDvdDisc(b))!,
      (await readDvdDisc(a))!,
    ]..sort(compareDvdDiscOrder);
    expect(discs.map((DvdDisc d) => d.name), <String>['Disc B', 'Disc A']);
  });
}
