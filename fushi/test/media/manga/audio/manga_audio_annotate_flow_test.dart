import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_annotate_flow.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:shared_preferences/shared_preferences.dart';

MangaScriptLine _line({
  String speaker = 'A',
  CastLineKind kind = CastLineKind.spoken,
  double? confidence,
  TtsCastSource source = TtsCastSource.llm,
}) => MangaScriptLine(
  page: 0,
  blocks: const <int>[0],
  speaker: speaker,
  kind: kind,
  confidence: confidence,
  source: source,
);

void main() {
  test('review queue: unknown or low-confidence AI lines only', () {
    expect(mangaLineNeedsReview(_line(speaker: kTtsUnknown)), isTrue);
    expect(mangaLineNeedsReview(_line(confidence: 0.3)), isTrue);
    expect(mangaLineNeedsReview(_line(confidence: 0.9)), isFalse);
    expect(mangaLineNeedsReview(_line()), isFalse);
    // 模型有意不读的行不进复核队列；用户改过的行也不再列。
    expect(
      mangaLineNeedsReview(
        _line(speaker: kTtsUnknown, kind: CastLineKind.skip),
      ),
      isFalse,
    );
    expect(
      mangaLineNeedsReview(
        _line(speaker: kTtsUnknown, source: TtsCastSource.user),
      ),
      isFalse,
    );
  });

  test('upload consent is device-local and versioned', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    expect(await hasMangaAudioUploadConsent(), isFalse);
    SharedPreferences.setMockInitialValues(<String, Object>{
      kMangaAudioUploadConsentKey: kMangaAudioUploadConsentVersion - 1,
    });
    expect(await hasMangaAudioUploadConsent(), isFalse);
    SharedPreferences.setMockInitialValues(<String, Object>{
      kMangaAudioUploadConsentKey: kMangaAudioUploadConsentVersion,
    });
    expect(await hasMangaAudioUploadConsent(), isTrue);
  });

  test('manga audio feature persists under its own key', () {
    expect(AiFeature.mangaAudio.storageKey, 'mangaAudio');
    expect(AiFeature.fromStorageKey('mangaAudio'), AiFeature.mangaAudio);
  });
}
