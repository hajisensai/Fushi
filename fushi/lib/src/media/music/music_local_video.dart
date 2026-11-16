/// 曲库里的本地 MV（拍板台 jeNKF9u0WJ，维护者 2026-11-16 选 A + 加标签）。
///
/// 音乐来源目录里的视频容器（mkv / mp4 / webm …，扫描器 `native/fushi_music/src/tags.rs`
/// 的 `VIDEO_EXTENSIONS` + `mp4`）作为曲目进曲库：排队、随机、歌单、歌词、学习统计与歌曲
/// 一致，音乐引擎只放音轨（libmpv `vid=no`）。曲目行标「MV」。
///
/// 看画面不在音乐模块里另做一套视频渲染：直接复用视频播放页（ASS 特效字幕原样渲染、
/// 同名外挂字幕自动探测、暂停识别画面文字、查词制卡都现成）。视频播放页按视频库行播放，
/// 所以第一次观看时按 app 外打开视频同一入口（[upsertExternalVideoBook]，不复制文件、
/// 按路径去重）登记进视频库，并给新登记的行打上「MV」标签——视频库里按这个标签就能
/// 把 MV 筛出来。已在视频库里的同一个文件直接复用那一行，不动用户自己的标签。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/music_format_badge.dart';
import 'package:fushi/src/media/video/external_video_ingest.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/media_extensions.dart' show isVideoMediaPath;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:path/path.dart' as p;

/// 本地 MV 登记进视频库时打的标签名（共享标签池按名跨设备合并，所以不随界面语言变）。
const String kMusicVideoTagName = 'MV';

/// 这首曲目是不是 MV（视频容器），只看扩展名：本地与网络来源（SFTP / WebDAV / AList，
/// path 是 `https://…` / `sftp://…`）的 MV 都算，曲目行都标「MV」。纯函数，不碰文件系统。
bool isMusicVideoTrack(MusicTrackRow track) => isVideoMediaPath(track.path);

/// 这首曲目是不是**能在视频播放页里看的本地 MV**：视频容器且 path 是本机绝对路径。
///
/// 网络来源的 MV（path 带 URL scheme）在视频播放页里没有可打开的本地文件——视频库按
/// 本机路径登记、[openMusicTrackVideo] 先查 `File.exists`——所以只放音轨、不给观看入口，
/// 免得给出一个必然「视频文件不存在」的按钮。纯函数，不碰文件系统。
bool isMusicLocalVideoTrack(MusicTrackRow track) =>
    isMusicVideoTrack(track) && isMusicLocalFilePath(track.path);

final RegExp _urlSchemePrefix = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://');

/// [path] 是不是本机文件系统的绝对路径（不带 `scheme://` 前缀）。
bool isMusicLocalFilePath(String path) {
  final String trimmed = path.trim();
  if (trimmed.isEmpty || _urlSchemePrefix.hasMatch(trimmed)) return false;
  return p.isAbsolute(trimmed);
}

/// 本地曲目副标题里艺人之后的徽章段：MV 标在前，后接格式徽章（视频容器的编码扫描时
/// 读不出，格式徽章多为空）。各本地曲目列表共用，不各自拼。
List<String> musicLocalTrackBadges(MusicTrackRow track) {
  final String format = musicFormatBadge(
    codec: track.codec,
    isLossless: track.isLossless,
    sampleRate: track.sampleRate,
    bitDepth: track.bitDepth,
    bitrateKbps: track.bitrate,
  );
  return <String>[
    if (isMusicVideoTrack(track)) t.music_track_mv_badge,
    if (format.isNotEmpty) format,
  ];
}

/// 把本地 MV 文件登记进视频库（已在库则复用），返回视频库 bookUid。只有这次新建的行才
/// 打「MV」标签：已有的行是用户自己导入 / 整理过的，标签归用户管（删掉的标签不该在
/// 每次观看时被加回来）。落库失败抛出，由调用方提示。
Future<String> ensureMusicVideoInVideoLibrary(
  FushiDatabase db,
  String videoPath,
) async {
  final ExternalVideoUpsert upsert = await upsertExternalVideoBook(
    VideoBookRepository(db),
    videoPath,
  );
  if (upsert.created) {
    final int tagId = await db.getOrCreateTagByName(kMusicVideoTagName);
    await db.addTagToVideoBook(upsert.bookUid, tagId);
  }
  return upsert.bookUid;
}
