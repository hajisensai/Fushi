/// Audiobookshelf 标签页的纯函数：卡片 / 单集的副标题、错误转人话。无 UI，单独可测。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/discovery/audiobookshelf_server_config.dart';
import 'package:fushi/src/media/discovery/sources/audiobookshelf_discovery_source.dart'
    show formatAudiobookshelfDuration;
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';
import 'package:fushi_engine/media/external_provider.dart';

/// 书库里 Audiobookshelf 标签页要显示的服务器：已启用**且**已登录的。没有就不出标签页
/// （空壳 tab 只会让人困惑）。
List<AudiobookshelfServerConfig> audiobookshelfTabServers(
  Iterable<AudiobookshelfServerConfig> servers,
) => <AudiobookshelfServerConfig>[
  for (final AudiobookshelfServerConfig server in servers)
    if (server.enabled && server.isSignedIn) server,
];

/// 封面卡的副标题：作者 · 时长（缺的项跳过）。
String audiobookshelfCardSubtitle(AudiobookshelfItem item) {
  final double? seconds = item.durationSeconds;
  return <String>[
    if (item.authorName case final String author) author,
    if (seconds != null && seconds > 0) formatAudiobookshelfDuration(seconds),
  ].join(' · ');
}

/// 单集行的副标题：发布日期（本地时区 `yyyy-MM-dd`）· 时长。
String audiobookshelfEpisodeSubtitle(AudiobookshelfEpisode episode) {
  final int? publishedAt = episode.publishedAtMs;
  final double seconds = episode.track.durationMs / 1000;
  return <String>[
    if (publishedAt != null)
      _isoDate(DateTime.fromMillisecondsSinceEpoch(publishedAt).toLocal()),
    if (seconds > 0) formatAudiobookshelfDuration(seconds),
  ].join(' · ');
}

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// 单集按发布时间从新到旧（没有发布时间的排最后，保持原序）。
List<AudiobookshelfEpisode> audiobookshelfEpisodesNewestFirst(
  Iterable<AudiobookshelfEpisode> episodes,
) {
  final List<AudiobookshelfEpisode> list = episodes.toList();
  final List<AudiobookshelfEpisode> dated = <AudiobookshelfEpisode>[
    for (final AudiobookshelfEpisode e in list)
      if (e.publishedAtMs != null) e,
  ]..sort((a, b) => b.publishedAtMs!.compareTo(a.publishedAtMs!));
  return <AudiobookshelfEpisode>[
    ...dated,
    for (final AudiobookshelfEpisode e in list)
      if (e.publishedAtMs == null) e,
  ];
}

/// 失败原因转成给用户看的一句话：登录失效直接说去设置里重新登录，其余带上原因。
String audiobookshelfDescribeError(Object error) {
  if (error is ExternalProviderFailure) {
    return switch (error.kind) {
      ExternalProviderFailureKind.unauthorized =>
        t.discovery_audiobookshelf_session_expired,
      ExternalProviderFailureKind.forbidden =>
        t.discovery_audiobookshelf_download_forbidden,
      _ => error.message,
    };
  }
  return '$error';
}
