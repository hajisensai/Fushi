/// 在线音源插件曲目下载（docs/specs/2026-10-28-music-plugins.md §5「下载」）：把插件曲目落成
/// **本地曲目**进曲库，离线可播。
///
/// - 落点：`<documents>/music_downloads/<插件 id>/<专辑名> [<专辑键哈希>]/<碟-曲序> <标题> [<曲目哈希>].<扩展名>`
///   （[musicPluginDownloadTarget]）。一张专辑一个目录：目录封面 `cover.<jpg|png|webp>` 只属于这张
///   专辑，曲库扫描按目录封面认（native/fushi_music `COVER_STEMS`）。没有专辑的单曲自成一个目录。
///   文件名带曲目 id 哈希：同一作品里同名的曲目（ASMR 作品里 mp3 / wav 两套同名文件很常见）不撞。
/// - 传输：与在线视频源剧集下载同一个下载器（`AnimeEpisodeDownloader.download`：直链 `.part` +
///   Range 续传与流身份校验、HLS 分片），任务交给 app 级 [InterconnectDownloadManager]——进度 / 暂停 /
///   取消 / 失败重试都在下载中心，离页照跑。流地址每轮现取（短时效、带防盗链头），续传前由下载器
///   按 ETag / 长度确认还是同一份字节。
/// - 扩展名：下完按文件头嗅探（[sniffAudioExtension]），认不出才看 URL 后缀 / 插件给的 codec；
///   都认不出如实失败，不猜。
/// - 元数据：标题 / 艺人 / 专辑 / 专辑艺人 / 曲序 / 碟号 / 发行日期写进文件标签
///   （[musicPluginDownloadTags]，Rust `ffm_tags_write_fields`），之后按「仅此一次」导入曲库
///   （与音频 CD 抓轨同一条入库路径），曲库从标签读，不另造一份入库逻辑。
/// - 歌词：插件 `lyrics` 给的原文 / 译文写成同名 sidecar（[musicPluginLyricSidecars]：
///   `<主名>.<格式>`、`<主名>.<语言>.<格式>`），与用户自己放在音频旁的歌词同一条读取规则
///   （`pickLyricSidecars`）。下载后的曲目是本地曲目，不再回插件取词。
/// - 只给试听片段的曲目拒绝下载（[MusicPluginTrialOnly]，与播放 / 转写同一判据
///   [fetchFullMusicPluginStream]）；不可播放的曲目（`playable: false`）不发起。
/// - 音质：用户的在线插件默认音质（`AppModel.musicPluginQuality`），没有单独的下载音质。
///
/// 封面 / 歌词取不到不让下载失败（音频已经完整落地，缺的只是附属品），记进错误日志；标签写不进、
/// 导入失败则任务失败，下载中心重试时已下完的音频不重下。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fushi_engine/utils/misc/safe_file_name.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/music/plugin/music_plugins.dart';
import 'package:fushi/src/media/video/online/anime_episode_downloader.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi/src/sync/remote_video_client.dart'
    show RemoteDownloadCancelled;
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// `<documents>` 下的下载根目录名（登记在 `AppPaths.fushiOwnedDocumentsEntries`，随数据根迁移）。
const String kMusicDownloadsDirName = 'music_downloads';

/// 下载中的字节暂存在 `<主名>.download`（下载器在它旁边再派生 `.part` / HLS 断点文件），
/// 下完嗅探出格式后改名成 `<主名>.<扩展名>`。
const String kMusicPluginDownloadStagingSuffix = '.download';

/// 认作下载成品的音频扩展名（[sniffAudioExtension] 产出的全集 + URL 后缀回退认的那些）。
const Set<String> kMusicPluginDownloadAudioExtensions = <String>{
  'flac',
  'mp3',
  'aac',
  'm4a',
  'wav',
  'ogg',
  'opus',
  'aiff',
  'ape',
  'wv',
  'wma',
  'mka',
};

const List<String> _kCoverExtensions = <String>['jpg', 'png', 'webp'];

/// 一首插件曲目的下载任务键（下载中心 / 去重用）：`music-plugin:<播放身份>`，与视频 / 书任务键
/// 隔一个域前缀。
String musicPluginDownloadTaskId(String pluginId, String trackId) =>
    'music-plugin:${musicPluginTrackUid(pluginId, trackId)}';

/// 「下载全部」的批键。
String musicPluginDownloadBatchId(
  String pluginId, {
  String? albumId,
  String? playlistId,
}) => albumId != null
    ? 'music-plugin-album:${musicPluginAlbumUid(pluginId, albumId)}'
    : 'music-plugin-playlist:${_hash('$pluginId\u0000${playlistId ?? ''}', 15)}';

String _hash(String s, int bytes) {
  final List<int> d = sha1.convert(utf8.encode(s)).bytes;
  final StringBuffer b = StringBuffer();
  for (int i = 0; i < bytes; i++) {
    b.write(d[i].toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}

/// 不可信文本 → 一段安全的文件名：去非法字符、压空白、去首尾空白与结尾的点（Windows 不认）、
/// 按码点截到 [max]、避开保留设备名；空了给 `_`。
String musicDownloadPathSegment(String raw, {int max = 80}) {
  String s = safeWindowsFileName(raw).replaceAll(RegExp(r'\s+'), ' ').trim();
  final List<int> runes = s.runes.toList();
  if (runes.length > max) s = String.fromCharCodes(runes.take(max)).trim();
  s = s.replaceFirst(RegExp(r'[. ]+$'), '');
  if (s.isEmpty) return '_';
  if (isWindowsReservedFileName(s)) return '_$s';
  return s;
}

/// 一首曲目的下载落点。
final class MusicPluginDownloadTarget {
  const MusicPluginDownloadTarget({required this.dir, required this.stem});

  /// 专辑目录。
  final Directory dir;

  /// 文件主名（不含扩展名）。
  final String stem;

  /// 下载中的暂存文件（交给下载管理器的 `dest`）。
  File get staging =>
      File(p.join(dir.path, '$stem$kMusicPluginDownloadStagingSuffix'));

  /// 成品音频。
  File audio(String ext) => File(p.join(dir.path, '$stem.$ext'));

  /// 已经落地的成品音频（任一认得的扩展名）；没有返回 null。
  Future<File?> existingAudio() async {
    for (final String ext in kMusicPluginDownloadAudioExtensions) {
      final File f = audio(ext);
      if (await f.exists()) return f;
    }
    return null;
  }
}

/// 下载落点（纯函数）：`<root>/<插件 id>/<专辑名> [<专辑键哈希>]/<碟-曲序> <标题> [<曲目哈希>]`。
///
/// 专辑取 `track.albumId`，没有时取从专辑页下载时的 [album]；都没有的单曲自成一个目录（键是曲目
/// id）。碟号 > 1 时曲序前缀写成 `2-03`，没有曲序就不写前缀。
MusicPluginDownloadTarget musicPluginDownloadTarget(
  Directory root,
  String pluginId,
  MusicPluginTrack track, {
  MusicPluginAlbum? album,
}) {
  final String? albumId = track.albumId ?? album?.id;
  final String albumKey = albumId != null
      ? 'album\u0000$albumId'
      : 'track\u0000${track.id}';
  final String albumName = track.albumTitle ?? album?.title ?? track.title;
  final String dirName =
      '${musicDownloadPathSegment(albumName)} '
      '[${_hash('$pluginId\u0000$albumKey', 4)}]';
  final int? no = track.trackNo;
  final int? disc = track.discNo;
  final String number = no == null || no <= 0
      ? ''
      : '${disc != null && disc > 1 ? '$disc-' : ''}'
            '${no.toString().padLeft(2, '0')} ';
  final String stem =
      '$number${musicDownloadPathSegment(track.title)} '
      '[${_hash('$pluginId\u0000${track.id}', 4)}]';
  return MusicPluginDownloadTarget(
    dir: Directory(
      p.join(root.path, musicDownloadPathSegment(pluginId, max: 64), dirName),
    ),
    stem: stem,
  );
}

/// 写进下载成品的标签（纯函数）。空值不写。专辑艺人优先取专辑页的专辑艺人，没有时用曲目艺人，
/// 让同一张专辑的各首在曲库里归到一起。
Map<MusicTagField, String> musicPluginDownloadTags(
  MusicPluginTrack track, {
  MusicPluginAlbum? album,
}) {
  final String artist = track.artistText.trim();
  final String? albumTitle = track.albumTitle ?? album?.title;
  final String albumArtist = album != null && album.artists.isNotEmpty
      ? joinArtistNames(album.artists).trim()
      : artist;
  final String? date =
      album?.releaseDate ?? (album?.year == null ? null : '${album!.year}');
  return <MusicTagField, String>{
    MusicTagField.title: track.title,
    if (artist.isNotEmpty) MusicTagField.artist: artist,
    if (albumTitle != null && albumTitle.trim().isNotEmpty)
      MusicTagField.album: albumTitle.trim(),
    if (albumArtist.isNotEmpty) MusicTagField.albumArtist: albumArtist,
    if (track.trackNo case final int no when no > 0)
      MusicTagField.trackNo: '$no',
    if (track.discNo case final int disc when disc > 0)
      MusicTagField.discNo: '$disc',
    if (date != null && date.isNotEmpty) MusicTagField.date: date,
  };
}

/// 与 `pickLyricSidecars` 认的语言后缀同一形状。
final RegExp _kSidecarLang = RegExp(r'^[a-zA-Z]{2,3}([-_][a-zA-Z0-9]{2,8})*$');

/// 插件歌词 → 音频 [audio] 旁的 sidecar 文件（纯函数）：原文 `<主名>.<格式>`，译文
/// `<主名>.<语言>.<格式>`（没给语言 / 语言不合形状按 `zh-Hans`，与插件歌词合并译文的缺省一致）。
/// 罗马音 v1 不用（与在线播放时一致）。
List<({String path, String text})> musicPluginLyricSidecars(
  File audio,
  MusicPluginLyrics lyrics,
) {
  final MusicPluginLyricText? original = lyrics.original;
  if (original == null) return const <({String path, String text})>[];
  final String dir = audio.parent.path;
  final String stem = p.basenameWithoutExtension(audio.path);
  final MusicPluginLyricText? tr = lyrics.translation;
  final String? lang = tr?.language;
  return <({String path, String text})>[
    (path: p.join(dir, '$stem.${original.format}'), text: original.text),
    if (tr != null)
      (
        path: p.join(
          dir,
          '$stem.${lang != null && _kSidecarLang.hasMatch(lang) ? lang : 'zh-Hans'}'
          '.${tr.format}',
        ),
        text: tr.text,
      ),
  ];
}

bool _ascii(List<int> b, int at, String s) {
  if (b.length < at + s.length) return false;
  for (int i = 0; i < s.length; i++) {
    if (b[at + i] != s.codeUnitAt(i)) return false;
  }
  return true;
}

bool _contains(List<int> b, String s) {
  for (int i = 0; i + s.length <= b.length; i++) {
    if (_ascii(b, i, s)) return true;
  }
  return false;
}

/// 按文件头认音频容器（纯函数）；认不出返回 null。[head] 取文件前 4 KB 即可。
String? sniffAudioExtension(List<int> head) {
  if (_ascii(head, 0, 'fLaC')) return 'flac';
  if (_ascii(head, 0, 'ID3')) return 'mp3';
  if (_ascii(head, 0, 'RIFF') && _ascii(head, 8, 'WAVE')) return 'wav';
  if (_ascii(head, 0, 'OggS')) {
    return _contains(head, 'OpusHead') ? 'opus' : 'ogg';
  }
  if (_ascii(head, 4, 'ftyp')) return 'm4a';
  if (_ascii(head, 0, 'FORM') &&
      (_ascii(head, 8, 'AIFF') || _ascii(head, 8, 'AIFC'))) {
    return 'aiff';
  }
  if (_ascii(head, 0, 'MAC ')) return 'ape';
  if (_ascii(head, 0, 'wvpk')) return 'wv';
  if (head.length >= 4 &&
      head[0] == 0x30 &&
      head[1] == 0x26 &&
      head[2] == 0xB2 &&
      head[3] == 0x75) {
    return 'wma';
  }
  if (head.length >= 4 &&
      head[0] == 0x1A &&
      head[1] == 0x45 &&
      head[2] == 0xDF &&
      head[3] == 0xA3) {
    return 'mka';
  }
  // MPEG 音频帧同步：layer 位 00 是 ADTS（AAC），其余是 MP1/2/3。
  if (head.length >= 2 && head[0] == 0xFF && (head[1] & 0xE0) == 0xE0) {
    return (head[1] & 0x06) == 0 ? 'aac' : 'mp3';
  }
  return null;
}

/// 文件头认不出时的回退：流地址的后缀，再看插件给的 codec 名。
String? musicPluginDownloadExtensionHint(MusicPluginStream stream) {
  final String path = Uri.tryParse(stream.url)?.path ?? '';
  final String ext = p.extension(path).replaceFirst('.', '').toLowerCase();
  if (kMusicPluginDownloadAudioExtensions.contains(ext)) return ext;
  final String codec = (stream.codec ?? '').toLowerCase();
  return switch (codec) {
    'flac' => 'flac',
    'mp3' => 'mp3',
    'aac' || 'alac' => 'm4a',
    'opus' => 'opus',
    'vorbis' || 'ogg' => 'ogg',
    'wav' || 'pcm' => 'wav',
    _ => null,
  };
}

/// 图片头 → 封面扩展名；不是认得的图片返回 null。
String? sniffCoverExtension(List<int> head) {
  if (head.length >= 3 &&
      head[0] == 0xFF &&
      head[1] == 0xD8 &&
      head[2] == 0xFF) {
    return 'jpg';
  }
  if (head.length >= 8 && head[0] == 0x89 && _ascii(head, 1, 'PNG')) {
    return 'png';
  }
  if (_ascii(head, 0, 'RIFF') && _ascii(head, 8, 'WEBP')) return 'webp';
  return null;
}

/// 下载中心的任务标题：`标题 · 艺人`。
String musicPluginDownloadTitle(MusicPluginTrack track) => track.artists.isEmpty
    ? track.title
    : '${track.title} · ${track.artistText}';

/// 向插件取这首的完整流（缺省 [fetchFullMusicPluginStream]）。只给试听抛 [MusicPluginTrialOnly]。
typedef MusicPluginDownloadStreamFetcher =
    Future<MusicPluginStream> Function(String pluginId, String trackId);

/// 取插件歌词；插件没有 `lyrics` 能力时调用方不传。
typedef MusicPluginDownloadLyricsFetcher =
    Future<MusicPluginLyrics?> Function(String pluginId, String trackId);

/// 把流落到 [dest]（缺省 `AnimeEpisodeDownloader.download`）。[cancelSignal] 完成时抛
/// [RemoteDownloadCancelled]、断点留着。
typedef MusicPluginDownloadTransfer =
    Future<void> Function({
      required String url,
      required Map<String, String> headers,
      required File dest,
      void Function(double progress)? onProgress,
      void Function(int received, int? total)? onBytes,
      Future<void>? cancelSignal,
    });

/// 取一张图片的字节（封面）。
typedef MusicPluginDownloadBytesFetcher =
    Future<Uint8List> Function(String url);

/// 写标签（缺省 Rust `MusicTagFieldsIo`，后台 isolate）。
typedef MusicPluginDownloadTagWriter =
    Future<void> Function(String path, Map<MusicTagField, String> tags);

/// 把一个音频文件「仅此一次」导入曲库；返回扫描错误（null = 成功）。
typedef MusicPluginDownloadImporter = Future<String?> Function(String path);

/// 封面 / 歌词这类附属品取不到时的记录口（缺省进错误日志）。
typedef MusicPluginDownloadSoftError =
    void Function(String where, Object error, StackTrace stack);

/// 一次发起的结果。
enum MusicPluginDownloadStart {
  /// 已交给下载管理器。
  started,

  /// 同一首已在下载中。
  alreadyRunning,

  /// 成品已在本机（重新登记进曲库）。
  alreadyDownloaded,

  /// 只能试听片段，没有发起。
  trialOnly,

  /// 插件标了不可播放，没有发起。
  unplayable,
}

/// 「下载全部」的结果（整批跑完才返回）。
typedef MusicPluginDownloadBatchResult = ({
  int started,
  int alreadyDownloaded,
  int trialOnly,
  int unplayable,
  int failed,
});

/// 插件曲目下载的编排（无状态；任务状态全在 [InterconnectDownloadManager]）。
class MusicPluginDownloadService {
  MusicPluginDownloadService({
    required this.downloads,
    required this.root,
    required MusicPluginDownloadStreamFetcher stream,
    required MusicPluginDownloadImporter import,
    MusicPluginDownloadTransfer? transfer,
    MusicPluginDownloadBytesFetcher? fetchBytes,
    MusicPluginDownloadTagWriter? writeTags,
    MusicPluginDownloadSoftError? softError,
  }) : _stream = stream,
       _import = import,
       _transfer = transfer ?? AnimeEpisodeDownloader().download,
       _fetchBytes = fetchBytes ?? _httpBytes,
       _writeTags = writeTags ?? _rustWriteTags,
       _softError = softError ?? _logSoftError;

  /// 生产装配：插件管理器取流（用户默认在线音质）；成品入库由调用方经 [import] 注入
  /// （来源库「仅此一次」导入住在 UI / AppModel 那一侧的大 import 环里，本层不直接依赖，
  /// 见 test/build/import_cycle_guard_test.dart）。
  factory MusicPluginDownloadService.forApp({
    required InterconnectDownloadManager downloads,
    required MusicPluginManager Function() plugins,
    required MusicPluginQuality Function() quality,
    required MusicPluginDownloadImporter import,
  }) => MusicPluginDownloadService(
    downloads: downloads,
    root: () => AppPaths.documentsSubdirectory(kMusicDownloadsDirName),
    stream: (String pluginId, String trackId) => fetchFullMusicPluginStream(
      plugins().source(pluginId),
      trackId,
      quality: quality(),
    ),
    import: import,
  );

  final InterconnectDownloadManager downloads;

  /// 下载根（`<documents>/music_downloads`）。
  final Future<Directory> Function() root;

  final MusicPluginDownloadStreamFetcher _stream;
  final MusicPluginDownloadImporter _import;
  final MusicPluginDownloadTransfer _transfer;
  final MusicPluginDownloadBytesFetcher _fetchBytes;
  final MusicPluginDownloadTagWriter _writeTags;
  final MusicPluginDownloadSoftError _softError;

  static Future<Uint8List> _httpBytes(String url) async {
    final HttpClient client = createAppHttpClient();
    try {
      final HttpClientRequest req = await client.getUrl(Uri.parse(url));
      final HttpClientResponse res = await req.close().timeout(
        const Duration(seconds: 30),
      );
      if (res.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${res.statusCode}', uri: Uri.parse(url));
      }
      final BytesBuilder b = BytesBuilder(copy: false);
      await for (final List<int> chunk in res.timeout(
        const Duration(seconds: 30),
      )) {
        b.add(chunk);
      }
      return b.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> _rustWriteTags(
    String path,
    Map<MusicTagField, String> tags,
  ) => Isolate.run(() => MusicTagFieldsIo.instance.write(path, tags));

  static void _logSoftError(String where, Object error, StackTrace stack) =>
      ErrorLogService.instance.log(where, error, stack);

  /// 这首的落点。
  Future<MusicPluginDownloadTarget> targetFor(
    String pluginId,
    MusicPluginTrack track, {
    MusicPluginAlbum? album,
  }) async =>
      musicPluginDownloadTarget(await root(), pluginId, track, album: album);

  /// 下载一首（单曲「下载」）：先向插件取一次流——只能试听就不发起，返回
  /// [MusicPluginDownloadStart.trialOnly]——再交给下载管理器，**不等**下载结束。其它取流失败抛
  /// [MusicPluginStreamUnavailable]（消息给用户看）。
  Future<MusicPluginDownloadStart> download(
    String pluginId,
    MusicPluginTrack track, {
    MusicPluginAlbum? album,
    MusicPluginDownloadLyricsFetcher? lyrics,
  }) async {
    final ({MusicPluginDownloadStart outcome, Future<void>? done}) r =
        await _begin(pluginId, track, album: album, lyrics: lyrics);
    // 结果以任务状态为准（下载中心可见、可重试），这里不接异常。
    r.done?.ignore();
    return r.outcome;
  }

  /// 「下载全部」：整批串行（同一平台并发拉多首既慢又容易被限流），整批结束才返回。试听 /
  /// 不可播放的曲目跳过并计数；单首失败不挡后面的（原因在它的任务里，下载中心可重试）；用户在
  /// 下载中心暂停正在下的那首 = 停掉整批（[InterconnectDownloadManager.startBatch]）。
  Future<MusicPluginDownloadBatchResult> downloadAll(
    String pluginId,
    List<MusicPluginTrack> tracks, {
    required String batchId,
    required String batchTitle,
    MusicPluginAlbum? album,
    MusicPluginDownloadLyricsFetcher? lyrics,
  }) async {
    int started = 0;
    int already = 0;
    int trial = 0;
    int unplayable = 0;
    int failed = 0;
    await downloads.startBatch(
      id: batchId,
      title: batchTitle,
      starters: <Future<void> Function()>[
        for (final MusicPluginTrack track in tracks)
          () async {
            final ({MusicPluginDownloadStart outcome, Future<void>? done}) r;
            try {
              r = await _begin(pluginId, track, album: album, lyrics: lyrics);
            } on Object {
              failed++;
              rethrow;
            }
            switch (r.outcome) {
              case MusicPluginDownloadStart.trialOnly:
                trial++;
                return;
              case MusicPluginDownloadStart.unplayable:
                unplayable++;
                return;
              case MusicPluginDownloadStart.alreadyDownloaded:
                already++;
                return;
              case MusicPluginDownloadStart.started:
              case MusicPluginDownloadStart.alreadyRunning:
                started++;
            }
            try {
              await r.done;
            } on RemoteDownloadCancelled {
              rethrow;
            } on Object {
              failed++;
              rethrow;
            }
          },
      ],
    );
    return (
      started: started,
      alreadyDownloaded: already,
      trialOnly: trial,
      unplayable: unplayable,
      failed: failed,
    );
  }

  Future<({MusicPluginDownloadStart outcome, Future<void>? done})> _begin(
    String pluginId,
    MusicPluginTrack track, {
    MusicPluginAlbum? album,
    MusicPluginDownloadLyricsFetcher? lyrics,
  }) async {
    if (!track.playable) {
      return (outcome: MusicPluginDownloadStart.unplayable, done: null);
    }
    final String id = musicPluginDownloadTaskId(pluginId, track.id);
    if (downloads.isRunning(id)) {
      return (outcome: MusicPluginDownloadStart.alreadyRunning, done: null);
    }
    // 上次没下完（暂停 / 失败）：同一份传输原语接着下，不重新开任务。
    if (downloads.canRestart(id)) {
      return (
        outcome: MusicPluginDownloadStart.started,
        done: downloads.resume(id),
      );
    }
    final MusicPluginDownloadTarget target = await targetFor(
      pluginId,
      track,
      album: album,
    );
    final File? existing = await target.existingAudio();
    if (existing != null) {
      // 成品在、但可能已被用户从曲库移除：重新登记（同一路径同一 uid，已在库是空操作）。
      await _importOrThrow(existing.path);
      return (outcome: MusicPluginDownloadStart.alreadyDownloaded, done: null);
    }
    final MusicPluginStream first;
    try {
      first = await _stream(pluginId, track.id);
    } on MusicPluginTrialOnly {
      return (outcome: MusicPluginDownloadStart.trialOnly, done: null);
    }
    final _TrackDownload job = _TrackDownload(
      service: this,
      pluginId: pluginId,
      track: track,
      album: album,
      target: target,
      lyrics: lyrics,
      prefetched: first,
    );
    final Future<void> done = downloads.startMusicDownload(
      id: id,
      title: musicPluginDownloadTitle(track),
      dest: target.staging,
      run: job.run,
      onComplete: job.complete,
      discard: job.discard,
    );
    return (outcome: MusicPluginDownloadStart.started, done: done);
  }

  Future<void> _importOrThrow(String path) async {
    final String? error = await _import(path);
    if (error != null) throw MusicPluginDownloadImportFailed(error);
  }
}

/// 下载完了，但曲库导入（扫描）报错：消息原样给下载中心。
final class MusicPluginDownloadImportFailed implements Exception {
  const MusicPluginDownloadImportFailed(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 下完的字节认不出是什么音频（文件头 / URL 后缀 / codec 都没线索）。
final class MusicPluginDownloadUnknownFormat implements Exception {
  const MusicPluginDownloadUnknownFormat();

  @override
  String toString() => 'unrecognized audio format';
}

/// 一首曲目的传输原语与收尾（下载管理器握着它的闭包：暂停后继续 / 失败重试都走这里）。
class _TrackDownload {
  _TrackDownload({
    required this.service,
    required this.pluginId,
    required this.track,
    required this.album,
    required this.target,
    required this.lyrics,
    required MusicPluginStream prefetched,
  }) : _prefetched = prefetched;

  final MusicPluginDownloadService service;
  final String pluginId;
  final MusicPluginTrack track;
  final MusicPluginAlbum? album;
  final MusicPluginDownloadTarget target;
  final MusicPluginDownloadLyricsFetcher? lyrics;

  /// 发起时为判断试听取的那一份流：第一轮直接用，之后每轮现取（地址短时效）。
  MusicPluginStream? _prefetched;

  /// 本轮落地的成品（[run] 写、[complete] 读）。
  File? _audio;

  Future<void> run(
    File staging, {
    void Function(double progress)? onProgress,
    void Function(int received, int? total)? onBytes,
    Future<void>? cancelSignal,
  }) async {
    File? audio = await target.existingAudio();
    if (audio == null) {
      MusicPluginStream? stream = _prefetched;
      _prefetched = null;
      if (!await staging.exists()) {
        stream ??= await service._stream(pluginId, track.id);
        await service._transfer(
          url: stream.url,
          headers: stream.headers,
          dest: staging,
          onProgress: onProgress,
          onBytes: onBytes,
          cancelSignal: cancelSignal,
        );
      }
      final String? ext = await _formatOf(staging, stream);
      if (ext == null) throw const MusicPluginDownloadUnknownFormat();
      audio = await staging.rename(target.audio(ext).path);
    }
    _audio = audio;
    await _writeCover();
    await service._writeTags(
      audio.path,
      musicPluginDownloadTags(track, album: album),
    );
    await _writeLyrics(audio);
    onProgress?.call(1);
  }

  Future<String?> _formatOf(File file, MusicPluginStream? stream) async {
    final RandomAccessFile raf = await file.open();
    final Uint8List head;
    try {
      head = await raf.read(4096);
    } finally {
      await raf.close();
    }
    return sniffAudioExtension(head) ??
        (stream == null ? null : musicPluginDownloadExtensionHint(stream));
  }

  Future<void> _writeCover() async {
    final String? url = track.coverUrl ?? album?.coverUrl;
    if (url == null) return;
    for (final String ext in _kCoverExtensions) {
      if (await File(p.join(target.dir.path, 'cover.$ext')).exists()) return;
    }
    try {
      final Uint8List bytes = await service._fetchBytes(url);
      final String? ext = sniffCoverExtension(bytes);
      if (ext == null) {
        throw FormatException('cover is not jpg/png/webp: $url');
      }
      await File(p.join(target.dir.path, 'cover.$ext')).writeAsBytes(bytes);
    } on Object catch (e, s) {
      service._softError('MusicPluginDownload.cover', e, s);
    }
  }

  Future<void> _writeLyrics(File audio) async {
    final MusicPluginDownloadLyricsFetcher? fetch = lyrics;
    if (fetch == null) return;
    try {
      final MusicPluginLyrics? got = await fetch(pluginId, track.id);
      if (got == null) return;
      for (final ({String path, String text}) f in musicPluginLyricSidecars(
        audio,
        got,
      )) {
        await File(f.path).writeAsString(f.text, flush: true);
      }
    } on Object catch (e, s) {
      service._softError('MusicPluginDownload.lyrics', e, s);
    }
  }

  Future<void> complete(File staging) async {
    final File? audio = _audio ?? await target.existingAudio();
    if (audio == null) throw const MusicPluginDownloadUnknownFormat();
    await service._importOrThrow(audio.path);
  }

  /// 下载中心「删除并删文件」：暂存字节与断点、以及已落地但没导入成功的成品连同 sidecar。
  Future<bool> discard() async {
    bool deleted = await deleteAnimeEpisodeDownloadLeftovers(target.staging);
    final Set<String> paths = <String>{target.staging.path};
    // 主名带曲目哈希，`<主名>.*` 只可能是这一首的成品与它的歌词 sidecar。
    if (await target.existingAudio() != null && await target.dir.exists()) {
      final String prefix = '${target.stem}.';
      await for (final FileSystemEntity e in target.dir.list()) {
        if (e is File && p.basename(e.path).startsWith(prefix)) {
          paths.add(e.path);
        }
      }
    }
    for (final String path in paths) {
      final File f = File(path);
      try {
        if (await f.exists()) {
          await f.delete();
          deleted = true;
        }
      } on FileSystemException catch (e, s) {
        service._softError('MusicPluginDownload.discard', e, s);
      }
    }
    return deleted;
  }
}
