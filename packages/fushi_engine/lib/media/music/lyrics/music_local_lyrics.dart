/// 本地歌词层：音频同目录 sidecar 的选取与文件内嵌歌词（BUG-5300）。
///
/// app 的 `MusicLyricsService`（本机播放）与互联 host（`EngineMusicLibraryHost.lyrics`，库里还没有
/// 歌词行时现读）共用这一份规则，两边认到的是同一个文件：
/// - sidecar：[pickLyricSidecars] 的同主名 / 语言标签规则；没有同名文件时认头部 `#MP3:` / `#AUDIO:`
///   指向这首音频的 UltraStar `.txt`；调用方可排除一些文件（本机字幕管线的旧产物）；
/// - 内嵌：读文件头（后台 isolate），多条里按 [pickBestEmbedded] 取最好的一条。
///
/// 只选文件、读原文，不解析时间轴（解析在调用方：app 走自己注入的解析器，host 把原文交给客户端）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_music/fushi_music.dart'
    show EmbeddedLyrics, FushiLyricsAsync, LyricsParseException;

import 'package:fushi_engine/media/music/lyrics/music_lyrics_sources.dart';

/// 列目录里的文件（测试注入）。
typedef MusicLocalLyricsDirLister = List<String> Function(String dir);

/// 读一个音频文件的全部内嵌歌词（测试注入）。
typedef MusicEmbeddedLyricsReader =
    Future<List<EmbeddedLyrics>> Function(String path, int? durationMs);

/// 目录里的文件（不递归、不跟链接；读不了为空）。
List<String> listMusicDirFiles(String dir) {
  try {
    return <String>[
      for (final FileSystemEntity e in Directory(
        dir,
      ).listSync(followLinks: false))
        if (e is File) e.path,
    ];
  } on FileSystemException {
    return const <String>[];
  }
}

class MusicLocalLyrics {
  MusicLocalLyrics({
    MusicLocalLyricsDirLister? listDir,
    MusicEmbeddedLyricsReader? readEmbedded,
  }) : _listDir = listDir ?? listMusicDirFiles,
       _readEmbedded =
           readEmbedded ??
           ((String p, int? d) => FushiLyricsAsync.embedded(p, durationMs: d));

  final MusicLocalLyricsDirLister _listDir;
  final MusicEmbeddedLyricsReader _readEmbedded;

  /// [audioPath] 旁的歌词 sidecar（主文件 + 各语言翻译）。[exclude] 判为 true 的文件不算（只对按
  /// 主名选中的那几份调用）。主文件为 null = 没有。
  Future<LyricSidecarSet> sidecars(
    String audioPath, {
    Future<bool> Function(String path)? exclude,
  }) async {
    final List<String> siblings = _listDir(File(audioPath).parent.path);
    LyricSidecarSet set = pickLyricSidecars(audioPath, siblings);
    if (exclude != null) {
      final Set<String> own = <String>{};
      for (final LyricSidecarFile f in <LyricSidecarFile>[
        if (set.primary != null) set.primary!,
        ...set.translations,
      ]) {
        if (await exclude(f.path)) own.add(f.path);
      }
      if (own.isNotEmpty) {
        set = pickLyricSidecars(audioPath, <String>[
          for (final String s in siblings)
            if (!own.contains(s)) s,
        ]);
      }
    }
    if (set.primary != null) return set;
    final LyricSidecarFile? ultraStar = await _ultraStarByHeader(
      audioPath,
      siblings,
    );
    return ultraStar == null
        ? set
        : LyricSidecarSet(primary: ultraStar, translations: set.translations);
  }

  /// 文件内嵌歌词里最好的一条（没有 / 读不了为 null）。
  Future<EmbeddedLyrics?> bestEmbedded(
    String audioPath, {
    int? durationMs,
  }) async {
    try {
      return pickBestEmbedded(await _readEmbedded(audioPath, durationMs));
    } on LyricsParseException {
      return null;
    }
  }

  /// 文件内嵌的全部歌词（选来源面板列候选用）。
  Future<List<EmbeddedLyrics>> allEmbedded(
    String audioPath, {
    int? durationMs,
  }) => _readEmbedded(audioPath, durationMs);

  /// UltraStar 歌曲包：主名不同、头部 `#MP3:` / `#AUDIO:` 指向这首音频的 `.txt`。
  Future<LyricSidecarFile?> _ultraStarByHeader(
    String audioPath,
    List<String> siblings,
  ) async {
    final String audioName = File(audioPath).uri.pathSegments.last;
    for (final String p in ultraStarCandidates(audioPath, siblings)) {
      final List<int> head;
      try {
        final RandomAccessFile f = await File(p).open();
        try {
          head = await f.read(kUltraStarHeadBytes);
        } finally {
          await f.close();
        }
      } on FileSystemException {
        continue;
      }
      final String? ref = ultraStarAudioReference(
        utf8.decode(head, allowMalformed: true),
      );
      if (ref != null && ref.toLowerCase() == audioName.toLowerCase()) {
        return LyricSidecarFile(path: p, ext: 'ultrastar');
      }
    }
    return null;
  }
}
