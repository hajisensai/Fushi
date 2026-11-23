import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/analysis/music_audio_analysis_models.dart';
import 'package:fushi/src/utils/net/github_mirrors.dart';

/// 音频分析模型托管在本仓预发行（拍板 pr4211-model-hosting=b），不再访问第三方 Hugging Face 仓库。
void main() {
  tearDown(() => gitHubMirrorsEnabledReader = () => true);

  test('both models download from this repo\'s versioned prerelease', () {
    expect(
      kMusicAnalysisModelsReleaseTag,
      'music-analysis-models-$kMusicAnalysisModelsVersion',
    );
    for (final MusicAnalysisModelFile f in <MusicAnalysisModelFile>[
      kMusicBeatThisModel,
      kMusicHtdemucsModel,
    ]) {
      expect(
        f.url,
        'https://github.com/hajisensai/Fushi/releases/download/'
        '$kMusicAnalysisModelsReleaseTag/${f.fileName}',
      );
      expect(f.url, isNot(contains('huggingface')));
      expect(f.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
    }
  });

  test('candidates: GitHub direct first, then the GitHub mirrors', () {
    gitHubMirrorsEnabledReader = () => true;
    final List<String> c = musicAnalysisModelUrlCandidates(kMusicBeatThisModel);
    expect(c.first, kMusicBeatThisModel.url);
    expect(c.length, 1 + kGitHubMirrorPrefixes.length);
    for (final String prefix in kGitHubMirrorPrefixes) {
      expect(c, contains('$prefix${kMusicBeatThisModel.url}'));
    }
    expect(c.toSet().length, c.length);
  });

  test('candidates: only GitHub direct when the user turned mirrors off', () {
    gitHubMirrorsEnabledReader = () => false;
    expect(musicAnalysisModelUrlCandidates(kMusicHtdemucsModel), <String>[
      kMusicHtdemucsModel.url,
    ]);
  });
}
