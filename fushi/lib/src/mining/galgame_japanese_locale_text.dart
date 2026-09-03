import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/mining/galgame_japanese_locale.dart';

/// 转区判定证据 → 用户看得懂的名字（BUG-2047）。
///
/// 分层理由与 `gal_hook_failure_text.dart` 相同：[GalJapaneseLocaleEvidence] 是纯模型，
/// 会话事件里存它的稳定 key（[galJapaneseLocaleEvidenceToKey]）供诊断；UI 只在这里
/// 翻成人话。
String galJapaneseLocaleEvidenceLabel(GalJapaneseLocaleEvidence evidence) =>
    switch (evidence) {
      GalJapaneseLocaleEvidence.userLanguageJapanese =>
        t.game_japanese_locale_evidence_user_language_japanese,
      GalJapaneseLocaleEvidence.userLanguageOther =>
        t.game_japanese_locale_evidence_user_language_other,
      GalJapaneseLocaleEvidence.manifestUtf8CodePage =>
        t.game_japanese_locale_evidence_manifest_utf8_code_page,
      GalJapaneseLocaleEvidence.versionInfoJapanese =>
        t.game_japanese_locale_evidence_version_info_japanese,
      GalJapaneseLocaleEvidence.versionInfoChinese =>
        t.game_japanese_locale_evidence_version_info_chinese,
      GalJapaneseLocaleEvidence.exeShiftJisStrings =>
        t.game_japanese_locale_evidence_exe_shift_jis_strings,
      GalJapaneseLocaleEvidence.dirFileNameJapanese =>
        t.game_japanese_locale_evidence_dir_file_name_japanese,
      GalJapaneseLocaleEvidence.dirFileNameChinesePatch =>
        t.game_japanese_locale_evidence_dir_file_name_chinese_patch,
      GalJapaneseLocaleEvidence.dirTextShiftJis =>
        t.game_japanese_locale_evidence_dir_text_shift_jis,
      GalJapaneseLocaleEvidence.dirTextGbk =>
        t.game_japanese_locale_evidence_dir_text_gbk,
      GalJapaneseLocaleEvidence.dirTextSimplifiedHanzi =>
        t.game_japanese_locale_evidence_dir_text_simplified_hanzi,
    };

/// 证据清单文案：空清单 = 「证据不足」，否则用 ` · ` 串起各条名字（与会话卡其余
/// 分隔符一致，且与语言无关）。
String galJapaneseLocaleEvidenceListLabel(
  List<GalJapaneseLocaleEvidence> evidence,
) => evidence.isEmpty
    ? t.game_session_japanese_locale_evidence_insufficient
    : evidence.map(galJapaneseLocaleEvidenceLabel).join(' · ');
