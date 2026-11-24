import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/lrclib_client.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_auto_sync.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/lyrics/music_lyrics_sources.dart';
import 'package:fushi_music/fushi_music.dart';

/// 拍板台 niQk_Ns4OV：纯文本歌词按本机转录自动对时 → 本地 LRC → 工作台逐行微调。
/// 解析走真 Rust 库，对齐走上游 `alignLyricsToTranscript`（后台 isolate）。
Future<LyricTimeline> _parse(Uint8List b, String hint, int? d) async =>
    FushiLyrics.parse(b, hint: hint, durationMs: d);

const String _plain =
    '[Verse 1]\nきみのなまえをよんだ\nとおいそらのしたで\n\n[Chorus]\nまたあえるひまで\n';

const String _transcriptSrt =
    '1\n00:00:12,000 --> 00:00:15,000\nきみのなまえをよんだー\n\n'
    '2\n00:00:16,000 --> 00:00:19,000\nとおいそらのしたで\n\n'
    '3\n00:00:21,000 --> 00:00:24,000\nまたあえるひまでええ\n';

const String _unrelatedSrt =
    '1\n00:00:01,000 --> 00:00:04,000\nぜんぜんちがううたです\n\n'
    '2\n00:00:05,000 --> 00:00:08,000\nなにもかさならない\n';

void main() {
  group('pure helpers', () {
    test('buildMusicLrc: headers, strictly increasing stamps, end marker', () {
      final String lrc = buildMusicLrc(
        <MusicLrcLine>[
          (startMs: 12000, text: 'a'),
          (startMs: 12004, text: 'b'), // 同一个百分秒：往后挪一格
          (startMs: 61234, text: 'c\nd'),
        ],
        endMs: 65000,
        title: 'T [x]',
        artist: '',
      );
      expect(lrc.split('\n'), <String>[
        '[ti:T x]',
        '[00:12.00]a',
        '[00:12.01]b',
        '[01:01.23]c d',
        '[01:05.00]',
        '',
      ]);
    });

    test('musicLyricsCanAutoSync only for unsynced text', () async {
      expect(musicLyricsCanAutoSync(null), isFalse);
      expect(
        musicLyricsCanAutoSync(await _parse(utf8.encode(_plain), 'txt', null)),
        isTrue,
      );
      expect(
        musicLyricsCanAutoSync(
          await _parse(utf8.encode(_transcriptSrt), 'srt', null),
        ),
        isFalse,
      );
    });

    test('musicLrcWithLineStart clamps between neighbours', () async {
      final LyricTimeline t = await _parse(
        utf8.encode('[00:10.00]a\n[00:20.00]b\n[00:30.00]c\n[00:35.00]\n'),
        'lrc',
        null,
      );
      Future<List<int>> starts(Uint8List? lrc) async => <int>[
        for (final LyricLine l in (await _parse(lrc!, 'lrc', null)).lines)
          l.startMs,
      ];
      expect(await starts(musicLrcWithLineStart(t, 1, 18000)), <int>[
        10000,
        18000,
        30000,
      ]);
      expect(await starts(musicLrcWithLineStart(t, 1, 5000)), <int>[
        10000,
        10010,
        30000,
      ]);
      expect(await starts(musicLrcWithLineStart(t, 1, 99000)), <int>[
        10000,
        29990,
        30000,
      ]);
      expect(musicLrcWithLineStart(t, 3, 1000), isNull);
    });
  });

  group('MusicLyricsService auto-sync', () {
    late FushiDatabase db;
    late Directory dir;
    late int now;

    MusicLyricsService service() => MusicLyricsService(
      database: () => db,
      lrclib: LrclibClient(
        transport: (Uri uri) async => (status: 404, body: ''),
      ),
      onlineEnabled: () => false,
      readEmbedded: (String _, int? _) async => const <EmbeddedLyrics>[],
      parse: _parse,
      now: () => now++,
    );

    MusicLyricsTrackRef track() => MusicLyricsTrackRef(
      trackUid: 'uid-1',
      path: '${dir.path}${Platform.pathSeparator}song.flac',
      title: 'Song',
      artist: 'Singer',
      durationMs: 60000,
    );

    Future<LyricTimeline> plain() => _parse(utf8.encode(_plain), 'txt', 60000);

    Future<void> saveTranscript(MusicLyricsService s, String srt) async {
      final Uint8List raw = utf8.encode(srt);
      await s.saveGenerated(
        'uid-1',
        format: 'srt',
        raw: raw,
        timeline: await _parse(raw, 'srt', 60000),
      );
    }

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      dir = Directory.systemTemp.createTempSync('fushi_lyrics_autosync_');
      File(track().path).writeAsBytesSync(<int>[0]);
      now = 1000;
    });

    tearDown(() async {
      await db.close();
      dir.deleteSync(recursive: true);
    });

    test('without a transcript it asks for one and saves nothing', () async {
      final MusicLyricsService s = service();
      final MusicLyricsAutoSyncOutcome o = await s.autoSyncPlainLyrics(
        track(),
        await plain(),
      );
      expect(o.status, MusicLyricsAutoSyncStatus.needsTranscript);
      expect(await s.hasAutoSynced('uid-1'), isFalse);
    });

    test('synced lines are saved as a local LRC user choice, original text '
        'kept, section markers dropped', () async {
      final MusicLyricsService s = service();
      await saveTranscript(s, _transcriptSrt);
      final MusicLyricsAutoSyncOutcome o = await s.autoSyncPlainLyrics(
        track(),
        await plain(),
      );
      expect(o.status, MusicLyricsAutoSyncStatus.synced);
      expect(o.lines, 3);
      expect(await s.hasAutoSynced('uid-1'), isTrue);

      final MusicLyricRow row = (await db.select(db.musicLyrics).get())
          .singleWhere((MusicLyricRow r) => r.source == MusicLyricsSource.user);
      expect(row.format, 'lrc');
      expect(row.isUserEdited, isTrue);
      final String lrc = utf8.decode(row.raw);
      expect(lrc, contains('[ti:Song]'));
      expect(lrc, contains('[00:12.00]きみのなまえをよんだ'));
      expect(lrc, isNot(contains('Chorus')));

      final MusicLyricsResolution? r = await s.resolve(track());
      expect(r?.source, MusicLyricsSource.user);
      expect(r!.timeline.isSynced, isTrue);
      expect(r.timeline.lines.map((LyricLine l) => l.text), <String>[
        'きみのなまえをよんだ',
        'とおいそらのしたで',
        'またあえるひまで',
      ]);
      expect(r.timeline.lines.map((LyricLine l) => l.startMs), <int>[
        12000,
        16000,
        21000,
      ]);

      // 缓存失效（解析器升级）后按行记的格式重解析：LRC 原文照样读得回来。
      final LyricTimeline reparsed = await parseStoredMusicLyrics(
        row.raw,
        row.format,
        parse: _parse,
      );
      expect(reparsed.lines, hasLength(3));
    });

    test('an unrelated transcript is reported and nothing is saved', () async {
      final MusicLyricsService s = service();
      await saveTranscript(s, _unrelatedSrt);
      final MusicLyricsAutoSyncOutcome o = await s.autoSyncPlainLyrics(
        track(),
        await plain(),
      );
      expect(o.status, MusicLyricsAutoSyncStatus.unreliable);
      expect(await s.hasAutoSynced('uid-1'), isFalse);
    });

    test(
      'registered before generation: runs when the transcript lands',
      () async {
        final MusicLyricsService s = service();
        final List<MusicLyricsAutoSyncEvent> events =
            <MusicLyricsAutoSyncEvent>[];
        final List<String> updates = <String>[];
        s.autoSyncResults.listen(events.add);
        s.generatedUpdates.listen(updates.add);
        s.autoSyncWhenGenerated(track(), await plain());
        expect(s.autoSyncPending('uid-1'), isTrue);
        await saveTranscript(s, _transcriptSrt);
        await pumpEventQueue();
        expect(s.autoSyncPending('uid-1'), isFalse);
        expect(events.single.trackUid, 'uid-1');
        expect(events.single.outcome.status, MusicLyricsAutoSyncStatus.synced);
        // 转录落库一次、对时结果再一次：页面两次都重载。
        expect(updates, <String>['uid-1', 'uid-1']);
        expect((await s.resolve(track()))?.source, MusicLyricsSource.user);
      },
    );

    test('workbench fine-tune moves one line and keeps the offset', () async {
      final MusicLyricsService s = service();
      await saveTranscript(s, _transcriptSrt);
      await s.autoSyncPlainLyrics(track(), await plain());
      await s.setOffset('uid-1', MusicLyricsSource.user, 250);
      expect(await s.setAutoSyncedLineStart(track(), 1, 16800), isTrue);
      final MusicLyricsResolution? r = await s.resolve(track());
      expect(r!.timeline.lines.map((LyricLine l) => l.startMs), <int>[
        12000,
        16800,
        21000,
      ]);
      expect(r.timeline.offsetMs, 250);
    });

    test('fine-tune does nothing when the effective lyrics were chosen, not '
        'auto-synced', () async {
      final MusicLyricsService s = service();
      final LyricTimeline t = await _parse(
        utf8.encode('[00:01.00]a\n[00:02.00]b\n'),
        'lrc',
        null,
      );
      await s.choose(
        'uid-1',
        MusicLyricsCandidate(
          source: MusicLyricsSource.lrclib,
          label: 'x',
          format: 'lrc',
          raw: utf8.encode('[00:01.00]a\n[00:02.00]b\n'),
          timeline: t,
        ),
      );
      expect(await s.hasAutoSynced('uid-1'), isFalse);
      expect(await s.setAutoSyncedLineStart(track(), 0, 500), isFalse);
      // 选来源的行仍按 TTML 原文解析（format 记的是 ttml）。
      final MusicLyricsResolution? r = await s.resolve(track());
      expect(r!.timeline.lines.map((LyricLine l) => l.text), <String>[
        'a',
        'b',
      ]);
    });
  });
}
