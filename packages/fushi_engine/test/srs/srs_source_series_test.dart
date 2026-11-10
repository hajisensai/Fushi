// 出处「系列 → 集」两级（反馈 MCJLSBR5Wg）：制卡上下文的系列名进 SrsSourceRef，定位字段不变。
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_engine/srs/srs_miner.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

const String _sha =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

CardSourceLink _videoLink({String uid = 'video/RWBY 01'}) => CardSourceLink(
  kind: CardSourceKind.video,
  uid: uid,
  sourceId: CardSourceLink.newSourceId(),
  episodeIndex: 0,
  startMs: 1000,
  endMs: 2000,
  fingerprint: CardSourceLink.isContentAddressedVideoUid(uid) ? null : _sha,
);

void main() {
  group('SrsSourceRef.seriesTitle', () {
    test('工厂去两侧空白写进 seriesTitle；空白 / null 不写键', () {
      final SrsSourceRef ep = SrsSourceRef.media(
        kind: SrsSourceKind.video,
        mediaKey: _sha,
        startMs: 5,
        title: 'RWBY - S01E01',
        seriesTitle: '  RWBY ',
      );
      expect(ep.seriesTitle, 'RWBY');
      expect(ep.toJson()[SrsSourceRef.seriesKey], 'RWBY');
      expect(ep.title, 'RWBY - S01E01');
      expect(ep.data['mediaKey'], _sha);
      expect(ep.data['startMs'], 5);

      for (final String? blank in <String?>[null, '', '   ']) {
        final SrsSourceRef solo = SrsSourceRef.media(
          kind: SrsSourceKind.video,
          mediaKey: _sha,
          startMs: 0,
          seriesTitle: blank,
        );
        expect(solo.seriesTitle, isNull, reason: '$blank');
        expect(
          solo.toJson().containsKey(SrsSourceRef.seriesKey),
          isFalse,
          reason: '$blank',
        );
      }
    });

    test('JSON 往返保留系列名；旧出处没有这个键 = 没有系列', () {
      final SrsSourceRef ep = SrsSourceRef.onlineVideo(
        sourceId: 'pkg:1',
        animeUrl: '',
        episodeUrl: '/ep/2',
        startMs: 0,
        title: 'Episode 2',
        seriesTitle: 'Show',
      );
      expect(SrsSourceRef.fromJson(ep.toJson())!.seriesTitle, 'Show');
      expect(
        SrsSourceRef.fromJson(<String, Object?>{
          'kind': 'video',
          'mediaKey': _sha,
          'startMs': 0,
          'title': 'RWBY - S01E01',
        })!.seriesTitle,
        isNull,
      );
      expect(
        SrsSourceRef.fromJson(<String, Object?>{
          'kind': 'video',
          'mediaKey': _sha,
          'seriesTitle': 3,
        })!.seriesTitle,
        isNull,
        reason: '不是字符串 = 没有系列（与内核 source_series 同口径）',
      );
    });
  });

  group('srsSourceRefFromMiningContext', () {
    test('本地视频：系列名进出处，mediaKey / 时间区间 / 集标题照旧', () {
      final SrsSourceRef ref = srsSourceRefFromMiningContext(
        AnkiMiningContext(
          sentence: 's',
          documentTitle: 'RWBY - S01E01',
          seriesTitle: 'RWBY',
          clipStartMs: 1200,
          clipEndMs: 1800,
          sourceLink: _videoLink(),
        ),
      );
      expect(ref.kind, SrsSourceKind.video);
      expect(ref.data['mediaKey'], _sha);
      expect(ref.data['startMs'], 1200);
      expect(ref.data['endMs'], 1800);
      expect(ref.title, 'RWBY - S01E01');
      expect(ref.seriesTitle, 'RWBY');
    });

    test('在线视频（anime-source）：系列名同样进出处', () {
      final SrsSourceRef ref = srsSourceRefFromMiningContext(
        AnkiMiningContext(
          sentence: 's',
          documentTitle: 'Show - Episode 2',
          seriesTitle: 'Show',
          sourceLink: _videoLink(uid: 'anime-source:pkg:1:/ep/2'),
        ),
      );
      expect(ref.kind, SrsSourceKind.onlineVideo);
      expect(ref.data['episodeUrl'], '/ep/2');
      expect(ref.seriesTitle, 'Show');
    });

    test('单视频（没有系列名）：出处只有集这一级', () {
      final SrsSourceRef ref = srsSourceRefFromMiningContext(
        AnkiMiningContext(
          sentence: 's',
          documentTitle: 'Movie',
          sourceLink: _videoLink(),
        ),
      );
      expect(ref.seriesTitle, isNull);
      expect(ref.toJson().containsKey(SrsSourceRef.seriesKey), isFalse);
    });

    test('withMediaRefs / withSourceLink 带着系列名走（落卡路径不丢）', () {
      final AnkiMiningContext ctx = AnkiMiningContext(
        sentence: 's',
        seriesTitle: 'RWBY',
        sourceLink: _videoLink(),
      );
      expect(
        ctx.withMediaRefs(coverRef: null, sentenceAudioRef: null).seriesTitle,
        'RWBY',
      );
      expect(ctx.withSourceLink(null).seriesTitle, 'RWBY');
    });
  });
}
