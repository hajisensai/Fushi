/// 放送状态的读取侧归一。
///
/// `VideoMetadataWork.status` 保持各家 provider 的**原串**（TMDB `Returning Series`、
/// Jikan `Currently Airing`、AniList `RELEASING` …），wire / NFO / DB 列都按原串
/// 消费、不改写；这里只在读取侧把原串折成 [VideoAiringStatus]，供「只有放送中
/// 才提供订阅」这类判断使用。认不出的串一律 null，不猜。
library;

import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

enum VideoAiringStatus { airing, finished, upcoming, cancelled, hiatus }

/// 各家 provider 状态原串 → 归一值。键已经是 [_foldStatus] 之后的形态。
const Map<String, VideoAiringStatus> _airingStatusByRaw =
    <String, VideoAiringStatus>{
  // TMDB TV
  'returning series': VideoAiringStatus.airing,
  'ended': VideoAiringStatus.finished,
  'canceled': VideoAiringStatus.cancelled,
  'in production': VideoAiringStatus.upcoming,
  'planned': VideoAiringStatus.upcoming,
  'pilot': VideoAiringStatus.upcoming,
  // TMDB movie
  'released': VideoAiringStatus.finished,
  'post production': VideoAiringStatus.upcoming,
  'rumored': VideoAiringStatus.upcoming,
  // Jikan (MAL)
  'currently airing': VideoAiringStatus.airing,
  'finished airing': VideoAiringStatus.finished,
  'not yet aired': VideoAiringStatus.upcoming,
  // AniList
  'releasing': VideoAiringStatus.airing,
  'finished': VideoAiringStatus.finished,
  'not yet released': VideoAiringStatus.upcoming,
  'cancelled': VideoAiringStatus.cancelled,
  'hiatus': VideoAiringStatus.hiatus,
};

final RegExp _statusSeparators = RegExp(r'[\s_\-]+');

String _foldStatus(String raw) =>
    raw.trim().toLowerCase().replaceAll(_statusSeparators, ' ');

/// trim + 小写 + 连续空白 / 下划线 / 连字符折叠成单空格后查表；认不出 → null。
VideoAiringStatus? normalizeVideoAiringStatus(String? raw) {
  if (raw == null) return null;
  final String folded = _foldStatus(raw);
  if (folded.isEmpty) return null;
  return _airingStatusByRaw[folded];
}

extension VideoMetadataWorkAiringStatus on VideoMetadataWork {
  VideoAiringStatus? get airingStatus => normalizeVideoAiringStatus(status);
}
