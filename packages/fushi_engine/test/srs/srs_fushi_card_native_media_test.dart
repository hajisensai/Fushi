import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_fushi_card_native_media.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';

const String kProfile = '01928c3e-0000-7000-8000-000000000002';

/// BUG（用户 2026-10-21「我视频怎么没了」）：原生 Fushi 卡面只画 `<img>` 与 `[sound:]`，
/// 视频片段卡（默认视频制卡模式）的 `<video>` / 页内 `<audio>` 与动图 AVIF 被静默丢成
/// 「没有画面 / 一张静图」。判据钉在引擎 renderCard：画不全的卡留在整面 WebView。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('srsFushiCardMediaIsNative', () {
    test('plain still / animated raster <img> stays native', () async {
      for (final String name in <String>[
        'a.jpg',
        'b.webp',
        'c.gif',
        'd.avif',
      ]) {
        expect(
          srsFushiCardMediaIsNative(<String, String>{
            'Media': coverMediaRef(name),
            'SentenceAudio': '[sound:s.aac]',
            'TermAudio': '[sound:w.mp3]',
          }),
          isTrue,
          reason: name,
        );
      }
      expect(
        srsFushiCardMediaIsNative(<String, String>{
          'Media': '<div><img src="a.png"><br></div>',
        }),
        isTrue,
      );
      expect(srsFushiCardMediaIsNative(<String, String>{}), isTrue);
    });

    test('clip cards (mining output) stay native', () async {
      // 与制卡链路同一组生成函数（anki_note_composer.dart）：WebM 片段 + 内嵌单词 /
      // 句子音频，原生卡面用片段播放器与音频按钮画全。
      expect(
        srsFushiCardMediaIsNative(<String, String>{
          'Media': coverMediaRef('clip.webm'),
          'SentenceAudio': inlineVideoSentenceAudioHtml('clip.webm'),
          'TermAudio': inlineVideoWordAudioHtml('w.mp3'),
        }),
        isTrue,
      );
      // MP4 片段是 Picture 里的 [sound:clip.mp4]。
      expect(
        srsFushiCardMediaIsNative(<String, String>{
          'Media': coverMediaRef('clip.mp4'),
        }),
        isTrue,
      );
    });

    test(
      'svg, remote, replay buttons and mixed Picture content are not native',
      () async {
        for (final String picture in <String>[
          synchronizedVideoReplayHtml,
          '[sound:a.mp3]', // 非视频的 [sound:]：原生 Picture 没有对应画法
          '<audio src="a.mp3"></audio>',
          '<img src="a.svg">',
          '<img src="data:image/svg+xml;base64,AAAA">',
          '<img src="https://example.com/a.png">',
          '<img src="a.png"> caption',
          '<img alt="no source">',
        ]) {
          expect(
            srsFushiCardMediaIsNative(<String, String>{'Media': picture}),
            isFalse,
            reason: picture,
          );
        }
      },
    );
  });

  group('renderCard', () {
    int t = DateTime.utc(2026, 10, 21, 12).millisecondsSinceEpoch;

    Future<SrsRenderedCard> render(
      SrsDbStore s,
      Map<String, String> fieldsByKey,
    ) async {
      final String note = await s.createNote(
        noteTypeId: s.fushiCardNoteTypeId,
        fieldsById: <String, String>{
          srsFushiCardFieldId(kProfile, 'Expression'): 'あちら',
          srsFushiCardFieldId(kProfile, 'MainDefinition'):
              '<ol><li>there</li></ol>',
          for (final MapEntry<String, String> e in fieldsByKey.entries)
            srsFushiCardFieldId(kProfile, e.key): e.value,
        },
      );
      final SrsCardCacheRow card = (await s.cardsOfNote(note)).first;
      t += 1000;
      return (await s.renderCard(card.id))!;
    }

    test('clip and animated AVIF cards render natively', () async {
      final SrsDbStore s = await openTestStore(
        profileUid: kProfile,
        deviceId: 'a',
        now: () => t,
      );

      final SrsRenderedCard still = await render(s, <String, String>{
        'Media': coverMediaRef('still.jpg'),
        'SentenceAudio': '[sound:s.aac]',
      });
      expect(still.fushiCardDefinitions, isNotNull);

      final SrsRenderedCard clip = await render(s, <String, String>{
        'Media': coverMediaRef('clip.webm'),
        'SentenceAudio': inlineVideoSentenceAudioHtml('clip.webm'),
      });
      expect(clip.fushiCardDefinitions, isNotNull, reason: '片段卡走原生卡面');
      expect(
        clip.fields['Media'],
        contains('<video class="fushi-inline-video"'),
      );

      final SrsRenderedCard anim = await render(s, <String, String>{
        'Media': coverMediaRef('anim.avif'),
      });
      expect(anim.fushiCardDefinitions, isNotNull, reason: '动图 AVIF 由原生逐帧解码播放');
    });
  });
}
