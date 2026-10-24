// 字节级合成 DVD IFO（`VIDEO_TS.IFO` / `VTS_nn_0.IFO`），给 DVD 解析与选片测试当输入。
//
// 与 `bluray_fixture.dart` 同理：不往仓库里塞商业盘的 IFO，按 DVD-Video 规范布局手拼
// 最小合法结构，每个字段都能单独拨动（卷号、play-all、坏 PGC、缺 VOB……）。

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

const int _kBlock = 2048;

/// 一个 cell：时长 + 扇区范围。
class FixtureDvdCell {
  const FixtureDvdCell(this.seconds, this.firstSector, this.lastSector);

  final int seconds;
  final int firstSector;
  final int lastSector;
}

/// 一条 PGC。
class FixtureDvdPgc {
  const FixtureDvdPgc(this.cells, {this.headerSeconds});

  final List<FixtureDvdCell> cells;

  /// PGC 头里的总时长；null = 按 cells 之和写。
  final int? headerSeconds;
}

/// VTS 里的一个 title：章节依次落在哪些 PGC（1 起）上。
class FixtureDvdVtsTitle {
  const FixtureDvdVtsTitle(this.chapterPgcs);

  final List<int> chapterPgcs;
}

/// TT_SRPT 的一行。
class FixtureDvdTitle {
  const FixtureDvdTitle({
    required this.titleSet,
    required this.vtsTitle,
    required this.chapters,
  });

  final int titleSet;
  final int vtsTitle;
  final int chapters;
}

void _putU16(Uint8List b, int at, int v) {
  b[at] = (v >> 8) & 0xFF;
  b[at + 1] = v & 0xFF;
}

void _putU32(Uint8List b, int at, int v) {
  b[at] = (v >> 24) & 0xFF;
  b[at + 1] = (v >> 16) & 0xFF;
  b[at + 2] = (v >> 8) & 0xFF;
  b[at + 3] = v & 0xFF;
}

void _putAscii(Uint8List b, int at, String s) {
  for (int i = 0; i < s.length; i++) {
    b[at + i] = s.codeUnitAt(i);
  }
}

int _bcd(int v) => ((v ~/ 10) << 4) | (v % 10);

/// 写 4 字节 BCD 时间码（30 fps 标记，0 帧）。
void putDvdTime(Uint8List b, int at, int totalSeconds, {int frames = 0}) {
  b[at] = _bcd(totalSeconds ~/ 3600);
  b[at + 1] = _bcd(totalSeconds ~/ 60 % 60);
  b[at + 2] = _bcd(totalSeconds % 60);
  b[at + 3] = 0xC0 | _bcd(frames);
}

/// `VIDEO_TS.IFO`。
Uint8List buildVmgIfo({
  required List<FixtureDvdTitle> titles,
  int volumeNumber = 1,
  int volumeCount = 1,
  int titleSetCount = 1,
}) {
  final Uint8List b = Uint8List(_kBlock * 2);
  _putAscii(b, 0, 'DVDVIDEO-VMG');
  _putU16(b, 0x26, volumeCount);
  _putU16(b, 0x28, volumeNumber);
  b[0x2A] = 1;
  _putU16(b, 0x3E, titleSetCount);
  _putAscii(b, 0x40, 'FUSHI-TEST');
  _putU32(b, 0xC4, 1);
  const int base = _kBlock;
  _putU16(b, base, titles.length);
  _putU32(b, base + 4, 8 + titles.length * 12 - 1);
  for (int i = 0; i < titles.length; i++) {
    final int at = base + 8 + i * 12;
    final FixtureDvdTitle t = titles[i];
    b[at] = 0x3C;
    b[at + 1] = 1;
    _putU16(b, at + 2, t.chapters);
    b[at + 6] = t.titleSet;
    b[at + 7] = t.vtsTitle;
    _putU32(b, at + 8, 0x100 * t.titleSet);
  }
  return b;
}

/// `VTS_nn_0.IFO`：PTT_SRPT 在第 1 块，PGCI 从第 2 块起。
Uint8List buildVtsIfo({
  required List<FixtureDvdVtsTitle> titles,
  required List<FixtureDvdPgc> pgcs,
}) {
  const int pgcHeader = 0xEC;
  final int pgciSize =
      8 +
      pgcs.length * 8 +
      pgcs.fold<int>(
        0,
        (int s, FixtureDvdPgc g) => s + pgcHeader + g.cells.length * 24,
      );
  final int pgciBlocks = (pgciSize + _kBlock - 1) ~/ _kBlock;
  final Uint8List b = Uint8List(_kBlock * (2 + pgciBlocks));
  _putAscii(b, 0, 'DVDVIDEO-VTS');
  _putU32(b, 0xC8, 1);
  _putU32(b, 0xCC, 2);

  // VTS_PTT_SRPT
  const int ptt = _kBlock;
  _putU16(b, ptt, titles.length);
  int cursor = 8 + titles.length * 4;
  for (int i = 0; i < titles.length; i++) {
    _putU32(b, ptt + 8 + i * 4, cursor);
    for (int c = 0; c < titles[i].chapterPgcs.length; c++) {
      _putU16(b, ptt + cursor, titles[i].chapterPgcs[c]);
      _putU16(b, ptt + cursor + 2, c + 1);
      cursor += 4;
    }
  }
  _putU32(b, ptt + 4, cursor - 1);

  // VTS_PGCI
  const int pgci = _kBlock * 2;
  _putU16(b, pgci, pgcs.length);
  int offset = 8 + pgcs.length * 8;
  for (int i = 0; i < pgcs.length; i++) {
    final FixtureDvdPgc pgc = pgcs[i];
    b[pgci + 8 + i * 8] = 0x81;
    _putU32(b, pgci + 8 + i * 8 + 4, offset);
    final int at = pgci + offset;
    b[at + 2] = pgc.cells.length;
    b[at + 3] = pgc.cells.length;
    final int total =
        pgc.headerSeconds ??
        pgc.cells.fold<int>(0, (int s, FixtureDvdCell c) => s + c.seconds);
    putDvdTime(b, at + 4, total);
    _putU16(b, at + 0xE8, pgcHeader);
    for (int c = 0; c < pgc.cells.length; c++) {
      final int cell = at + pgcHeader + c * 24;
      putDvdTime(b, cell + 4, pgc.cells[c].seconds);
      _putU32(b, cell + 8, pgc.cells[c].firstSector);
      _putU32(b, cell + 20, pgc.cells[c].lastSector);
    }
    offset += pgcHeader + pgc.cells.length * 24;
  }
  _putU32(b, pgci + 4, offset - 1);
  return b;
}

/// 一个 VTS 的完整描述：IFO 内容 + 是否铺 title VOB。
class FixtureDvdTitleSet {
  const FixtureDvdTitleSet({
    required this.titles,
    required this.pgcs,
    this.writeVob = true,
  });

  final List<FixtureDvdVtsTitle> titles;
  final List<FixtureDvdPgc> pgcs;
  final bool writeVob;
}

/// 在 [root] 下铺一张文件夹形态的 DVD：`VIDEO_TS/` 下 VMG IFO + BUP、各 VTS 的
/// IFO + BUP、一个空的 `VTS_nn_1.VOB`（[FixtureDvdTitleSet.writeVob]）与菜单 VOB。
void writeDvdFixture(
  String root, {
  required List<FixtureDvdTitle> titles,
  required List<FixtureDvdTitleSet> titleSets,
  int volumeNumber = 1,
  int volumeCount = 1,
}) {
  final Directory dir = Directory(p.join(root, 'VIDEO_TS'))
    ..createSync(recursive: true);
  final Uint8List vmg = buildVmgIfo(
    titles: titles,
    volumeNumber: volumeNumber,
    volumeCount: volumeCount,
    titleSetCount: titleSets.length,
  );
  File(p.join(dir.path, 'VIDEO_TS.IFO')).writeAsBytesSync(vmg);
  File(p.join(dir.path, 'VIDEO_TS.BUP')).writeAsBytesSync(vmg);
  File(p.join(dir.path, 'VIDEO_TS.VOB')).writeAsBytesSync(Uint8List(16));
  for (int i = 0; i < titleSets.length; i++) {
    final String stem = 'VTS_${(i + 1).toString().padLeft(2, '0')}';
    final Uint8List vts = buildVtsIfo(
      titles: titleSets[i].titles,
      pgcs: titleSets[i].pgcs,
    );
    File(p.join(dir.path, '${stem}_0.IFO')).writeAsBytesSync(vts);
    File(p.join(dir.path, '${stem}_0.BUP')).writeAsBytesSync(vts);
    if (titleSets[i].writeVob) {
      File(p.join(dir.path, '${stem}_1.VOB')).writeAsBytesSync(Uint8List(16));
    }
  }
}

/// 典型 TV 盘：VTS 1 里 4 集各一条 PGC（每集 24 分钟、3 个 cell），title 1 是
/// 把 4 集串起来的 play-all，title 2~5 是各集，title 6 是 8 秒厂标（单独一个 PGC）。
void writeTvDvdFixture(
  String root, {
  int volumeNumber = 1,
  int volumeCount = 1,
}) {
  final List<FixtureDvdPgc> episodes = <FixtureDvdPgc>[
    for (int e = 0; e < 4; e++)
      FixtureDvdPgc(<FixtureDvdCell>[
        for (int c = 0; c < 3; c++)
          FixtureDvdCell(480, 1000 * e + 300 * c, 1000 * e + 300 * c + 299),
      ]),
  ];
  final FixtureDvdPgc playAll = FixtureDvdPgc(<FixtureDvdCell>[
    for (final FixtureDvdPgc pgc in episodes) ...pgc.cells,
  ]);
  writeDvdFixture(
    root,
    volumeNumber: volumeNumber,
    volumeCount: volumeCount,
    titles: <FixtureDvdTitle>[
      const FixtureDvdTitle(titleSet: 1, vtsTitle: 1, chapters: 4),
      for (int e = 0; e < 4; e++)
        FixtureDvdTitle(titleSet: 1, vtsTitle: e + 2, chapters: 1),
      const FixtureDvdTitle(titleSet: 1, vtsTitle: 6, chapters: 1),
    ],
    titleSets: <FixtureDvdTitleSet>[
      FixtureDvdTitleSet(
        // PGC 1 = play-all，2..5 = 各集，6 = 厂标。
        pgcs: <FixtureDvdPgc>[
          playAll,
          ...episodes,
          const FixtureDvdPgc(<FixtureDvdCell>[FixtureDvdCell(8, 9000, 9010)]),
        ],
        titles: <FixtureDvdVtsTitle>[
          const FixtureDvdVtsTitle(<int>[1, 1, 1, 1]),
          for (int e = 0; e < 4; e++) FixtureDvdVtsTitle(<int>[e + 2]),
          const FixtureDvdVtsTitle(<int>[6]),
        ],
      ),
    ],
  );
}

/// 电影盘带特典：title 1 是 110 分钟正片（VTS 1，20 章）；title 2 是 5 分钟制作
/// 特辑、title 3 是 30 秒预告（同在 VTS 2）；title 4 是菜单背景循环（VTS 3，同一段
/// cell 连排两次，共 4 分钟）。正片之外只有 title 2 算特典。
void writeMovieWithExtrasDvdFixture(String root) {
  writeDvdFixture(
    root,
    titles: const <FixtureDvdTitle>[
      FixtureDvdTitle(titleSet: 1, vtsTitle: 1, chapters: 20),
      FixtureDvdTitle(titleSet: 2, vtsTitle: 1, chapters: 1),
      FixtureDvdTitle(titleSet: 2, vtsTitle: 2, chapters: 1),
      FixtureDvdTitle(titleSet: 3, vtsTitle: 1, chapters: 1),
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
          FixtureDvdVtsTitle(<int>[2]),
        ],
        pgcs: <FixtureDvdPgc>[
          FixtureDvdPgc(<FixtureDvdCell>[FixtureDvdCell(300, 0, 499)]),
          FixtureDvdPgc(<FixtureDvdCell>[FixtureDvdCell(30, 500, 549)]),
        ],
      ),
      FixtureDvdTitleSet(
        titles: <FixtureDvdVtsTitle>[
          FixtureDvdVtsTitle(<int>[1]),
        ],
        pgcs: <FixtureDvdPgc>[
          FixtureDvdPgc(<FixtureDvdCell>[
            FixtureDvdCell(120, 0, 99),
            FixtureDvdCell(120, 0, 99),
          ]),
        ],
      ),
    ],
  );
}
