/// 音乐语境下的光盘（音乐方案 §9.2）：演唱会 / MV 合集 DVD·蓝光的「章节导入为曲目」。
///
/// 盘在曲库里是一张带 `DVD` / `BD` 角标的专辑（不设「光盘」分区）；它的曲目是某个
/// title（DVD title / BD 播放列表）里的一个章节，**与 CUE 虚拟曲目同一个约定**：
///
///   * `music_tracks.path` = title 的身份路径——DVD 是虚拟成员路径
///     `<盘根>/VIDEO_TS/TITLE_nn.dvdtitle`（`dvd_title_path.dart`），BD 是真实的
///     `BDMV/PLAYLIST/<id>.mpls`；
///   * `cue_start_ms` / `cue_end_ms` = 章节在 title 时间轴上的起止。
///
/// 于是吃「整轨 + 起止」的下游（ffmpeg 的 `-ss/-t` 经 `DvdFfmpegBackend` /
/// `BlurayFfmpegBackend` 改写成 dvdvideo demuxer / concat，R128 扫描、声纹）原样可用；
/// 播放端把 title 换成 mpv 吃得下的源再套 EDL 段（`music_disc_media.dart`）。
///
/// **为什么不用 dvdvideo demuxer 自己的 `chapter_start` / `chapter_end` 裁章节**：实测
/// （2026-10-24，统一 FFmpeg 9.0.1，自制 NTSC 测试盘 0 / 1.8 / 4.2 / 6.0 s）它按 VOBU 粒度
/// 截，三章分别只出 1.44 / 2.08 / 1.79 s，相邻两章之间各丢约 0.36 s——不是「起止精确」。
/// 整 title 读出再按时间裁（EDL 段 / `-ss` `-t`）才对得上章节点。
///
/// 纯 Dart、不碰 Flutter（引擎纯度守卫）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/video/bluray/bluray_disc.dart';
import 'package:fushi_engine/media/video/bluray/bluray_playlist.dart';
import 'package:fushi_engine/media/video/disc/disc_format.dart';
import 'package:fushi_engine/media/video/disc/disc_image_probe.dart';
import 'package:fushi_engine/media/video/dvd/dvd_disc.dart';

/// 光盘种类（`music_disc_sources.kind` 的持久化值）。
enum MusicDiscKind {
  dvd('dvd'),
  bluray('bluray'),
  cdda('cdda');

  const MusicDiscKind(this.wire);

  final String wire;

  static MusicDiscKind? fromWire(String? wire) {
    for (final MusicDiscKind k in values) {
      if (k.wire == wire) return k;
    }
    return null;
  }
}

/// 短于它的章节并进相邻章节：BD 播放列表尾部常有一个约 1 s 的黑场收尾章节点（实测一张
/// TV BD 每条播放列表结尾都有一个 1.06 s 的），DVD 菜单式盘也会在开头放一段黑场章节——
/// 单独成曲只会多出一首「0:01」。取 1.5 s：盖住这类收尾章节，又不吞掉短章节（自制测试盘
/// 的章节只有 1.8 s）。
const Duration kMusicDiscMinimumChapter = Duration(milliseconds: 1500);

/// 一个章节（= 一首曲目）。
class MusicDiscChapter {
  const MusicDiscChapter({
    required this.number,
    required this.start,
    required this.end,
  });

  /// 1 起的章节号（合并过短章节后仍取原盘上的号，便于和盘上的章节菜单对照）。
  final int number;
  final Duration start;
  final Duration end;

  Duration get duration => end - start;

  @override
  bool operator ==(Object other) =>
      other is MusicDiscChapter &&
      other.number == number &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(number, start, end);

  @override
  String toString() => 'MusicDiscChapter($number, $start–$end)';
}

/// 盘上一个可导入的 title（DVD title / BD 播放列表）。
class MusicDiscTitle {
  const MusicDiscTitle({
    required this.titlePath,
    required this.number,
    required this.label,
    required this.duration,
    required this.chapters,
    required this.isMainFeature,
  });

  /// 身份路径（DVD 虚拟成员路径 / BD `.mpls`），即导入后曲目的 `path`。
  final String titlePath;

  /// DVD 全盘 title 号 / BD 播放列表号（`00012` → 12）。
  final int number;

  /// 展示名（`Title 3` / `00012`），由调用方本地化；这里给原盘上的编号串。
  final String label;
  final Duration duration;

  /// 章节表；章节起点不可知（DVD program map 缺失）时为空。
  final List<MusicDiscChapter> chapters;

  /// 导入时默认勾选的那条：章节最多的 title（演唱会正片 / MV 合集的 play-all），章节数
  /// 相同取长的；都只有一章时取最长的。**不沿用视频入库的「正片」判定**——实测一张 TV BD
  /// 上视频侧选中的是一条 9 小时、只有 1 个章节的循环播放列表。
  final bool isMainFeature;

  MusicDiscTitle _withMain(bool main) => MusicDiscTitle(
    titlePath: titlePath,
    number: number,
    label: label,
    duration: duration,
    chapters: chapters,
    isMainFeature: main,
  );
}

/// 纯函数：标出默认勾选的 title（规则见 [MusicDiscTitle.isMainFeature]）。
List<MusicDiscTitle> markMusicDiscDefaultTitle(List<MusicDiscTitle> titles) {
  MusicDiscTitle? best;
  for (final MusicDiscTitle t in titles) {
    if (best == null) {
      best = t;
      continue;
    }
    final int a = t.chapters.length;
    final int b = best.chapters.length;
    if (a > b || (a == b && t.duration > best.duration)) best = t;
  }
  return <MusicDiscTitle>[
    for (final MusicDiscTitle t in titles) t._withMain(identical(t, best)),
  ];
}

/// 一张读入的盘。
class MusicDiscInfo {
  const MusicDiscInfo({
    required this.kind,
    required this.rootPath,
    required this.name,
    required this.discId,
    required this.titles,
    required this.identityFilePath,
    this.volumeLabel,
  });

  final MusicDiscKind kind;

  /// 盘根：含 `VIDEO_TS` / `BDMV` 的目录，或 `.iso`。
  final String rootPath;

  /// 盘名（BD 取盘内 META 标题，否则目录 / 镜像文件名）。
  final String name;

  /// 盘身份：DVD 是 libdvdread `DVDDiscID` 口径（IFO 的 MD5），BD 是 `index.bdmv` 与全部
  /// 播放列表字节的 SHA-1。挪目录 / 换盘符不变。
  final String discId;
  final String? volumeLabel;

  /// 可导入的 title，按号升序；主正片 [MusicDiscTitle.isMainFeature]。
  final List<MusicDiscTitle> titles;

  /// 判「盘变没变」的真实文件（DVD `VIDEO_TS.IFO` / 镜像本身，BD `index.bdmv`）：曲目行的
  /// `file_mtime_at` / `file_size` 取它。
  final String identityFilePath;
}

/// 纯函数：章节起点表 → 章节（起止）。过短章节并进前一章（第一章过短并进下一章）；
/// 重复 / 倒退的起点丢掉；越过 [duration] 的起点截掉。
List<MusicDiscChapter> musicDiscChaptersOf({
  required List<Duration> starts,
  required Duration duration,
  Duration minimum = kMusicDiscMinimumChapter,
}) {
  if (duration <= Duration.zero) return const <MusicDiscChapter>[];
  final List<({int number, Duration start})> marks =
      <({int number, Duration start})>[];
  for (int i = 0; i < starts.length; i++) {
    final Duration s = starts[i];
    if (s < Duration.zero || s >= duration) continue;
    if (marks.isNotEmpty && s <= marks.last.start) continue;
    marks.add((number: i + 1, start: s));
  }
  if (marks.isEmpty) {
    return <MusicDiscChapter>[
      MusicDiscChapter(number: 1, start: Duration.zero, end: duration),
    ];
  }
  final List<MusicDiscChapter> raw = <MusicDiscChapter>[
    for (int i = 0; i < marks.length; i++)
      MusicDiscChapter(
        number: marks[i].number,
        // 第一章从 title 开头算：首个章节点不在 0 时，前面那段并进第一章。
        start: i == 0 ? Duration.zero : marks[i].start,
        end: i + 1 < marks.length ? marks[i + 1].start : duration,
      ),
  ];
  final List<MusicDiscChapter> out = <MusicDiscChapter>[];
  MusicDiscChapter? carry; // 开头过短、要并进下一章的那段
  for (final MusicDiscChapter c in raw) {
    MusicDiscChapter cur = carry == null
        ? c
        : MusicDiscChapter(number: c.number, start: carry.start, end: c.end);
    carry = null;
    if (cur.duration >= minimum) {
      out.add(cur);
      continue;
    }
    if (out.isNotEmpty) {
      final MusicDiscChapter prev = out.removeLast();
      out.add(
        MusicDiscChapter(number: prev.number, start: prev.start, end: cur.end),
      );
    } else {
      carry = cur;
    }
  }
  if (carry != null) out.add(carry);
  return List<MusicDiscChapter>.unmodifiable(out);
}

/// 一个曲目在盘上的位置（导入时写进 `music_disc_sources.title_map_json`）。
class MusicDiscTrackRef {
  const MusicDiscTrackRef({
    required this.trackUid,
    required this.titleNumber,
    required this.chapterNumber,
  });

  final String trackUid;
  final int titleNumber;
  final int chapterNumber;

  Map<String, Object?> toJson() => <String, Object?>{
    'track': trackUid,
    'title': titleNumber,
    'chapter': chapterNumber,
  };

  static MusicDiscTrackRef? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? uid = json['track'];
    final Object? title = json['title'];
    final Object? chapter = json['chapter'];
    if (uid is! String || title is! int || chapter is! int) return null;
    return MusicDiscTrackRef(
      trackUid: uid,
      titleNumber: title,
      chapterNumber: chapter,
    );
  }
}

/// `title_map_json` 的读写（版本化，读不懂返回空表而不是抛：只是丢了「上次导入了哪些
/// 章节」的记录，重新导入即可恢复）。
String encodeMusicDiscTitleMap(List<MusicDiscTrackRef> refs) =>
    jsonEncode(<String, Object?>{
      'v': 1,
      'tracks': <Object?>[for (final MusicDiscTrackRef r in refs) r.toJson()],
    });

List<MusicDiscTrackRef> decodeMusicDiscTitleMap(String? json) {
  if (json == null || json.isEmpty) return const <MusicDiscTrackRef>[];
  try {
    final Object? root = jsonDecode(json);
    if (root is! Map<String, Object?> || root['v'] != 1) {
      return const <MusicDiscTrackRef>[];
    }
    final Object? list = root['tracks'];
    if (list is! List<Object?>) return const <MusicDiscTrackRef>[];
    return <MusicDiscTrackRef>[
      for (final Object? e in list) ?MusicDiscTrackRef.fromJson(e),
    ];
  } on FormatException {
    return const <MusicDiscTrackRef>[];
  }
}

String _hex128(List<int> digest) {
  final StringBuffer b = StringBuffer();
  for (int i = 0; i < 16; i++) {
    b.write(digest[i].toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}

/// 光盘专辑的 uid（内容派生，与 `music_albums.album_uid` 同形：32 位小写十六进制）。
/// 同一张盘挪了目录 / 换了盘符仍是同一张专辑。
String musicDiscAlbumUid(MusicDiscKind kind, String discId) => _hex128(
  sha1
      .convert(
        utf8.encode('fushi-music-disc-album-v1\u0000${kind.wire}\u0000$discId'),
      )
      .bytes,
);

/// 光盘来源行的 uid（`music_disc_sources.disc_uid`）。
String musicDiscUid(MusicDiscKind kind, String discId) => _hex128(
  sha1
      .convert(
        utf8.encode('fushi-music-disc-v1\u0000${kind.wire}\u0000$discId'),
      )
      .bytes,
);

/// 章节曲目的 uid：盘身份 + title 号 + 章节号。歌单 / 歌词 / 播放记录随盘身份走，
/// 不随盘所在路径变。
String musicDiscChapterTrackUid({
  required MusicDiscKind kind,
  required String discId,
  required int titleNumber,
  required int chapterNumber,
}) => _hex128(
  sha1
      .convert(
        utf8.encode(
          'fushi-music-disc-track-v1\u0000${kind.wire}\u0000$discId\u0000'
          '$titleNumber\u0000$chapterNumber',
        ),
      )
      .bytes,
);

/// [path] 是不是一张能当音乐专辑导入章节的盘根（DVD / BD 目录，或 DVD / BD 镜像）。
/// 只看形状与必要文件，不解析 IFO / MPLS。
Future<MusicDiscKind?> probeMusicDiscRoot(String path) async {
  final FileSystemEntityType type = FileSystemEntity.typeSync(path);
  if (type == FileSystemEntityType.file) {
    if (!isDiscImagePath(path)) return null;
    final DiscImageProbe? probe = await probeDiscImageFile(path);
    return switch (probe?.format) {
      DiscFormat.dvd => MusicDiscKind.dvd,
      DiscFormat.bluray || DiscFormat.uhdBluray => MusicDiscKind.bluray,
      _ => null,
    };
  }
  if (type != FileSystemEntityType.directory) return null;
  if (dvdDiscRootForDirectory(path) != null) return MusicDiscKind.dvd;
  if (await blurayDiscRootForDirectory(path) != null) {
    return MusicDiscKind.bluray;
  }
  return null;
}

/// 读入一张盘的 title 与章节。不是盘 / 读不出任何 title 返回 null；IFO 两份都坏照常抛
/// （`DvdIfoFormatException`，明确报错）。
///
/// BD 镜像暂不支持章节导入（MPLS 在镜像里，播放端要 m2ts 真实路径拼 EDL），返回 null。
Future<MusicDiscInfo?> readMusicDiscInfo(String path) async {
  final MusicDiscKind? kind = await probeMusicDiscRoot(path);
  switch (kind) {
    case MusicDiscKind.dvd:
      // 不按视频入库的最短时长筛 title：MV 合集的单曲 title 可能不足一分钟。
      final DvdDisc? disc = await readDvdDisc(path, keepWithoutTitles: true);
      return disc == null ? null : _fromDvd(disc);
    case MusicDiscKind.bluray:
      if (FileSystemEntity.typeSync(path) == FileSystemEntityType.file) {
        return null;
      }
      final String? root = await blurayDiscRootForDirectory(path);
      if (root == null) return null;
      final BlurayDisc? disc = await readBlurayDisc(root);
      return disc == null ? null : _fromBluray(disc);
    case MusicDiscKind.cdda:
    case null:
      return null;
  }
}

MusicDiscInfo _fromDvd(DvdDisc disc) {
  final List<MusicDiscTitle> titles = <MusicDiscTitle>[
    for (final DvdTitleCandidate c in disc.candidates)
      if (c.duration >= kMusicDiscMinimumChapter)
        MusicDiscTitle(
          titlePath: dvdTitlePath(disc.rootPath, c.entry.titleNumber),
          number: c.entry.titleNumber,
          label: c.entry.titleNumber.toString().padLeft(2, '0'),
          duration: c.duration,
          chapters: c.chapterStarts.isEmpty
              ? const <MusicDiscChapter>[]
              : musicDiscChaptersOf(
                  starts: c.chapterStarts,
                  duration: c.duration,
                ),
          isMainFeature: false,
        ),
  ]..sort((MusicDiscTitle a, MusicDiscTitle b) => a.number.compareTo(b.number));
  return MusicDiscInfo(
    kind: MusicDiscKind.dvd,
    rootPath: disc.rootPath,
    name: disc.name,
    discId: disc.discId,
    volumeLabel: disc.volumeLabel,
    titles: List<MusicDiscTitle>.unmodifiable(
      markMusicDiscDefaultTitle(titles),
    ),
    identityFilePath: isDiscImagePath(disc.rootPath)
        ? disc.rootPath
        : p.join(disc.rootPath, kDvdVideoDirectory, 'VIDEO_TS.IFO'),
  );
}

Future<MusicDiscInfo> _fromBluray(BlurayDisc disc) async {
  final List<BlurayTitle> all = <BlurayTitle>[...disc.titles, ...disc.extras]
    ..sort(
      (BlurayTitle a, BlurayTitle b) => a.playlist.id.compareTo(b.playlist.id),
    );
  final List<MusicDiscTitle> titles = <MusicDiscTitle>[
    for (final BlurayTitle t in all)
      MusicDiscTitle(
        titlePath: t.playlistPath,
        number: int.tryParse(t.playlist.id) ?? 0,
        label: t.playlist.id,
        duration: t.duration,
        chapters: musicDiscChaptersOf(
          starts: <Duration>[
            for (final BlurayChapter c in t.playlist.chapters) c.start,
          ],
          duration: t.duration,
        ),
        isMainFeature: false,
      ),
  ];
  return MusicDiscInfo(
    kind: MusicDiscKind.bluray,
    rootPath: disc.rootPath,
    name: disc.name,
    discId: await _blurayDiscId(disc),
    titles: List<MusicDiscTitle>.unmodifiable(
      markMusicDiscDefaultTitle(titles),
    ),
    identityFilePath: p.join(disc.rootPath, 'BDMV', 'index.bdmv'),
  );
}

/// BD 盘身份：`index.bdmv` + 全部播放列表的字节（按文件名序）取 SHA-1。只读几 KB 到
/// 几百 KB；同一张盘的拷贝逐字节相同，换路径不变。
Future<String> _blurayDiscId(BlurayDisc disc) async {
  final BytesBuilder b = BytesBuilder(copy: false);
  Future<void> add(String path) async {
    final File f = File(path);
    if (!f.existsSync()) return;
    b
      ..add(utf8.encode(p.basename(path)))
      ..addByte(0)
      ..add(await f.readAsBytes());
  }

  await add(p.join(disc.rootPath, 'BDMV', 'index.bdmv'));
  for (final BlurayPlaylist pl in disc.playlists) {
    await add(p.join(disc.rootPath, 'BDMV', 'PLAYLIST', pl.fileName));
  }
  return sha1.convert(b.takeBytes()).toString();
}
