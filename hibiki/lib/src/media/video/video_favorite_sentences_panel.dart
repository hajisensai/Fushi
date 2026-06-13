import 'package:flutter/material.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

class VideoFavoriteSentencesPanel extends StatelessWidget {
  const VideoFavoriteSentencesPanel({
    required this.currentEpisode,
    required this.sentences,
    required this.onTapSentence,
    this.emptyLabel = 'No saved sentences in this episode',
    super.key,
  });

  final int currentEpisode;
  final List<FavoriteSentence> sentences;
  final ValueChanged<FavoriteSentence> onTapSentence;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    final List<FavoriteSentence> currentEpisodeSentences = sentences
        .where(
          (FavoriteSentence sentence) =>
              sentence.source == kFavoriteSentenceSourceVideo &&
              sentence.sectionIndex == currentEpisode,
        )
        .toList(growable: false);

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

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: currentEpisodeSentences.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (BuildContext context, int index) {
        final FavoriteSentence sentence = currentEpisodeSentences[index];
        final int? startMs = sentence.normCharOffset;
        return ListTile(
          dense: true,
          leading: const Icon(Icons.star_rounded),
          title: Text(
            sentence.text,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: startMs == null ? null : Text(_formatTimestamp(startMs)),
          onTap: () => onTapSentence(sentence),
        );
      },
    );
  }

  String _formatTimestamp(int ms) {
    final Duration duration = Duration(milliseconds: ms);
    final int minutes = duration.inMinutes;
    final int seconds = duration.inSeconds.remainder(60);
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
