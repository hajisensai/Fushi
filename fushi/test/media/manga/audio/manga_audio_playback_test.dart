// 漫画有声（成品音频）播放端端到端：手写清单 → 入库（Audiobooks + 每句一条 cue）→
// 播放编排（句子音频 + 静音条目铺满时间表、纯听 = 去掉页时间）→ 句序驱动（位置 →
// 高亮哪几块 / 翻到哪页、用户翻页重定位、纯听跳过页停留、占位句照常高亮）→
// 后台入口（AudiobookSessionLauncher 遇到漫画格式走同一条编排）。
// 翻页式（spread 两页一组）与条漫（spread 只有一页，isSameSpread 语义）各验一遍。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_validate.dart'
    show mangaPayloadOcrSignature;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_session_launcher.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_library.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_playback_driver.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_playback_plan.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_session.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_silence.dart';
import 'package:fushi/src/media/manga/reader/manga_read_aloud_controller.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_timeline.dart';
import 'package:path/path.dart' as p;

/// 手写清单：5 页。
/// - 第 0 页：两句，同一人；第二句跨两个块（3、4）。
/// - 第 1 页：无台词，`hold` 覆盖成 2000。
/// - 第 2 页：一句占位（没配上音，静音文件）。
/// - 第 3 页：无台词，默认停留。
/// - 第 4 页：一句，换人、心声（内心 ↔ 说出口切换前一句是说出口）。
const String _fixture = '''
{
  "v": 1,
  "pageCount": 5,
  "ocr": "sig-1",
  "lines": [
    {"id": "p0b0", "p": 0, "b": [0], "s": "A", "k": "spoken", "f": "a/p0b0.wav", "ms": 1200, "t": "line one"},
    {"id": "p0b3", "p": 0, "b": [3, 4], "s": "A", "k": "spoken", "beat": 200, "f": "a/p0b3.wav", "ms": 800, "t": "line two"},
    {"id": "p2b1", "p": 2, "b": [1], "s": "B", "k": "spoken", "f": "a/p2b1.wav", "ms": 900, "t": "", "ph": true},
    {"id": "p4b0", "p": 4, "b": [0, 2], "s": "B", "k": "thought", "f": "a/p4b0.wav", "ms": 1500, "t": "line four"}
  ],
  "pages": {"1": {"hold": 2000}}
}
''';

MangaRenderManifest _manifest() =>
    MangaRenderManifest.fromJson(jsonDecode(_fixture))!;

/// 假播放器：位置由测试设定，seek 立即生效。
class _Player extends ChangeNotifier implements MangaAudioPlayerPort {
  int pos = 0;
  bool playing = false;
  double rate = 1.0;
  final List<int> seeks = <int>[];

  void at(int ms) {
    pos = ms;
    notifyListeners();
  }

  @override
  int get positionMs => pos;
  @override
  bool get isPlaying => playing;
  @override
  double get speed => rate;
  @override
  Future<void> play() async {
    playing = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    playing = false;
    notifyListeners();
  }

  /// 设了就模拟跨文件跳转：落地（闸门放开）前位置不变，旧文件照常往下报。
  Completer<void>? seekGate;

  @override
  Future<void> seekMs(int ms) async {
    seeks.add(ms);
    final Completer<void>? gate = seekGate;
    if (gate != null) await gate.future;
    pos = ms;
    notifyListeners();
  }

  @override
  Future<void> setSpeed(double speed) async => rate = speed;
}

/// 假宿主：[pairs] = 翻页式（spread 0-1、2-3、4），否则条漫（每页自成一屏）。
/// [show] 翻到别的 spread 时像真页面一样回报页变化。
class _Host implements MangaReadAloudHost {
  _Host({required this.pairs});

  final bool pairs;
  final List<(int, List<int>)> shown = <(int, List<int>)>[];
  int visible = 0;
  int clears = 0;
  int activity = 0;
  void Function(int page)? onPageChanged;

  @override
  int get pageCount => 5;
  @override
  bool get rightToLeft => true;
  @override
  int get visiblePage => visible;
  @override
  bool isSameSpread(int a, int b) => pairs ? a ~/ 2 == b ~/ 2 : a == b;
  @override
  Future<MangaPageTextResult> ensurePageText(int pageIndex) =>
      throw UnimplementedError();
  @override
  Future<void> show(int pageIndex, List<int> blocks) async {
    shown.add((pageIndex, blocks));
    if (!isSameSpread(pageIndex, visible)) {
      visible = pairs ? pageIndex - pageIndex % 2 : pageIndex;
      onPageChanged?.call(visible);
    }
  }

  @override
  Future<void> clearHighlight() async => clears++;
  @override
  void markStudyActivity() => activity++;
}

/// 记录里的 List 按身份比较，逐字段断言。
void _expectShown(_Host host, int page, List<int> blocks) {
  expect(host.shown.last.$1, page);
  expect(host.shown.last.$2, blocks);
}

void main() {
  group('播放编排', () {
    test('条目铺满边看边听时间表；页段与 hold 覆盖照清单', () {
      final MangaRenderManifest m = _manifest();
      final MangaTimeline watch = m.timeline();
      final MangaAudioPlaybackPlan plan = MangaAudioPlaybackPlan.build(m);
      expect(plan.totalMs, watch.totalMs);
      int pos = 0;
      for (final MangaAudioItem item in plan.items) {
        expect(item.startMs, pos, reason: '$item');
        pos += item.durationMs;
      }
      expect(pos, plan.totalMs);
      for (int i = 0; i < m.lines.length; i++) {
        expect(plan.lineStartMs(i), watch.lines[i].startMs);
        expect(plan.lineIndexAt(watch.lines[i].startMs + 1), i);
      }
      expect(plan.segments, watch.segments);
      // 第 1 页 hold 覆盖成 2000，第 3 页默认 4000。
      expect(plan.segments[1].durationMs, 2000);
      expect(plan.segments[3].durationMs, 4000);
      expect(plan.pageAt(plan.pageStartMs(3) + 10), 3);
      expect(plan.lineIndexAt(plan.pageStartMs(1) + 10), isNull);
    });

    test('纯听时间表 = 去掉页时间条目（句间停顿保留）', () {
      final MangaRenderManifest m = _manifest();
      final MangaTimeline listen = m.timeline(
        mode: MangaPlaybackMode.listenOnly,
      );
      final MangaAudioPlaybackPlan plan = MangaAudioPlaybackPlan.build(m);
      int kept = 0;
      int lineSeen = 0;
      for (final MangaAudioItem item in plan.items) {
        if (item.kind.isPageTime) continue;
        if (item.isLine) {
          expect(kept, listen.lines[lineSeen].startMs, reason: '$item');
          lineSeen++;
        }
        kept += item.durationMs;
      }
      expect(kept, listen.totalMs);
      // 进入第 1 页的 hold → 跳到第 2 页第一句（lead 也跳过）。
      final int holdItem = plan.itemIndexAt(plan.pageStartMs(1));
      expect(plan.items[holdItem].kind, MangaAudioItemKind.hold);
      expect(plan.listenOnlySkipTarget(holdItem), plan.lineStartMs(2));
      // 句间停顿不跳。
      final int gap = plan.items.indexWhere(
        (MangaAudioItem i) => i.kind == MangaAudioItemKind.gap,
      );
      expect(plan.listenOnlySkipTarget(gap), isNull);
    });

    test('进度口径：播放毫秒 ↔ 只数句子音频的毫秒，静音里续播从下一句开始', () {
      final MangaAudioPlaybackPlan plan = MangaAudioPlaybackPlan.build(
        _manifest(),
      );
      final int inLine1 = plan.lineStartMs(1) + 300;
      expect(plan.toLinePositionMs(inLine1), 1200 + 300);
      expect(plan.fromLinePositionMs(1200 + 300), inLine1);
      // 第 1 页 hold 里 → 第 2 句（下标 2）开头 = 前两句时长之和。
      expect(plan.toLinePositionMs(plan.pageStartMs(1) + 50), 1200 + 800);
      expect(
        plan.fromLinePositionMs(plan.toLinePositionMs(plan.pageStartMs(1))),
        plan.lineStartMs(2),
      );
      expect(plan.fromLinePositionMs(0), 0);
    });

    test('cue 与条目一一对应：句子带页 / 块 / 文本，静音只带页', () {
      final MangaAudioPlaybackPlan plan = MangaAudioPlaybackPlan.build(
        _manifest(),
      );
      final List<AudioCue> cues = plan.cues('vol');
      expect(cues.length, plan.items.length);
      final AudioCue two = cues[plan.itemIndexOfLine(1)];
      expect(two.chapterHref, 'manga-page-0');
      expect(parseMangaBlocksFragment(two.textFragmentId), <int>[3, 4]);
      expect(two.text, 'line two');
      expect(two.endMs, 800);
      final AudioCue hold = cues[plan.itemIndexAt(plan.pageStartMs(1))];
      expect(hold.text, isEmpty);
      expect(hold.chapterHref, 'manga-page-1');
      for (int i = 0; i < cues.length; i++) {
        expect(cues[i].audioFileIndex, i);
      }
      // 从 cue 推出的文件时长 = 条目时长（播放器的全书毫秒按它编码）。
      expect(audiobookFileDurationsFromCues(cues), <int>[
        for (final MangaAudioItem item in plan.items) item.durationMs,
      ]);
    });

    test('静音 WAV：头 44 字节 + 8 kHz 16 位单声道', () {
      final Uint8List bytes = mangaSilenceWavBytes(1000);
      expect(bytes.length, 44 + 16000);
      expect(ascii.decode(bytes.sublist(0, 4)), 'RIFF');
      expect(ascii.decode(bytes.sublist(8, 12)), 'WAVE');
      expect(bytes.sublist(44).every((int b) => b == 0), isTrue);
    });
  });

  group('句序驱动', () {
    late MangaAudioPlaybackPlan plan;
    late _Player player;
    late MangaAudioPlaybackDriver driver;

    setUp(() {
      plan = MangaAudioPlaybackPlan.build(_manifest());
      player = _Player();
      driver = MangaAudioPlaybackDriver(
        bookKey: 'vol',
        plan: plan,
        player: player,
      );
    });

    tearDown(() => driver.dispose());

    for (final bool pairs in <bool>[true, false]) {
      final String mode = pairs ? '翻页式' : '条漫';
      test('$mode：位置推进 → 逐句高亮（跨块一句框两块）、无台词页只翻页清高亮', () async {
        final _Host host = _Host(pairs: pairs);
        host.onPageChanged = driver.onPageChanged;
        driver.attachHost(host, visible: true);
        player.playing = true;
        player.at(plan.lineStartMs(0) + 10);
        player.at(plan.lineStartMs(1) + 10);
        await Future<void>.delayed(Duration.zero);
        _expectShown(host, 0, <int>[3, 4]);
        player.at(plan.pageStartMs(1) + 10);
        await Future<void>.delayed(Duration.zero);
        _expectShown(host, 1, <int>[]);
        // 翻页式下第 1 页与第 0 页同屏，不翻；条漫下翻到第 1 页。
        expect(host.visible, pairs ? 0 : 1);
        // 自己翻的页不算用户翻页：没有重定位。
        expect(player.seeks, isEmpty);
        // 占位句照常高亮。
        player.at(plan.lineStartMs(2) + 10);
        await Future<void>.delayed(Duration.zero);
        _expectShown(host, 2, <int>[1]);
        expect(driver.currentLine!.placeholder, isTrue);
        expect(host.visible, 2);
        expect(host.activity, 3, reason: '每开始读一句喂一次学习时钟');
      });

      test('$mode：用户翻到别的屏 → 跳到该页页段起点；关跟随时音频不动', () async {
        final _Host host = _Host(pairs: pairs);
        host.onPageChanged = driver.onPageChanged;
        driver.attachHost(host, visible: true);
        player.playing = true;
        player.at(plan.lineStartMs(0) + 10);
        await Future<void>.delayed(Duration.zero);
        // 同屏的页变化（翻页式下 0→1 同一 spread）不重定位；条漫下 1 是另一屏。
        host.visible = 1;
        driver.onPageChanged(1);
        await Future<void>.delayed(Duration.zero);
        if (pairs) {
          expect(player.seeks, isEmpty);
        } else {
          expect(player.seeks, <int>[plan.pageStartMs(1)]);
        }
        player.seeks.clear();
        host.visible = 4;
        driver.onPageChanged(4);
        await Future<void>.delayed(Duration.zero);
        expect(player.seeks, <int>[plan.pageStartMs(4)]);
        expect(driver.currentPage, 4);

        driver.setFollowPage(false);
        player.seeks.clear();
        host.visible = 2;
        driver.onPageChanged(2);
        await Future<void>.delayed(Duration.zero);
        expect(player.seeks, isEmpty, reason: '关掉跟随翻页时用户翻页不动音频');
      });

      test('$mode：翻页后跳转落地前旧位置跨句，不把阅读器拉回旧页（BUG-4906）', () async {
        final _Host host = _Host(pairs: pairs);
        host.onPageChanged = driver.onPageChanged;
        driver.attachHost(host, visible: true);
        player.playing = true;
        player.at(plan.lineStartMs(0) + 10);
        await Future<void>.delayed(Duration.zero);

        final Completer<void> gate = Completer<void>();
        player.seekGate = gate;
        host.visible = 4;
        driver.onPageChanged(4);
        await Future<void>.delayed(Duration.zero);
        expect(player.seeks, <int>[plan.pageStartMs(4)]);
        expect(driver.positionMs, plan.pageStartMs(4), reason: '播放条先显示目标');

        // 旧文件还在往下播，跨进第 0 页第二句。
        final int shownBefore = host.shown.length;
        player.at(plan.lineStartMs(1) + 10);
        await Future<void>.delayed(Duration.zero);
        expect(host.shown.length, shownBefore, reason: '在途期间不显示旧句');
        expect(host.visible, 4, reason: '不被拉回旧页');

        player.seekGate = null;
        gate.complete();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(host.visible, 4);
        expect(driver.currentPage, 4);
        expect(player.seeks, <int>[plan.pageStartMs(4)], reason: '没有被拉回后再跳一次');
      });

      test('$mode：连续翻页（滚轮）时先发的跳转后落地，不把阅读器拉回中间页（BUG-4906）', () async {
        final _Host host = _Host(pairs: pairs);
        host.onPageChanged = driver.onPageChanged;
        driver.attachHost(host, visible: true);
        // 暂停中翻页同样会重定位（截图里的场景）。
        player.at(plan.lineStartMs(0) + 10);
        await Future<void>.delayed(Duration.zero);

        final Completer<void> first = Completer<void>();
        player.seekGate = first;
        host.visible = 2;
        driver.onPageChanged(2);
        final Completer<void> second = Completer<void>();
        player.seekGate = second;
        host.visible = 4;
        driver.onPageChanged(4);
        await Future<void>.delayed(Duration.zero);
        expect(player.seeks, <int>[plan.pageStartMs(2), plan.pageStartMs(4)]);
        expect(driver.positionMs, plan.pageStartMs(4));

        // 先发的那次落地：用户已经在第 4 页，不显示第 2 页、不翻回去。
        final int shownBefore = host.shown.length;
        first.complete();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(host.shown.length, shownBefore);
        expect(host.visible, 4);
        expect(driver.positionMs, plan.pageStartMs(4), reason: '播放条仍显示最后一次目标');

        player.seekGate = null;
        second.complete();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(host.visible, 4);
        expect(driver.currentPage, 4);
        expect(host.shown.last.$1, 4, reason: '落地后显示的是第 4 页页段');
      });
    }

    // 反馈 WrLFAXNkSw：翻页落到页段起点（lead）、进书续播落在句间停顿、暂停停在静音
    // 里时高亮一律被清空，暂停时位置不再变就一直不回来。
    for (final bool pairs in <bool>[true, false]) {
      final String mode = pairs ? '翻页式' : '条漫';
      test('$mode：暂停中翻页落到 lead → 框本页第一句', () async {
        final _Host host = _Host(pairs: pairs);
        host.onPageChanged = driver.onPageChanged;
        player.at(plan.lineStartMs(0) + 10);
        driver.attachHost(host, visible: true);
        await Future<void>.delayed(Duration.zero);
        expect(player.playing, isFalse);
        host.visible = 4;
        driver.onPageChanged(4);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(player.seeks, <int>[plan.pageStartMs(4)]);
        expect(
          plan.items[plan.itemIndexAt(plan.pageStartMs(4))].kind,
          MangaAudioItemKind.lead,
          reason: '落点是页首 lead，不是句子本身',
        );
        _expectShown(host, 4, <int>[0, 2]);
      });

      test('$mode：进书续播落在句间停顿 / 页尾补齐 → 框本页刚读完的那句', () async {
        final int gap = plan.items.indexWhere(
          (MangaAudioItem i) => i.kind == MangaAudioItemKind.gap && i.page == 0,
        );
        expect(gap, greaterThanOrEqualTo(0));
        player.at(plan.items[gap].startMs + 1);
        final _Host host = _Host(pairs: pairs);
        host.onPageChanged = driver.onPageChanged;
        driver.attachHost(host, visible: true);
        await Future<void>.delayed(Duration.zero);
        final int line = plan.items
            .sublist(0, gap)
            .lastWhere((MangaAudioItem i) => i.isLine)
            .lineIndex;
        _expectShown(host, 0, _manifest().lines[line].blocks);
        // 页尾之后的静音（同页）同样保留刚读完那句；无台词页才清。
        final MangaAudioItem lastOnPage0 = plan.items.lastWhere(
          (MangaAudioItem i) => i.page == 0,
        );
        player.at(lastOnPage0.startMs + 1);
        await Future<void>.delayed(Duration.zero);
        _expectShown(host, 0, <int>[3, 4]);
        player.at(plan.pageStartMs(1) + 10);
        await Future<void>.delayed(Duration.zero);
        _expectShown(host, 1, <int>[]);
      });
    }

    test('纯听（无宿主 / 阅读器不可见）跳过页时间，边看边听不跳', () async {
      final _Host host = _Host(pairs: true);
      driver.attachHost(host, visible: true);
      player.playing = true;
      final int hold = plan.pageStartMs(1) + 10;
      player.at(hold);
      expect(player.seeks, isEmpty);
      expect(driver.mode, MangaPlaybackMode.watchAndListen);

      driver.setReaderVisible(false);
      expect(driver.mode, MangaPlaybackMode.listenOnly);
      expect(player.seeks, <int>[plan.lineStartMs(2)]);

      // 阅读器离开（会话后台继续播）同样是纯听。
      driver.setReaderVisible(true);
      driver.detachHost(host);
      player.seeks.clear();
      player.at(plan.pageStartMs(3) + 10);
      expect(player.seeks, <int>[plan.lineStartMs(3)]);
      // 暂停中不跳（恢复播放时再跳）。
      player.playing = false;
      player.seeks.clear();
      player.at(plan.pageStartMs(3) + 20);
      expect(player.seeks, isEmpty);
    });

    test('上一句 / 下一句 / 拖进度 / 媒体键', () async {
      player.at(plan.lineStartMs(0) + 100);
      await driver.next();
      expect(player.pos, plan.lineStartMs(1));
      await driver.next();
      expect(player.pos, plan.lineStartMs(2), reason: '跨过无台词页');
      await driver.previous();
      expect(player.pos, plan.lineStartMs(1));
      player.at(plan.lineStartMs(3) + 1600);
      await driver.previous();
      expect(player.pos, plan.lineStartMs(3), reason: '句中超过 1.5 秒回到本句开头');
      await driver.seekTo(plan.totalMs + 999);
      expect(player.pos, plan.totalMs);
      expect(driver.skipLine(-1), isTrue);
    });

    test('查后从句首重播：指定句 / 当前页刚读过的句 / 本页还没读到句子原地播（BUG-4909）', () async {
      // 边看边听（挂着可见的阅读器）：纯听形态起播会照设计跳过页停留，混进 seeks。
      driver.attachHost(_Host(pairs: true), visible: true);
      player.at(plan.lineStartMs(1) + 300);
      await driver.playFromLine(0);
      expect(player.pos, plan.lineStartMs(0));
      expect(player.playing, isTrue);

      player.playing = false;
      player.at(plan.lineStartMs(1) + 300);
      await driver.playFromLine(null);
      expect(player.pos, plan.lineStartMs(1), reason: '当前句句首');

      // 第 1 页无台词（页停留里）：往回找会跨到第 0 页，不为重播把读者拉回上一页。
      player.playing = false;
      player.seeks.clear();
      player.at(plan.pageStartMs(1) + 10);
      await driver.playFromLine(null);
      expect(player.seeks, isEmpty);
      expect(player.playing, isTrue);
    });
  });

  group('入库与后台入口', () {
    late Directory tmp;
    late FushiDatabase db;
    late File manifestFile;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('manga_audio_playback_test');
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      manifestFile = File(p.join(tmp.path, 'out', 'manifest.json'));
      await _manifest().save(manifestFile);
      for (final MangaRenderedLine line in _manifest().lines) {
        final File f = File(mangaAudioLinePath(manifestFile, line));
        f.parent.createSync(recursive: true);
        f.writeAsBytesSync(mangaSilenceWavBytes(line.durationMs));
      }
    });

    tearDown(() async {
      await db.close();
      tmp.deleteSync(recursive: true);
    });

    test('registerMangaAudio：每句一条 cue、音频绝对路径、幂等', () async {
      for (int round = 0; round < 2; round++) {
        await registerMangaAudio(
          db,
          bookKey: 'vol',
          manifestFile: manifestFile,
          manifest: _manifest(),
        );
      }
      final AudiobookRepository repo = AudiobookRepository(db);
      final Audiobook ab = (await repo.findByBookKey('vol'))!;
      expect(ab.alignmentFormat, kMangaAlignmentFormat);
      expect(ab.alignmentPath, manifestFile.absolute.path);
      expect(ab.audioPaths, <String>[
        for (final MangaRenderedLine l in _manifest().lines)
          p.normalize(p.join(manifestFile.parent.path, l.file)),
      ]);
      final List<AudioCue> cues = await repo.cuesForBook('vol')
        ..sort((AudioCue a, AudioCue b) => a.audioFileIndex - b.audioFileIndex);
      expect(cues.length, 4);
      expect(cues.map((AudioCue c) => c.chapterHref), <String>[
        'manga-page-0',
        'manga-page-0',
        'manga-page-2',
        'manga-page-4',
      ]);
      expect(cues[1].textFragmentId, '3,4');
      expect(cues.map((AudioCue c) => c.endMs), <int>[1200, 800, 900, 1500]);
      expect(cues.map((AudioCue c) => c.startMs).toSet(), <int>{0});

      final MangaAudioRegistration? reg = await loadMangaAudio(db, 'vol');
      expect(reg!.manifest.lines.length, 4);
    });

    test('updateMangaAudioLine：只换补回的那一句', () async {
      await registerMangaAudio(
        db,
        bookKey: 'vol',
        manifestFile: manifestFile,
        manifest: _manifest(),
      );
      final MangaRenderManifest m = _manifest();
      m.replaceLine(
        'p2b1',
        (MangaRenderedLine l) => l.replaced(
          file: 'a/p2b1_s1.wav',
          durationMs: 1100,
          placeholder: false,
          text: 'filled',
        ),
      );
      expect(
        await updateMangaAudioLine(
          db,
          bookKey: 'vol',
          manifestFile: manifestFile,
          manifest: m,
          lineId: 'p2b1',
        ),
        isTrue,
      );
      final AudiobookRepository repo = AudiobookRepository(db);
      final List<AudioCue> cues = await repo.cuesForBook('vol')
        ..sort((AudioCue a, AudioCue b) => a.audioFileIndex - b.audioFileIndex);
      expect(cues.map((AudioCue c) => c.endMs), <int>[1200, 800, 1100, 1500]);
      expect(cues[2].text, 'filled');
      final Audiobook ab = (await repo.findByBookKey('vol'))!;
      expect(ab.audioPaths![2], endsWith('p2b1_s1.wav'));
      expect(ab.audioPaths![1], endsWith('p0b3.wav'));
      expect(
        await updateMangaAudioLine(
          db,
          bookKey: 'vol',
          manifestFile: manifestFile,
          manifest: m,
          lineId: 'nope',
        ),
        isFalse,
      );
    });

    test('导入核对本卷 OCR：页数 / 签名不符拒绝；mokuro 卷按块内容签名', () {
      final MangaRenderManifest manifest = _manifest();
      MokuroPayload payload(String text, {String? engine}) => MokuroPayload(
        ocr: engine == null
            ? null
            : MangaOcrMetadata(
                engine: 'e',
                engineSignature: engine,
                schemaVersion: 1,
              ),
        images: <MokuroImage>[
          for (int i = 0; i < manifest.pageCount; i++)
            MokuroImage(
              url: 'p$i.jpg',
              size: const MokuroSize(100, 100),
              blocks: <MokuroBlock>[
                MokuroBlock(
                  rectangle: const MokuroRect.fromLTRB(0, 0, 10, 10),
                  isVertical: true,
                  fontSize: 12,
                  zIndex: 0,
                  lines: <String>['$text$i'],
                ),
              ],
            ),
        ],
      );
      // 没记签名的旧清单：只核页数。
      final MangaRenderManifest unsigned = MangaRenderManifest(
        pageCount: manifest.pageCount,
        lines: manifest.lines,
        pages: manifest.pages,
      );
      expect(mangaManifestVolumeMismatch(unsigned, payload('a')), isNull);
      expect(
        mangaManifestVolumeMismatch(
          unsigned,
          const MokuroPayload(images: <MokuroImage>[]),
        ),
        MangaAudioImportResult.pageMismatch,
      );
      // mokuro 卷（无引擎签名）：内容签名一致才收，内容变了拒绝。
      MangaRenderManifest signed(String sig) => MangaRenderManifest(
        pageCount: manifest.pageCount,
        lines: manifest.lines,
        pages: manifest.pages,
        engineSignature: sig,
      );
      final String content = mangaPayloadOcrSignature(payload('a'));
      expect(content, startsWith('content:'));
      expect(
        mangaManifestVolumeMismatch(signed(content), payload('a')),
        isNull,
      );
      expect(
        mangaManifestVolumeMismatch(signed(content), payload('b')),
        MangaAudioImportResult.ocrMismatch,
      );
      // 有引擎签名：按引擎签名比。
      expect(
        mangaManifestVolumeMismatch(
          signed('eng-1'),
          payload('x', engine: 'eng-1'),
        ),
        isNull,
      );
      expect(
        mangaManifestVolumeMismatch(
          signed('eng-1'),
          payload('x', engine: 'eng-2'),
        ),
        MangaAudioImportResult.ocrMismatch,
      );
    });

    test('importMangaAudioManifest：坏清单 / 缺音频不登记', () async {
      final File bad = File(p.join(tmp.path, 'bad.json'))
        ..writeAsStringSync('{not json');
      expect(
        await importMangaAudioManifest(db, bookKey: 'vol', manifestFile: bad),
        MangaAudioImportResult.invalid,
      );
      File(mangaAudioLinePath(manifestFile, _manifest().lines[3])).deleteSync();
      expect(
        await importMangaAudioManifest(
          db,
          bookKey: 'vol',
          manifestFile: manifestFile,
        ),
        MangaAudioImportResult.missingAudio,
      );
      expect(await loadMangaAudio(db, 'vol'), isNull);
    });

    test('后台入口：launcher 对漫画格式走同一套编排（静音条目、内存 cue、进度换算）', () async {
      await registerMangaAudio(
        db,
        bookKey: 'vol',
        manifestFile: manifestFile,
        manifest: _manifest(),
      );
      final AudiobookRepository repo = AudiobookRepository(db);
      // 库里存的是「只数句子」的口径：第二句中间。
      await repo.updatePositionMs(bookKey: 'vol', positionMs: 1200 + 300);
      final AudiobookSessionStartRequest req = (await AudiobookSessionLauncher(
        db,
      ).resolve('vol'))!;
      final MangaAudioPlaybackPlan plan = MangaAudioPlaybackPlan.build(
        _manifest(),
      );
      expect(req.info.cueLayoutId, plan.layoutId);
      expect(req.info.format, BookFormat.manga);
      expect(req.audioFiles.length, plan.items.length);
      expect(req.cues.length, plan.items.length);
      expect(req.prefs.positionMs, plan.lineStartMs(1) + 300);
      for (final File f in req.audioFiles) {
        expect(f.existsSync(), isTrue, reason: f.path);
      }
      expect(req.companion, isNotNull);
      // 会话写进度时换回「只数句子」的口径。
      await req.persist.onPositionWrite('vol', plan.pageStartMs(1) + 10);
      expect(await repo.readPositionMs('vol'), 1200 + 800);
    });

    // 反馈 Wi5MxmIT24：阅读器起播漏传封面，首页迷你播放条只能画兜底图标。两个入口
    // 都由 resolveMangaAudioSessionRequest 按 bookKey 统一取元数据。
    test('阅读器起播与后台入口给会话的书名 / 作者 / 封面一致且带封面', () async {
      await registerMangaAudio(
        db,
        bookKey: 'vol',
        manifestFile: manifestFile,
        manifest: _manifest(),
      );
      final Directory extract = Directory(p.join(tmp.path, 'book'))
        ..createSync(recursive: true);
      final File cover = File(p.join(extract.path, 'cover.jpg'))
        ..writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF]);
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'vol',
          title: 'Volume 1',
          epubPath: p.join(tmp.path, 'vol.cbz'),
          extractDir: extract.path,
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: 1000,
          author: const Value<String?>('Author A'),
          coverPath: const Value<String?>('cover.jpg'),
          format: const Value<String>('manga'),
        ),
      );
      final MangaAudioRegistration reg = (await loadMangaAudio(db, 'vol'))!;
      final AudiobookSessionStartRequest fromReader =
          await resolveMangaAudioSessionRequest(db, registration: reg);
      final AudiobookSessionStartRequest fromLauncher =
          (await AudiobookSessionLauncher(db).resolve('vol'))!;
      for (final AudiobookSessionStartRequest req
          in <AudiobookSessionStartRequest>[fromReader, fromLauncher]) {
        expect(req.info.coverPath, isNotNull);
        expect(p.equals(req.info.coverPath!, cover.path), isTrue);
        expect(req.info.title, 'Volume 1');
        expect(req.info.author, 'Author A');
        expect(req.info.format, BookFormat.manga);
      }
    });
  });
}
