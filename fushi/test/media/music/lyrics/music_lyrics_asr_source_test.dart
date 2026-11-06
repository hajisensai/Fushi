import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/lrclib_client.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_sources.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart';

/// 音乐库「生成日语字幕」的来源 `asr`：解析优先级、选来源面板、切换与重置、与「我库里的
/// 例句」共用的选行判据。解析走真 Rust 库。
Future<LyricTimeline> _parse(Uint8List b, String hint, int? d) async =>
    FushiLyrics.parse(b, hint: hint, durationMs: d);

const String _srt =
    '1\n00:00:01,000 --> 00:00:03,000\nこんばんは、今夜もお便りを読みます\n\n'
    '2\n00:00:04,000 --> 00:00:06,000\nラジオネーム、夜更かしさん\n';

void main() {
  late FushiDatabase db;
  late Directory dir;
  late List<Uri> lrclibCalls;
  late int now;

  MusicLyricsService service() => MusicLyricsService(
    database: () => db,
    lrclib: LrclibClient(
      transport: (Uri uri) async {
        lrclibCalls.add(uri);
        return (status: 404, body: '');
      },
    ),
    onlineEnabled: () => true,
    readEmbedded: (String _, int? _) async => const <EmbeddedLyrics>[],
    parse: _parse,
    now: () => now,
  );

  String audio() => '${dir.path}${Platform.pathSeparator}01 第1話.flac';

  MusicLyricsTrackRef track() => MusicLyricsTrackRef(
    trackUid: 'uid-1',
    path: audio(),
    title: '第1話',
    durationMs: 600000,
  );

  Future<void> saveAsr(MusicLyricsService s) async {
    final Uint8List raw = utf8.encode(_srt);
    await s.saveGenerated(
      'uid-1',
      format: 'srt',
      raw: raw,
      timeline: await _parse(raw, 'srt', 600000),
    );
  }

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    dir = Directory.systemTemp.createTempSync('fushi_lyrics_asr_');
    File(audio()).writeAsBytesSync(<int>[0]);
    lrclibCalls = <Uri>[];
    now = 1000;
  });

  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  test('生成字幕入库后：没有文件自带歌词就用它，不再出网查 LRCLIB', () async {
    final MusicLyricsService s = service();
    await saveAsr(s);
    final MusicLyricsResolution? r = await s.resolve(track());
    expect(r?.source, MusicLyricsSource.asr);
    expect(r!.timeline.lines.first.text, 'こんばんは、今夜もお便りを読みます');
    expect(lrclibCalls, isEmpty);
    expect(
      r.timeline.lines.expand((LyricLine l) => l.syllables).map(
        (LyricSyllable y) => y.ruby,
      ),
      everyElement(isNull),
      reason: '生成字幕不带注音',
    );
  });

  test('优先级：sidecar 高于生成字幕', () async {
    final MusicLyricsService s = service();
    await saveAsr(s);
    File(
      '${dir.path}${Platform.pathSeparator}01 第1話.lrc',
    ).writeAsStringSync('[00:01.00]歌詞ファイル');
    final MusicLyricsResolution? r = await s.resolve(track());
    expect(r?.source, MusicLyricsSource.sidecar);
  });

  test('选来源面板列出生成字幕；手动选别的之后重置回到生成字幕', () async {
    final MusicLyricsService s = service();
    await saveAsr(s);
    File(
      '${dir.path}${Platform.pathSeparator}01 第1話.lrc',
    ).writeAsStringSync('[00:01.00]歌詞ファイル');
    final List<MusicLyricsCandidate> cands = await s.localCandidates(track());
    expect(
      cands.map((MusicLyricsCandidate c) => c.source),
      containsAll(<String>[MusicLyricsSource.sidecar, MusicLyricsSource.asr]),
    );
    final MusicLyricsCandidate asr = cands.firstWhere(
      (MusicLyricsCandidate c) => c.source == MusicLyricsSource.asr,
    );
    await s.choose('uid-1', asr);
    expect((await s.resolve(track()))?.source, MusicLyricsSource.user);
    // 删掉 sidecar、撤销手动指定：回到自动优先级里的生成字幕。
    File('${dir.path}${Platform.pathSeparator}01 第1話.lrc').deleteSync();
    await s.clearUserEdit('uid-1');
    expect((await s.resolve(track()))?.source, MusicLyricsSource.asr);
  });

  test('重生成覆盖原文、保留用户调过的整首偏移', () async {
    final MusicLyricsService s = service();
    await saveAsr(s);
    await s.setOffset('uid-1', MusicLyricsSource.asr, 300);
    now = 2000;
    final Uint8List raw = utf8.encode(
      '1\n00:00:01,000 --> 00:00:02,000\n重新生成した行\n\n'
      '2\n00:00:03,000 --> 00:00:04,000\n二行目\n',
    );
    await s.saveGenerated(
      'uid-1',
      format: 'srt',
      raw: raw,
      timeline: await _parse(raw, 'srt', null),
    );
    final MusicLyricsResolution? r = await s.resolve(track());
    expect(r!.timeline.lines.first.text, '重新生成した行');
    expect(r.timeline.offsetMs, 300);
  });

  group('preferredMusicLyricRow（歌词页与曲库搜索共用的选行判据）', () {
    MusicLyricRow row(
      String source, {
      int updatedAt = 1,
      bool user = false,
      String format = 'lrc',
    }) => MusicLyricRow(
      trackUid: 'u',
      source: source,
      format: format,
      raw: Uint8List(0),
      timelineVersion: 0,
      offsetMs: 0,
      timingQuality: 'line',
      isUserEdited: user,
      updatedAt: updatedAt,
    );

    test('sidecar 与 asr 并存：取 sidecar，哪怕 asr 更新', () {
      expect(
        preferredMusicLyricRow(<MusicLyricRow>[
          row(MusicLyricsSource.asr, updatedAt: 9),
          row(MusicLyricsSource.sidecar, updatedAt: 1),
        ])?.source,
        MusicLyricsSource.sidecar,
      );
    });

    test('asr 高于 LRCLIB 与插件；用户指定最高；负缓存不算', () {
      expect(
        preferredMusicLyricRow(<MusicLyricRow>[
          row(MusicLyricsSource.lrclib, updatedAt: 9),
          row(MusicLyricsSource.lyricsPlugin('x'), updatedAt: 9),
          row(MusicLyricsSource.asr),
        ])?.source,
        MusicLyricsSource.asr,
      );
      expect(
        preferredMusicLyricRow(<MusicLyricRow>[
          row(MusicLyricsSource.asr),
          row(MusicLyricsSource.user, user: true),
        ])?.source,
        MusicLyricsSource.user,
      );
      expect(
        preferredMusicLyricRow(<MusicLyricRow>[
          row(MusicLyricsSource.lrclib, format: kMusicLyricsNoneFormat),
        ]),
        isNull,
      );
    });
  });
}
