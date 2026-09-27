import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// WebM 音画同步片段在卡片内 `<video>` 内嵌播放（Anki 桌面 Qt WebEngine 无 H.264/AAC，
/// 只有 WebM 能内嵌）。钉住三件事：
/// 1. 引用串形态：`<video>` 无 `autoplay` 属性、不产生任何 `[sound:]`；
/// 2. 嵌进 Lapis 的 JS 模板字面量也不会坏（无反引号 / `${` / 反斜杠）；
/// 3. Lapis 把 Picture 渲染三次时，只有**可见**的那一个被播放（node 实跑脚本）。
void main() {
  group('inline WebM cover', () {
    test('coverMediaRef(webm) → <video>，无 autoplay 属性、无 [sound:]', () {
      final String ref = coverMediaRef('fushi_cover_abc.webm');
      expect(ref, startsWith('<video class="fushi-inline-video"'));
      expect(ref, contains('src="fushi_cover_abc.webm"'));
      expect(ref, contains(' controls '));
      expect(ref, isNot(contains('autoplay')));
      expect(ref, isNot(contains('[sound:')));
      expect(coverMediaRef('CLIP.WEBM'), startsWith('<video'));
      // MP4 仍交给原生播放器：Qt WebEngine 放不了 H.264。
      expect(coverMediaRef('clip.mp4'), '[sound:clip.mp4]');
    });

    test('src 做 HTML 转义', () {
      expect(coverMediaRef('a"b.webm'), contains('src="a&quot;b.webm"'));
    });

    test('isAnkiInlineVideoCover 只认 webm', () {
      expect(isAnkiInlineVideoCover('/tmp/x/immersion_video.webm'), isTrue);
      expect(isAnkiInlineVideoCover('/tmp/x/immersion_video.mp4'), isFalse);
      expect(isAnkiInlineVideoCover('cover.jpg'), isFalse);
      expect(isAnkiInlineVideoCover(null), isFalse);
    });

    // Lapis 背面把 {{SentenceAudio}} 插进 `<script>` 块里的 addAudioButtons JS 模板字面量：
    // 反引号会截断字面量、`${` 会被当成插值、反斜杠会被当成转义，`<script` / `</script>`
    // 会让 HTML 解析器提前结束那个脚本块——任何一个出现，整张卡背面脚本失效。
    for (final MapEntry<String, String> e in <String, String>{
      'inlineVideoSentenceAudioHtml': inlineVideoSentenceAudioHtml(
        'fushi_cover_abc.webm',
      ),
      'inlineVideoCoverHtml': inlineVideoCoverHtml('fushi_cover_abc.webm'),
    }.entries) {
      test('${e.key} 可安全嵌入 JS 模板字面量', () {
        expect(e.value, isNot(contains('`')));
        expect(e.value, isNot(contains(r'${')));
        expect(e.value, isNot(contains(r'\')));
      });
    }

    test('句子音频字段里没有 <script>（会截断 Lapis 背面脚本块）', () {
      final String html = inlineVideoSentenceAudioHtml('fushi_cover_abc.webm');
      expect(html.toLowerCase(), isNot(contains('<script')));
      expect(html.toLowerCase(), isNot(contains('</script')));
      expect(html, isNot(contains('[sound:')));
      expect(html, contains('<audio class="fushi-inline-audio" '));
      expect(html, contains('src="fushi_cover_abc.webm"'));
      // 不能带 autoplay 属性：背面被 Lapis 复制两份，属性自动播放会与画面叠音。
      expect(html, isNot(contains('autoplay')));
    });

    test('重播按钮能被 Lapis 的「点例句重播」找到', () {
      final String html = inlineVideoSentenceAudioHtml('clip.webm');
      expect(html, contains('class="replay-button '));
      expect(html, contains('fushi-synced-video-replay'));
      expect(
        LapisNoteType.back,
        contains('.fushi-sentence-audio .replay-button'),
      );
    });

    test('Picture 渲染三次只播可见那一个；无画面时退回句子音频（node 实跑）', () async {
      final String cover = inlineVideoCoverHtml('clip.webm');
      final String sentence = inlineVideoSentenceAudioHtml('clip.webm');
      final String script = RegExp(
        r'<script>(.*)</script>',
      ).firstMatch(cover)!.group(1)!;
      final String onclick = RegExp(
        r'onclick="([^"]*)"',
      ).firstMatch(sentence)!.group(1)!;
      final String oncanplay = RegExp(
        r'oncanplay="([^"]*)"',
      ).firstMatch(sentence)!.group(1)!;
      final String harness =
          '''
const assert = require('node:assert/strict');
const timers = [];
global.setTimeout = (fn) => timers.push(fn);
process.on('unhandledRejection', () => { process.exitCode = 3; });
function media(visible) {
  return {
    attrs: {}, plays: 0, pauses: 0, currentTime: 2.5,
    offsetParent: visible ? {} : null,
    getAttribute(k) { return this.attrs[k] || null; },
    setAttribute(k, v) { this.attrs[k] = v; },
    play() { this.plays++; return Promise.resolve(); },
    pause() { this.pauses++; },
  };
}
function page(videos, audios) {
  global.document = {
    querySelectorAll(sel) {
      if (sel === 'video.fushi-inline-video') return videos;
      if (sel === 'audio.fushi-inline-audio') return audios;
      throw new Error('unexpected selector ' + sel);
    },
    querySelector(sel) {
      if (sel === 'video.fushi-inline-video') return videos[0] || null;
      if (sel === 'audio.fushi-inline-audio') return audios[0] || null;
      if (sel === 'audio.fushi-inline-audio[data-fushi-started]') {
        return audios.find((a) => a.getAttribute('data-fushi-started')) || null;
      }
      throw new Error('unexpected selector ' + sel);
    },
  };
}
const body = ${jsonEncode(script)};
const click = new Function('event', ${jsonEncode(onclick)});
const canplay = new Function(${jsonEncode(oncanplay)});
const ev = { stopPropagation() {} };

// ① Lapis 背面：Picture 三份（第二份可见），句子音频按钮被复制进两个容器。
const vs = [media(false), media(true), media(false)];
const as = [media(false), media(false)];
page(vs, as);
for (let i = 0; i < 3; i++) new Function(body)();
timers.forEach((t) => t());
as.forEach((a) => canplay.call(a));
assert.deepEqual(vs.map((v) => v.plays), [0, 1, 0], 'only the visible copy autoplays');
assert.deepEqual(as.map((a) => a.plays), [0, 0], 'audio must stay silent when a video is on the page');
assert.equal(vs[1].currentTime, 0);
click(ev);
assert.deepEqual(vs.map((v) => v.plays), [0, 2, 0], 'replay restarts the visible video');
assert.deepEqual(as.map((a) => a.plays), [0, 0]);

// ② Lapis 音频卡正面：只有 {{SentenceAudio}}，没有画面 → 声音自动播一次、按钮能重播。
const front = [media(false)];
page([], front);
canplay.call(front[0]);
canplay.call(front[0]);
assert.equal(front[0].plays, 1, 'front side autoplays the clip sound exactly once');
click(ev);
assert.equal(front[0].plays, 2, 'replay falls back to the audio element');

// ③ 卡组关了自动播放：play() 被拒也不能抛成未处理异常。
const denied = [media(true)];
denied[0].play = () => Promise.reject(new Error('NotAllowedError'));
page(denied, []);
timers.length = 0;
new Function(body)();
timers.forEach((t) => t());
const deniedAudio = [media(false)];
deniedAudio[0].play = () => Promise.reject(new Error('NotAllowedError'));
page([], deniedAudio);
canplay.call(deniedAudio[0]);
''';
      final ProcessResult result = await Process.run('node', <String>[
        '-e',
        harness,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    });
  });

  group('AnkiConnect 同步 WebM 片段落卡', () {
    late Directory dir;
    late File webm;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('hibiki_inline_video');
      // 内容不需要真能播：两端都只按扩展名与字节哈希落媒体。
      webm = File('${dir.path}/immersion_video.webm')
        ..writeAsBytesSync(<int>[
          0x1A,
          0x45,
          0xDF,
          0xA3,
          0x42,
          0x86,
          0x81,
          0x01,
        ]);
    });
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    for (final bool hasSentenceMapping in <bool>[true, false]) {
      test('上传一次、零 [sound:]，sentence mapping=$hasSentenceMapping', () async {
        final _RecordingAnkiConnectService service =
            _RecordingAnkiConnectService();
        final _ConfiguredAnkiConnectRepository repo =
            _ConfiguredAnkiConnectRepository(
              service: service,
              settings: AnkiSettings(
                selectedDeckId: 1,
                selectedNoteTypeId: 2,
                availableDecks: const <AnkiDeck>[
                  AnkiDeck(id: 1, name: 'Mining'),
                ],
                availableNoteTypes: const <AnkiNoteType>[
                  AnkiNoteType(
                    id: 2,
                    name: 'Hibiki',
                    fields: <String>['Expression', 'Picture', 'SentenceAudio'],
                  ),
                ],
                fieldMappings: <String, String>{
                  'Expression': '{expression}',
                  'Picture': '{card-image}',
                  if (hasSentenceMapping) 'SentenceAudio': '{sentence-audio}',
                },
                allowDupes: true,
              ),
            );
        final MineOutcome outcome = await repo.mineEntry(
          rawPayloadJson: '{"expression":"言葉"}',
          context: AnkiMiningContext(
            sentence: 'これは言葉です。',
            coverPath: webm.path,
            sentenceAudioPath: webm.path,
            synchronizedVideo: true,
            source: AnkiMiningSource.video,
          ),
        );
        expect(outcome.result, MineResult.success);
        expect(service.existingMedia, hasLength(1));
        expect(service.existingMedia.single, endsWith('.webm'));
        final Map<String, String> fields = service.addedFields.single;
        expect(
          fields['Picture'],
          startsWith('<video class="fushi-inline-video" src="fushi_cover_'),
        );
        // 画面与声音都在 <video> 里：Anki 原生队列一条都不能再有，否则同一句播两遍。
        expect(fields.values.join(), isNot(contains('[sound:')));
        if (hasSentenceMapping) {
          final String media = RegExp(
            r'src="([^"]+)"',
          ).firstMatch(fields['Picture']!)!.group(1)!;
          expect(fields['SentenceAudio'], inlineVideoSentenceAudioHtml(media));
          final String back = LapisNoteType.back
              .replaceAll('{{Picture}}', fields['Picture']!)
              .replaceAll('{{SentenceAudio}}', fields['SentenceAudio']!);
          expect(back, isNot(contains('[sound:')));
        } else {
          expect(fields['SentenceAudio'], isNull);
        }
      });
    }
  });
}

class _RecordingAnkiConnectService extends AnkiConnectService {
  _RecordingAnkiConnectService() : super(host: 'localhost');

  final List<Map<String, String>> addedFields = <Map<String, String>>[];
  final Set<String> existingMedia = <String>{};

  @override
  Future<bool> mediaFileExists(String filename) async =>
      existingMedia.contains(filename);

  @override
  Future<void> storeMediaFile({
    required String filename,
    String? data,
    String? path,
  }) async {
    existingMedia.add(filename);
  }

  @override
  Future<void> deleteMediaFile(String filename) async {
    existingMedia.remove(filename);
  }

  @override
  Future<int?> addNote({
    required String deckName,
    required String modelName,
    required Map<String, String> fields,
    List<String>? tags,
    Map<String, String>? mediaFiles,
    bool allowDuplicate = false,
    AnkiDuplicateScope duplicateScope = AnkiDuplicateScope.deck,
  }) async {
    addedFields.add(Map<String, String>.from(fields));
    return addedFields.length;
  }
}

class _ConfiguredAnkiConnectRepository extends AnkiConnectRepository {
  _ConfiguredAnkiConnectRepository({
    required AnkiConnectService service,
    required this.settings,
  }) : super(service: service);

  final AnkiSettings settings;

  @override
  Future<AnkiSettings> loadSettings() async => settings;
}
