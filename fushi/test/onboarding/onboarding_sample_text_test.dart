import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/onboarding/onboarding_sample_text.dart';

void main() {
  group('onboardingSampleLanguage', () {
    test(
      'picks the first installed dictionary language that has a sentence',
      () {
        expect(
          onboardingSampleLanguage(
            dictionarySourceLanguages: <String?>['', null, 'xx', 'de', 'ja'],
            recommendedPackSelected: true,
          ),
          'de',
        );
      },
    );

    test('reduces BCP-47 region/script tags to the primary subtag', () {
      expect(onboardingPrimaryLanguageSubtag('zh-Hant'), 'zh');
      expect(onboardingPrimaryLanguageSubtag('PT-br'), 'pt');
      expect(onboardingPrimaryLanguageSubtag(' '), isNull);
      expect(onboardingPrimaryLanguageSubtag(null), isNull);
      expect(
        onboardingSampleLanguage(
          dictionarySourceLanguages: <String?>['zh-Hant'],
          recommendedPackSelected: false,
        ),
        'zh',
      );
    });

    test('falls back to Japanese with the recommended pack, else English', () {
      expect(
        onboardingSampleLanguage(
          dictionarySourceLanguages: const <String?>[],
          recommendedPackSelected: true,
        ),
        'ja',
      );
      expect(
        onboardingSampleLanguage(
          dictionarySourceLanguages: <String?>['xx'],
          recommendedPackSelected: false,
        ),
        'en',
      );
    });

    test(
      'every listed language has a non-empty sentence and the fallbacks exist',
      () {
        expect(
          kOnboardingSampleSentences.keys,
          containsAll(<String>['ja', 'en']),
        );
        for (final MapEntry<String, String> entry
            in kOnboardingSampleSentences.entries) {
          expect(entry.key, entry.key.toLowerCase(), reason: '键必须是小写主子标签');
          expect(entry.key.contains('-'), isFalse, reason: '键不得带地区/文字子标签');
          expect(entry.value.trim(), isNotEmpty);
        }
        expect(
          onboardingSampleSentence(
            dictionarySourceLanguages: <String?>['ko'],
            recommendedPackSelected: true,
          ),
          kOnboardingSampleSentences['ko'],
        );
      },
    );
  });
}
