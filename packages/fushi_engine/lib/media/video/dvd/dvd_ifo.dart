// DVD-Video 信息文件（IFO）的纯 Dart 解析：只读入库选片要用的那几张表。
//
// - VMG（`VIDEO_TS.IFO`）：`VMGI_MAT`（卷号 / 卷总数 / 标题集数）与 `TT_SRPT`
//   （全盘标题表：每个 title 落在哪个 VTS、是那个 VTS 里的第几个 title、几个章节）。
// - VTS（`VTS_nn_0.IFO`）：`VTS_PTT_SRPT`（每个 title 的章节 → PGC 映射）与
//   `VTS_PGCI`（每条 PGC 的播放时长与 cell 表）。
//
// 字段偏移照 DVD-Video 规范（与 libdvdread `ifo_types.h` 同一份布局），全部大端。
// 菜单、导航命令、调色板、PTL 等与选片无关的表一律不读——菜单由原生 libdvdnav 执行。
//
// 损坏的 IFO 一律抛 [DvdIfoFormatException]，绝不越界读或返回半截结构：选片若在
// 半截数据上做，结果是「静默少一集」，比明确报错难查得多。

import 'dart:typed_data';

/// DVD 逻辑块大小。IFO 里的表位置都以它为单位。
const int kDvdLogicalBlockSize = 2048;

/// IFO 结构不合法（幻数不符、表越界、计数自相矛盾、时间码不是 BCD）。
class DvdIfoFormatException implements Exception {
  const DvdIfoFormatException(this.message);

  final String message;

  @override
  String toString() => 'DvdIfoFormatException: $message';
}

/// `TT_SRPT` 里的一行：全盘第 [titleNumber] 个 title。
class DvdTitleEntry {
  const DvdTitleEntry({
    required this.titleNumber,
    required this.playbackType,
    required this.angleCount,
    required this.chapterCount,
    required this.titleSetNumber,
    required this.titleSetTitleNumber,
    required this.titleSetStartSector,
  });

  /// 全盘 title 号，1 起（libdvdnav `dvdnav_title_play` 的那个号）。
  final int titleNumber;

  /// 播放类型字节（`pb_ty`）：区分「一序列」与「含跳转命令」的 title。
  final int playbackType;

  /// 角度数，单角度为 1。
  final int angleCount;

  /// 章节（PTT）数。
  final int chapterCount;

  /// 所在标题集（VTS）号，1 起：`VTS_<nn>_0.IFO` 的 nn。
  final int titleSetNumber;

  /// 在该 VTS 内的 title 号（VTS_TTN），1 起。
  final int titleSetTitleNumber;

  /// 该 VTS 在盘上的起始扇区。
  final int titleSetStartSector;
}

/// `VIDEO_TS.IFO` 读出的盘级信息。
class DvdVmgInfo {
  const DvdVmgInfo({
    required this.volumeCount,
    required this.volumeNumber,
    required this.discSide,
    required this.titleSetCount,
    required this.providerId,
    required this.titles,
  });

  /// 这一套盘的卷总数（`vmg_nr_of_volumes`）。
  final int volumeCount;

  /// 本盘是第几卷，1 起（`vmg_this_volume_nr`）。
  final int volumeNumber;

  /// 盘面（`disc_side`），单面盘为 1。
  final int discSide;

  /// 标题集（VTS）个数。
  final int titleSetCount;

  /// 制作商 ID（32 字节，去掉尾部 NUL / 空格）。
  final String providerId;

  /// 全盘 title 表，按 title 号升序。
  final List<DvdTitleEntry> titles;
}

/// 一个 cell：PGC 里连续播放的一段扇区。
class DvdCell {
  const DvdCell({
    required this.playbackTime,
    required this.firstSector,
    required this.lastSector,
  });

  final Duration playbackTime;

  /// 首个 VOBU 起始扇区（相对 VTS 的 title VOB）。
  final int firstSector;

  /// 最后一个 VOBU 结束扇区。
  final int lastSector;
}

/// 一条节目链（PGC）。
class DvdProgramChain {
  const DvdProgramChain({
    required this.programCount,
    required this.playbackTime,
    required this.cells,
  });

  final int programCount;

  /// PGC 头里的总播放时长。
  final Duration playbackTime;

  final List<DvdCell> cells;
}

/// 一个 title 的一个章节入口（PTT）。
class DvdPartOfTitle {
  const DvdPartOfTitle({required this.pgcNumber, required this.programNumber});

  /// 1 起的 PGC 号。
  final int pgcNumber;

  /// 1 起的 program 号。
  final int programNumber;
}

/// `VTS_nn_0.IFO` 读出的标题集信息。
class DvdTitleSetInfo {
  const DvdTitleSetInfo({
    required this.partsByTitle,
    required this.programChains,
  });

  /// 下标 i 是本 VTS 第 i+1 个 title 的章节表。
  final List<List<DvdPartOfTitle>> partsByTitle;

  /// 下标 i 是第 i+1 条 PGC；解析失败的 PGC 为 null（只影响引用它的 title）。
  final List<DvdProgramChain?> programChains;

  /// 本 VTS 第 [vtsTitleNumber] 个 title 依次经过的不重复 PGC（1 起 PGC 号）。
  List<int> programChainNumbersForTitle(int vtsTitleNumber) {
    if (vtsTitleNumber < 1 || vtsTitleNumber > partsByTitle.length) {
      return const <int>[];
    }
    final List<int> out = <int>[];
    for (final DvdPartOfTitle part in partsByTitle[vtsTitleNumber - 1]) {
      if (!out.contains(part.pgcNumber)) out.add(part.pgcNumber);
    }
    return out;
  }
}

/// 解析 `VIDEO_TS.IFO`。
DvdVmgInfo parseDvdVmgIfo(Uint8List bytes) {
  final _Reader r = _Reader(bytes, 'VIDEO_TS.IFO');
  r.expectMagic(0, 'DVDVIDEO-VMG');
  final int volumeCount = r.u16(0x26);
  final int volumeNumber = r.u16(0x28);
  final int discSide = r.u8(0x2A);
  final int titleSetCount = r.u16(0x3E);
  final String providerId = r.ascii(0x40, 32);
  final int srptSector = r.u32(0xC4);
  if (srptSector == 0) {
    throw const DvdIfoFormatException('VIDEO_TS.IFO has no TT_SRPT');
  }
  final int base = srptSector * kDvdLogicalBlockSize;
  final int count = r.u16(base);
  if (count == 0 || count > 99) {
    throw DvdIfoFormatException('TT_SRPT title count $count out of range');
  }
  final List<DvdTitleEntry> titles = <DvdTitleEntry>[];
  for (int i = 0; i < count; i++) {
    final int at = base + 8 + i * 12;
    final int vts = r.u8(at + 6);
    final int vtsTitle = r.u8(at + 7);
    if (vts == 0 || vtsTitle == 0) {
      throw DvdIfoFormatException('TT_SRPT title ${i + 1} has no VTS');
    }
    titles.add(
      DvdTitleEntry(
        titleNumber: i + 1,
        playbackType: r.u8(at),
        angleCount: r.u8(at + 1),
        chapterCount: r.u16(at + 2),
        titleSetNumber: vts,
        titleSetTitleNumber: vtsTitle,
        titleSetStartSector: r.u32(at + 8),
      ),
    );
  }
  return DvdVmgInfo(
    volumeCount: volumeCount,
    volumeNumber: volumeNumber,
    discSide: discSide,
    titleSetCount: titleSetCount,
    providerId: providerId,
    titles: List<DvdTitleEntry>.unmodifiable(titles),
  );
}

/// 解析 `VTS_nn_0.IFO`。[name] 只用于报错信息。
DvdTitleSetInfo parseDvdVtsIfo(Uint8List bytes, {String name = 'VTS IFO'}) {
  final _Reader r = _Reader(bytes, name);
  r.expectMagic(0, 'DVDVIDEO-VTS');
  final int pttSector = r.u32(0xC8);
  final int pgciSector = r.u32(0xCC);
  if (pttSector == 0 || pgciSector == 0) {
    throw DvdIfoFormatException('$name lacks VTS_PTT_SRPT or VTS_PGCI');
  }

  // VTS_PTT_SRPT：title 数 + 结束字节 + 每 title 一个相对偏移。
  final int pttBase = pttSector * kDvdLogicalBlockSize;
  final int titleCount = r.u16(pttBase);
  final int pttLastByte = r.u32(pttBase + 4);
  if (titleCount == 0 || titleCount > 99) {
    throw DvdIfoFormatException('$name VTS_PTT_SRPT count $titleCount');
  }
  final List<int> offsets = <int>[
    for (int i = 0; i < titleCount; i++) r.u32(pttBase + 8 + i * 4),
  ];
  final List<List<DvdPartOfTitle>> parts = <List<DvdPartOfTitle>>[];
  for (int i = 0; i < titleCount; i++) {
    final int start = offsets[i];
    final int end = i + 1 < titleCount ? offsets[i + 1] : pttLastByte + 1;
    if (start < 8 + titleCount * 4 || end < start || (end - start) % 4 != 0) {
      throw DvdIfoFormatException('$name VTS_PTT_SRPT title ${i + 1} span');
    }
    final List<DvdPartOfTitle> titleParts = <DvdPartOfTitle>[
      for (int at = start; at < end; at += 4)
        DvdPartOfTitle(
          pgcNumber: r.u16(pttBase + at),
          programNumber: r.u16(pttBase + at + 2),
        ),
    ];
    parts.add(List<DvdPartOfTitle>.unmodifiable(titleParts));
  }

  // VTS_PGCI：PGC 数 + 结束字节 + 每条 8 字节的搜索指针（类别 + 相对偏移）。
  final int pgciBase = pgciSector * kDvdLogicalBlockSize;
  final int pgcCount = r.u16(pgciBase);
  if (pgcCount == 0) {
    throw DvdIfoFormatException('$name VTS_PGCI is empty');
  }
  final List<DvdProgramChain?> chains = <DvdProgramChain?>[];
  for (int i = 0; i < pgcCount; i++) {
    final int offset = r.u32(pgciBase + 8 + i * 8 + 4);
    try {
      chains.add(_parsePgc(r, pgciBase + offset));
    } on DvdIfoFormatException {
      // 一条坏 PGC 只连累引用它的 title（调用方把那些 title 剔掉），不判死整个 VTS。
      chains.add(null);
    }
  }
  for (int i = 0; i < parts.length; i++) {
    for (final DvdPartOfTitle part in parts[i]) {
      if (part.pgcNumber < 1 || part.pgcNumber > pgcCount) {
        throw DvdIfoFormatException(
          '$name title ${i + 1} references PGC ${part.pgcNumber} of $pgcCount',
        );
      }
    }
  }
  return DvdTitleSetInfo(
    partsByTitle: List<List<DvdPartOfTitle>>.unmodifiable(parts),
    programChains: List<DvdProgramChain?>.unmodifiable(chains),
  );
}

DvdProgramChain _parsePgc(_Reader r, int at) {
  final int programCount = r.u8(at + 2);
  final int cellCount = r.u8(at + 3);
  final Duration time = r.dvdTime(at + 4);
  final List<DvdCell> cells = <DvdCell>[];
  if (cellCount > 0) {
    final int cellTable = r.u16(at + 0xE8);
    if (cellTable == 0) {
      throw const DvdIfoFormatException('PGC has cells but no cell table');
    }
    for (int i = 0; i < cellCount; i++) {
      final int c = at + cellTable + i * 24;
      cells.add(
        DvdCell(
          playbackTime: r.dvdTime(c + 4),
          firstSector: r.u32(c + 8),
          lastSector: r.u32(c + 20),
        ),
      );
    }
  }
  return DvdProgramChain(
    programCount: programCount,
    playbackTime: time,
    cells: List<DvdCell>.unmodifiable(cells),
  );
}

/// 4 字节 BCD 时间码（时 分 秒 帧，帧字节高两位是帧率标记）转成时长。
///
/// 帧率标记 `01` = 25 fps、`11` = 30 fps（29.97 按 30 记，与 libdvdread 同口径）；
/// `00` / `10` 是规范外的值，按 0 帧处理（只丢不到一秒的帧数，不判坏）。
Duration decodeDvdTime(Uint8List bytes, int at) {
  int bcd(int value) {
    final int hi = value >> 4;
    final int lo = value & 0x0F;
    if (hi > 9 || lo > 9) {
      throw DvdIfoFormatException(
        'time code byte 0x${value.toRadixString(16)} is not BCD',
      );
    }
    return hi * 10 + lo;
  }

  final int hours = bcd(bytes[at]);
  final int minutes = bcd(bytes[at + 1]);
  final int seconds = bcd(bytes[at + 2]);
  final int frameByte = bytes[at + 3];
  final int rate = switch (frameByte >> 6) {
    1 => 25,
    3 => 30,
    _ => 0,
  };
  final int frames = bcd(frameByte & 0x3F);
  final int frameMs = rate == 0 ? 0 : frames * 1000 ~/ rate;
  return Duration(
    hours: hours,
    minutes: minutes,
    seconds: seconds,
    milliseconds: frameMs,
  );
}

class _Reader {
  _Reader(this.bytes, this.name);

  final Uint8List bytes;
  final String name;

  void _need(int at, int length) {
    if (at < 0 || at + length > bytes.length) {
      throw DvdIfoFormatException(
        '$name: read of $length bytes at $at past end (${bytes.length})',
      );
    }
  }

  int u8(int at) {
    _need(at, 1);
    return bytes[at];
  }

  int u16(int at) {
    _need(at, 2);
    return (bytes[at] << 8) | bytes[at + 1];
  }

  int u32(int at) {
    _need(at, 4);
    return (bytes[at] << 24) |
        (bytes[at + 1] << 16) |
        (bytes[at + 2] << 8) |
        bytes[at + 3];
  }

  String ascii(int at, int length) {
    _need(at, length);
    final StringBuffer out = StringBuffer();
    for (int i = at; i < at + length; i++) {
      final int c = bytes[i];
      if (c == 0) break;
      out.writeCharCode(c >= 0x20 && c < 0x7F ? c : 0x3F);
    }
    return out.toString().trimRight();
  }

  Duration dvdTime(int at) {
    _need(at, 4);
    return decodeDvdTime(bytes, at);
  }

  void expectMagic(int at, String magic) {
    _need(at, magic.length);
    for (int i = 0; i < magic.length; i++) {
      if (bytes[at + i] != magic.codeUnitAt(i)) {
        throw DvdIfoFormatException('$name: missing "$magic" signature');
      }
    }
  }
}
