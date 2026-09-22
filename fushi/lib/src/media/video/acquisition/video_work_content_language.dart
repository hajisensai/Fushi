/// 「跟随作品语言」的解析：从作品资料推断它说什么语言，返回码 + **证据**。
///
/// 证据要进确认摘要（「字幕：日语（跟随作品语言 · 依据：制作国 JP）」），所以不是
/// 一个裸的 `String?`。判不出就是判不出（`VideoWorkContentLanguage.unknown`），对话层
/// 据此再问用户一次——**不硬编码日语**，与 `subtitle_language_preference.dart`
/// 「不猜、尤其不许硬编码日语」同一条铁律。
library;

import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_language_preference.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_models.dart';

/// 制作国 → 语言。只列能**唯一**推出语言的国家；多语国家（CA / CH / BE…）不列，
/// 列了就是猜。
const Map<String, String> _languageByCountry = <String, String>{
  'JP': 'ja',
  'CN': 'zh',
  'TW': 'zh',
  'HK': 'zh',
  'KR': 'ko',
  'US': 'en',
  'GB': 'en',
};

/// 平假名 + 片假名（U+3040–U+30FF），排掉片假名区里的中点 U+30FB「・」——
/// 中文 / 韩文本地化标题也借用它分隔外来语，单凭它判日语会误判。
final RegExp _kanaPattern = RegExp(r'[぀-ヺー-ヿ]');

/// 谚文音节（U+AC00–U+D7AF）+ 谚文字母（U+1100–U+11FF）。
final RegExp _hangulPattern = RegExp(r'[가-힯ᄀ-ᇿ]');

/// 优先级（全部经 `normalizeSubtitleLanguageCode` 归一）：
/// 1. `work.originalLanguage`（TMDB 主要来源）→ 证据 `originalLanguage`；
/// 2. `work.countries` 含且仅含一个可判定国家：JP→ja、CN/TW/HK→zh、KR→ko、US/GB→en
///    （多国冲突不判）→ 证据 `countries`；
/// 3. `reference.originalTitle ?? reference.title` 含假名 → ja、含谚文 → ko
///    （**仅汉字不判**：无假名的日文标题会误判成中文）→ 证据 `titleScript`；
/// 4. 全无 → [VideoWorkContentLanguage.unknown]。
VideoWorkContentLanguage resolveVideoWorkContentLanguage(
  VideoMetadataWork? work,
  VideoMediaReference reference,
) {
  final String? original = normalizeSubtitleLanguageCode(
    work?.originalLanguage,
  );
  if (original != null) {
    return VideoWorkContentLanguage(
      code: original,
      evidence: VideoWorkLanguageEvidence.originalLanguage,
    );
  }

  final Set<String> byCountry = <String>{
    for (final String country in work?.countries ?? const <String>[])
      if (_languageByCountry[country.trim().toUpperCase()] != null)
        _languageByCountry[country.trim().toUpperCase()]!,
  };
  if (byCountry.length == 1) {
    final String? code = normalizeSubtitleLanguageCode(byCountry.single);
    if (code != null) {
      return VideoWorkContentLanguage(
        code: code,
        evidence: VideoWorkLanguageEvidence.countries,
      );
    }
  }

  final String originalTitle = reference.originalTitle?.trim() ?? '';
  final String title = originalTitle.isNotEmpty
      ? originalTitle
      : reference.title;
  final String? byScript = _kanaPattern.hasMatch(title)
      ? 'ja'
      : _hangulPattern.hasMatch(title)
      ? 'ko'
      : null;
  final String? scriptCode = normalizeSubtitleLanguageCode(byScript);
  if (scriptCode != null) {
    return VideoWorkContentLanguage(
      code: scriptCode,
      evidence: VideoWorkLanguageEvidence.titleScript,
    );
  }

  return VideoWorkContentLanguage.unknown;
}
