import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_video_acquisition_preferences.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_models.dart';

void main() {
  group('AiDownloadQualityPref', () {
    test('parse / encode 往返覆盖三态', () {
      expect(AiDownloadQualityPref.parse(''), AiDownloadQualityPref.unset);
      expect(AiDownloadQualityPref.parse(null), AiDownloadQualityPref.unset);
      expect(AiDownloadQualityPref.parse('ask'), AiDownloadQualityPref.ask);
      for (final VideoAcquisitionQuality quality
          in VideoAcquisitionQuality.values) {
        final AiDownloadQualityPref pref = AiDownloadQualityPref.parse(
          quality.storageKey,
        );
        expect(pref, AiDownloadQualityFixed(quality));
        expect(pref.encode(), quality.storageKey);
        expect(AiDownloadQualityPref.parse(pref.encode()), pref);
      }
      expect(AiDownloadQualityPref.unset.encode(), '');
      expect(AiDownloadQualityPref.ask.encode(), kVideoAcquisitionPrefAsk);
    });

    test('大小写 / 空白宽容', () {
      expect(
        AiDownloadQualityPref.parse(' 1080P '),
        isA<AiDownloadQualityFixed>(),
      );
      expect(AiDownloadQualityPref.parse('ASK'), AiDownloadQualityPref.ask);
    });

    test('非法值 → Unset', () {
      for (final String raw in <String>['4k', '1080', 'auto', 'none', 'x']) {
        expect(
          AiDownloadQualityPref.parse(raw),
          AiDownloadQualityPref.unset,
          reason: raw,
        );
      }
    });
  });

  group('AiDownloadSubtitleLanguagePref', () {
    test('parse / encode 往返覆盖五态', () {
      expect(
        AiDownloadSubtitleLanguagePref.parse(''),
        AiDownloadSubtitleLanguagePref.unset,
      );
      expect(
        AiDownloadSubtitleLanguagePref.parse('ask'),
        AiDownloadSubtitleLanguagePref.ask,
      );
      expect(
        AiDownloadSubtitleLanguagePref.parse('original'),
        AiDownloadSubtitleLanguagePref.original,
      );
      expect(
        AiDownloadSubtitleLanguagePref.parse('none'),
        AiDownloadSubtitleLanguagePref.none,
      );
      for (final String code in kVideoAcquisitionSubtitleLanguageCodes) {
        final AiDownloadSubtitleLanguagePref pref =
            AiDownloadSubtitleLanguagePref.parse(code);
        expect(pref, AiDownloadSubtitleLanguageFixed(code));
        expect(pref.encode(), code);
      }
      for (final AiDownloadSubtitleLanguagePref pref
          in <AiDownloadSubtitleLanguagePref>[
            AiDownloadSubtitleLanguagePref.unset,
            AiDownloadSubtitleLanguagePref.ask,
            AiDownloadSubtitleLanguagePref.original,
            AiDownloadSubtitleLanguagePref.none,
            const AiDownloadSubtitleLanguageFixed('ko'),
          ]) {
        expect(AiDownloadSubtitleLanguagePref.parse(pref.encode()), pref);
      }
      expect(AiDownloadSubtitleLanguagePref.unset.encode(), '');
      expect(
        AiDownloadSubtitleLanguagePref.original.encode(),
        kVideoAcquisitionSubtitleOriginal,
      );
      expect(
        AiDownloadSubtitleLanguagePref.none.encode(),
        kVideoAcquisitionSubtitleNone,
      );
    });

    test('语言码先归一：jpn / ja-JP / zh_CN 都落到白名单码', () {
      expect(
        AiDownloadSubtitleLanguagePref.parse('jpn'),
        const AiDownloadSubtitleLanguageFixed('ja'),
      );
      expect(
        AiDownloadSubtitleLanguagePref.parse('ja-JP'),
        const AiDownloadSubtitleLanguageFixed('ja'),
      );
      expect(
        AiDownloadSubtitleLanguagePref.parse('zh_CN'),
        const AiDownloadSubtitleLanguageFixed('zh'),
      );
    });

    test('非法值 → Unset（白名单外语言也算非法）', () {
      for (final String raw in <String>['fr', 'de', '1080p', 'auto', 'x']) {
        expect(
          AiDownloadSubtitleLanguagePref.parse(raw),
          AiDownloadSubtitleLanguagePref.unset,
          reason: raw,
        );
      }
    });
  });
}
