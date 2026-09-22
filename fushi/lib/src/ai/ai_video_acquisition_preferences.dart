/// 「AI 下视频」两个偏好的类型化读法。
///
/// 偏好表里存的是裸字符串（`ai_video_download_quality` /
/// `ai_video_download_subtitle_language`，见 `preference_keys.dart`），三态语义
/// （未设置 / 每次询问 / 固定值）散在字符串比较里很容易漏掉一态——reducer 的决策表
/// 对「未设置」和「每次询问」的处理不同（前者问一次且默认勾「以后默认」，后者每次
/// 问且默认不勾）。这里把它收成 sealed class，消费端 `switch` 穷举。
///
/// 非法值（改过枚举、手工改库、旧版本残留）一律回落 [AiDownloadQualityPref.unset] /
/// [AiDownloadSubtitleLanguagePref.unset]：等价于「从没设置过」，下一次对话会重新问。
library;

import 'package:fushi/src/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_language_preference.dart';

/// 默认画质偏好。
sealed class AiDownloadQualityPref {
  const AiDownloadQualityPref();

  static const AiDownloadQualityPref unset = AiDownloadQualityUnset();
  static const AiDownloadQualityPref ask = AiDownloadQualityAsk();

  /// `''` → unset；`ask` → ask；合法档位 → fixed；其余 → unset。
  static AiDownloadQualityPref parse(String? raw) {
    final String value = raw?.trim().toLowerCase() ?? '';
    if (value.isEmpty) return unset;
    if (value == kVideoAcquisitionPrefAsk) return ask;
    final VideoAcquisitionQuality? quality =
        VideoAcquisitionQuality.fromStorageKey(value);
    return quality == null ? unset : AiDownloadQualityFixed(quality);
  }

  /// 写回偏好表的字符串；[parse] 的逆。
  String encode();
}

class AiDownloadQualityUnset extends AiDownloadQualityPref {
  const AiDownloadQualityUnset();

  @override
  String encode() => '';
}

class AiDownloadQualityAsk extends AiDownloadQualityPref {
  const AiDownloadQualityAsk();

  @override
  String encode() => kVideoAcquisitionPrefAsk;
}

class AiDownloadQualityFixed extends AiDownloadQualityPref {
  const AiDownloadQualityFixed(this.quality);

  final VideoAcquisitionQuality quality;

  @override
  String encode() => quality.storageKey;

  @override
  bool operator ==(Object other) =>
      other is AiDownloadQualityFixed && other.quality == quality;

  @override
  int get hashCode => quality.hashCode;
}

/// 字幕语言偏好。
sealed class AiDownloadSubtitleLanguagePref {
  const AiDownloadSubtitleLanguagePref();

  static const AiDownloadSubtitleLanguagePref unset =
      AiDownloadSubtitleLanguageUnset();
  static const AiDownloadSubtitleLanguagePref ask =
      AiDownloadSubtitleLanguageAsk();
  static const AiDownloadSubtitleLanguagePref original =
      AiDownloadSubtitleLanguageOriginal();
  static const AiDownloadSubtitleLanguagePref none =
      AiDownloadSubtitleLanguageNone();

  /// `''` → unset；`ask` / `original` / `none` → 对应单例；归一后落在
  /// [kVideoAcquisitionSubtitleLanguageCodes] 里的语言码 → fixed；其余 → unset。
  static AiDownloadSubtitleLanguagePref parse(String? raw) {
    final String value = raw?.trim().toLowerCase() ?? '';
    if (value.isEmpty) return unset;
    if (value == kVideoAcquisitionPrefAsk) return ask;
    if (value == kVideoAcquisitionSubtitleOriginal) return original;
    if (value == kVideoAcquisitionSubtitleNone) return none;
    final String? code = normalizeSubtitleLanguageCode(value);
    if (code != null && kVideoAcquisitionSubtitleLanguageCodes.contains(code)) {
      return AiDownloadSubtitleLanguageFixed(code);
    }
    return unset;
  }

  /// 写回偏好表的字符串；[parse] 的逆。
  String encode();
}

class AiDownloadSubtitleLanguageUnset extends AiDownloadSubtitleLanguagePref {
  const AiDownloadSubtitleLanguageUnset();

  @override
  String encode() => '';
}

class AiDownloadSubtitleLanguageAsk extends AiDownloadSubtitleLanguagePref {
  const AiDownloadSubtitleLanguageAsk();

  @override
  String encode() => kVideoAcquisitionPrefAsk;
}

class AiDownloadSubtitleLanguageOriginal
    extends AiDownloadSubtitleLanguagePref {
  const AiDownloadSubtitleLanguageOriginal();

  @override
  String encode() => kVideoAcquisitionSubtitleOriginal;
}

class AiDownloadSubtitleLanguageNone extends AiDownloadSubtitleLanguagePref {
  const AiDownloadSubtitleLanguageNone();

  @override
  String encode() => kVideoAcquisitionSubtitleNone;
}

class AiDownloadSubtitleLanguageFixed extends AiDownloadSubtitleLanguagePref {
  const AiDownloadSubtitleLanguageFixed(this.code);

  /// 已归一的语言码（`ja` / `zh` / `en` / `ko`）。
  final String code;

  @override
  String encode() => code;

  @override
  bool operator ==(Object other) =>
      other is AiDownloadSubtitleLanguageFixed && other.code == code;

  @override
  int get hashCode => code.hashCode;
}
