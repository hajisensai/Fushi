import 'package:flutter/material.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/utils.dart';

class VideoFavoriteSentencesPanel extends StatelessWidget {
  const VideoFavoriteSentencesPanel({
    required this.currentBookKey,
    required this.currentEpisode,
    required this.sentences,
    required this.onTapSentence,
    this.emptyLabel = 'No saved sentences in this episode',
    super.key,
  });

  /// 当前视频/系列的身份键（写入时为 [FavoriteSentence.bookKey] = `bookUid`）。面板必须
  /// 按它隔离——单视频各自 `sectionIndex == 0`，仅按集号过滤会把别的视频的收藏混进来
  /// （BUG-274）。
  final String currentBookKey;
  final int currentEpisode;
  final List<FavoriteSentence> sentences;
  final ValueChanged<FavoriteSentence> onTapSentence;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    // 默认按字幕时间（cue.startMs，视频收藏写入 [FavoriteSentence.normCharOffset]）升序，
    // 与播放进度一致；而非 [FavoriteSentenceRepository.getAll] 的「按添加时间倒序」。
    // 没有 cue 的句子 normCharOffset == null，按 0 处理，落在最前。
    final List<FavoriteSentence> currentEpisodeSentences = sentences
        .where(
          (FavoriteSentence sentence) =>
              sentence.source == kFavoriteSentenceSourceVideo &&
              sentence.bookKey == currentBookKey &&
              sentence.sectionIndex == currentEpisode,
        )
        .toList()
      ..sort(
        (FavoriteSentence a, FavoriteSentence b) =>
            (a.normCharOffset ?? 0).compareTo(b.normCharOffset ?? 0),
      );

    if (currentEpisodeSentences.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            emptyLabel,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );
    }

    // TODO-357：面板顶部加一行收藏数统计 header（「本集收藏 N 句」），让用户一眼看到
    // 本集已收藏多少句。仅在非空时显示——空状态已由上方 emptyLabel 说明，避免文案重复。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildCountHeader(context, currentEpisodeSentences.length),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: currentEpisodeSentences.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (BuildContext context, int index) {
              final FavoriteSentence sentence = currentEpisodeSentences[index];
              final int? startMs = sentence.normCharOffset;
              return HibikiListItem(
                density: HibikiListDensity.compact,
                leading: const Icon(Icons.star_rounded),
                title: Text(
                  sentence.text,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle:
                    startMs == null ? null : Text(_formatTimestamp(startMs)),
                titleMaxLines: 3,
                onTap: () => onTapSentence(sentence),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 收藏数统计 header：星标图标 + 「本集收藏 N 句」（i18n `video_favorite_sentences_count`，
  /// 带 `$count` 占位符）。用设计 token 的 spacing，文案走当前 locale 翻译。
  Widget _buildCountHeader(BuildContext context, int count) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap + tokens.spacing.gap / 2,
        tokens.spacing.page,
        tokens.spacing.gap,
      ),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.star_rounded,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          SizedBox(width: tokens.spacing.gap),
          Expanded(
            child: Text(
              t.video_favorite_sentences_count(count: count),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTimestamp(int ms) {
    final Duration duration = Duration(milliseconds: ms);
    final int minutes = duration.inMinutes;
    final int seconds = duration.inSeconds.remainder(60);
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
