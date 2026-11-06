import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fushi/src/media/audiobook/mining_audio_clip.dart'
    show padSentenceRange;
import 'package:fushi/src/media/video/video_subtitle_jump_panel.dart'
    show subtitleTranscriptRowSpans;
import 'package:fushi/src/sync/video_remote_host.dart';
import 'package:fushi_anki/fushi_anki.dart' show MiningRequestOverrides;
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/dictionary/dictionary_media_types.dart'
    show safeDictionaryMediaPath;
import 'package:fushi_engine/media/video/video_subtitle_source.dart'
    show SubtitleFormat, parseSubtitleContentAsync, subtitleFormatForPath;
import 'package:fushi_engine/sync/video_remote_service.dart';

/// 手机遥控的句子列表：把主 / 副两条字幕流按字幕面板的代表行规则摊平、按播放器轴排序。
/// 原生播放器页、内置网页播放器页、app 内浏览器三处遥控绑定共用；只有轨或调轴变了才重建，
/// 播放头每一拍读缓存。
class VideoRemoteCueCache {
  List<AudioCue>? _primary;
  List<AudioCue>? _secondary;
  String? _key;
  int _primaryLength = -1;
  int _secondaryLength = -1;
  List<VideoRemoteCue> _rows = <VideoRemoteCue>[];

  /// [key] 收进与 cue 列表身份无关、但会改变行的输入（选中的轨、调轴）。
  List<VideoRemoteCue> read({
    required List<AudioCue> primary,
    List<AudioCue> secondary = const <AudioCue>[],
    int primaryDelayMs = 0,
    int secondaryDelayMs = 0,
    String key = '',
  }) {
    final String fullKey = '$key|$primaryDelayMs|$secondaryDelayMs';
    if (identical(_primary, primary) &&
        identical(_secondary, secondary) &&
        _primaryLength == primary.length &&
        _secondaryLength == secondary.length &&
        _key == fullKey) {
      return _rows;
    }
    _primary = primary;
    _secondary = secondary;
    _primaryLength = primary.length;
    _secondaryLength = secondary.length;
    _key = fullKey;
    _rows =
        <VideoRemoteCue>[
          ...videoRemoteTrackRows(primary, 'primary', primaryDelayMs),
          ...videoRemoteTrackRows(secondary, 'secondary', secondaryDelayMs),
        ]..sort((VideoRemoteCue a, VideoRemoteCue b) {
          final int time = (a.startMs + a.delayMs).compareTo(
            b.startMs + b.delayMs,
          );
          return time != 0 ? time : a.id.compareTo(b.id);
        });
    return _rows;
  }
}

/// 一条字幕流的遥控行（id = `<track>:<代表行原始下标>`）。
List<VideoRemoteCue> videoRemoteTrackRows(
  List<AudioCue> cues,
  String track,
  int delayMs,
) => <VideoRemoteCue>[
  for (final ({int rawIndex, String text, int startMs, int endMs}) row
      in subtitleTranscriptRowSpans(cues))
    VideoRemoteCue(
      id: '$track:${row.rawIndex}',
      text: row.text,
      startMs: row.startMs,
      endMs: row.endMs,
      delayMs: delayMs,
      track: track,
    ),
];

/// 遥控制卡 / 试听的字幕时基区间：`[startMs, endMs]`（[anchor] 所在那条字幕流 [cues]）
/// 按制卡音频首尾留白加宽。调用方再按 [anchor] 的调轴换到播放器轴（`miningClipTimeMs`）。
/// 试听与写卡只算这一处（BUG-2196 ②），三处遥控绑定共用。
({int startMs, int endMs}) videoRemotePaddedMiningRange({
  required int startMs,
  required int endMs,
  required List<AudioCue> cues,
  required int headPadMs,
  required int tailPadMs,
}) {
  final AudioPlaybackRange padded = padSentenceRange(
    AudioPlaybackRange(audioFileIndex: 0, startMs: startMs, endMs: endMs),
    cues: cues,
    headPadMs: headPadMs,
    tailPadMs: tailPadMs,
  );
  return (startMs: padded.startMs, endMs: padded.endMs);
}

/// 手机制卡请求（`mine` 的 `fields`）解析后的三样：Anki 原始字段、手机带来的句子、
/// 「高级制卡」覆盖项。形状不对抛 400 `invalid_fields`。
///
/// `fields['dictionaryMedia']`（手机送来的词典媒体清单）在这里统一清洗
/// （[sanitizeVideoRemoteDictionaryMediaJson]）：三处遥控绑定都经这一个入口，越级路径
/// 不会因为某条路径漏调而走到写缓存那一步。同步函数：调用方在首个 await 之前读完。
typedef VideoRemoteMineRequest = ({
  Map<String, String> fields,
  String? sentence,
  MiningRequestOverrides? overrides,
});

VideoRemoteMineRequest parseVideoRemoteMineRequest(
  Map<String, dynamic> request,
) {
  final Object? rawFields = request['rawFields'];
  if (rawFields is! Map) {
    throw const VideoRemoteException(400, 'invalid_fields');
  }
  final Map<String, String> fields = <String, String>{
    for (final MapEntry<dynamic, dynamic> entry in rawFields.entries)
      entry.key.toString(): entry.value.toString(),
  };
  final String? dictionaryMedia = fields['dictionaryMedia'];
  if (dictionaryMedia != null) {
    fields['dictionaryMedia'] = sanitizeVideoRemoteDictionaryMediaJson(
      dictionaryMedia,
    );
  }
  if ((fields['expression'] ?? '').trim().isEmpty) {
    throw const VideoRemoteException(400, 'invalid_fields');
  }
  final Object? sentence = request['sentence'];
  if (sentence != null && sentence is! String) {
    throw const VideoRemoteException(400, 'invalid_fields');
  }
  return (
    fields: fields,
    sentence: sentence as String?,
    overrides: MiningRequestOverrides.readFrom(fields),
  );
}

/// 卡片句子：手机调过上下文（加句 / 改字）时以合成文本为准，否则沿用手机带来的句子。
String videoRemoteMineSentence(
  VideoRemoteMineSelection selection,
  String? requestSentence,
) => selection.adjusted
    ? selection.sentence
    : requestSentence ?? selection.sentence;

/// 手机送来的词典媒体清单（`[{dictionary, path, filename}]`）只留路径落在词典资源根内的
/// 条目：缓存文件名取自路径扩展名，越级路径不许进写盘那一步。
///
/// `filename` 是 popup.js 写进义项 HTML 的占位符（`fushi_dict_<序号>.<ext>`），落卡时
/// 按它把 `<img src>` / `<a href>` 换成真实媒体名，必须原样保留；丢了它映射键就成了
/// 空串，`replaceAll('', ref)` 会把媒体名插进字段的每个字符之间。只收 popup.js 的占位符
/// 形态（前缀 + 不含引号 / 尖括号），不合格的只丢 `filename`（该条退回 alt 文本）。
String sanitizeVideoRemoteDictionaryMediaJson(String raw) {
  if (raw.isEmpty || raw == '[]') return raw;
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return '[]';
  }
  if (decoded is! List) return '[]';
  return jsonEncode(<Map<String, String>>[
    for (final Object? item in decoded)
      if (item is Map &&
          item['dictionary'] is String &&
          item['path'] is String &&
          safeDictionaryMediaPath(item['path'] as String) != null)
        <String, String>{
          'dictionary': item['dictionary'] as String,
          'path': safeDictionaryMediaPath(item['path'] as String)!,
          if (_isPopupMediaPlaceholder(item['filename']))
            'filename': item['filename'] as String,
        },
  ]);
}

bool _isPopupMediaPlaceholder(Object? filename) =>
    filename is String &&
    filename.startsWith('fushi_dict_') &&
    !filename.contains(RegExp(r'''["'<>\s]'''));

/// 收藏句在当前句子列表里的那一行：先按起点 + 文本，起点对得上但文本改过时退回只按起点。
/// 多行同时匹配回 409 `favorite_subtitle_ambiguous`，找不到回 404 `favorite_subtitle_missing`。
VideoRemoteCue matchVideoRemoteFavoriteCue(
  List<VideoRemoteCue> rows,
  FavoriteSentence favorite,
) {
  final List<VideoRemoteCue> candidates = rows
      .where(
        (VideoRemoteCue item) =>
            (favorite.normCharOffset == null ||
                item.startMs == favorite.normCharOffset) &&
            item.text.trim() == favorite.text.trim(),
      )
      .toList();
  if (candidates.isEmpty && favorite.normCharOffset != null) {
    candidates.addAll(
      rows.where(
        (VideoRemoteCue item) => item.startMs == favorite.normCharOffset,
      ),
    );
  }
  if (candidates.length > 1) {
    throw const VideoRemoteException(409, 'favorite_subtitle_ambiguous');
  }
  if (candidates.isEmpty) {
    throw const VideoRemoteException(404, 'favorite_subtitle_missing');
  }
  return candidates.single;
}

/// 手机在线搜下来的字幕档 → cue（网页播放器没有本地媒体，下载档按「站点视频的一条轨」
/// 挂上去）。格式不认识 / 解析失败回空表，调用方回 `subtitle_track_unavailable`。
Future<List<AudioCue>> loadVideoRemoteSubtitleFile(
  String path,
  String bookUid,
) async {
  final SubtitleFormat? format = subtitleFormatForPath(path);
  if (format == null) return const <AudioCue>[];
  try {
    final String text = await readTextWithEncoding(File(path));
    return await parseSubtitleContentAsync(
      format,
      content: text,
      bookUid: bookUid,
    );
  } on Object {
    return const <AudioCue>[];
  }
}

/// 字幕轨在遥控协议里的不透明 id：source 的摘要（source 可能是本机路径）。
String videoRemoteSubtitleOptionId(String source) =>
    sha256.convert(utf8.encode(source)).toString().substring(0, 16);
