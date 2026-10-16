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
      'inlineVideoWordAudioHtml': inlineVideoWordAudioHtml(
        'fushi_audio_abc.mp3',
      ),
    }.entries) {
      test('${e.key} 可安全嵌入 JS 模板字面量', () {
        expect(e.value, isNot(contains('`')));
        expect(e.value, isNot(contains(r'${')));
        expect(e.value, isNot(contains(r'\')));
        expect(e.value.toLowerCase(), isNot(contains('<script')));
        expect(e.value.toLowerCase(), isNot(contains('</script')));
        expect(e.value, isNot(contains('[sound:')));
        expect(e.value, isNot(contains('autoplay')));
      });
    }

    // BUG-3442：单词音频留成 [sound:] 时 Anki 原生队列翻面就放，和片段的 oncanplay
    // 同时出声。同步 WebM 片段卡的单词音频必须变成页内 <audio>，其余卡照旧 [sound:]。
    group('renderMediaPayload 单词音频', () {
      const Map<String, String> lapisLike = <String, String>{
        'Expression': '{expression}',
        'ExpressionAudio': '{audio}',
        'Picture': '{card-image}',
        'SentenceAudio': '{sentence-audio}',
      };

      test('同步 WebM 片段卡 → 页内 <audio>，整张卡零 [sound:]', () {
        final Map<String, String> fields = _Composer().render(
          coverPath: '/tmp/immersion_video.webm',
          coverRef: inlineVideoCoverHtml('fushi_cover_abc.webm'),
          mappings: lapisLike,
        );
        expect(
          fields['ExpressionAudio'],
          inlineVideoWordAudioHtml('fushi_audio_word.mp3'),
        );
        expect(fields.values.join(), isNot(contains('[sound:')));
        final String back = LapisNoteType.back
            .replaceAll('{{Picture}}', fields['Picture']!)
            .replaceAll('{{ExpressionAudio}}', fields['ExpressionAudio']!)
            .replaceAll('{{SentenceAudio}}', fields['SentenceAudio']!);
        expect(back, isNot(contains('[sound:')));
      });

      test('MP4 片段卡 / 非同步卡 / 托管模板仍走 [sound:]', () {
        expect(
          _Composer().render(
            coverPath: '/tmp/immersion_video.mp4',
            coverRef: coverMediaRef('fushi_cover_abc.mp4'),
            mappings: lapisLike,
          )['ExpressionAudio'],
          '[sound:fushi_audio_word.mp3]',
        );
        expect(
          _Composer().render(
            coverPath: '/tmp/immersion_video.webm',
            coverRef: inlineVideoCoverHtml('fushi_cover_abc.webm'),
            mappings: lapisLike,
            synchronized: false,
          )['ExpressionAudio'],
          '[sound:fushi_audio_word.mp3]',
        );
        expect(
          _Composer().render(
            coverPath: '/tmp/immersion_video.webm',
            coverRef: inlineVideoCoverHtml('fushi_cover_abc.webm'),
            mappings: <String, String>{...lapisLike, 'Picture': '{card-video}'},
          )['ExpressionAudio'],
          '[sound:fushi_audio_word.mp3]',
        );
      });
    });

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

    // BUG-2837：Anki 编辑器回写字段时删掉所有 <script> / <link>，翻面自动播放必须
    // 只靠内联事件属性（编辑器原样保留）。
    test('画面字段没有 <script> / <link>（Anki 编辑器会删），自动播放挂在 oncanplay', () {
      final String html = inlineVideoCoverHtml('fushi_cover_abc.webm');
      expect(html.toLowerCase(), isNot(contains('<script')));
      expect(html.toLowerCase(), isNot(contains('<link')));
      expect(html, contains('oncanplay="'));
      expect(html, endsWith('></video>'));
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
      final String videoCanplay = RegExp(
        r'oncanplay="([^"]*)"',
      ).firstMatch(cover)!.group(1)!;
      final String onclick = RegExp(
        r'onclick="([^"]*)"',
      ).firstMatch(sentence)!.group(1)!;
      final String oncanplay = RegExp(
        r'oncanplay="([^"]*)"',
      ).firstMatch(sentence)!.group(1)!;
      final String word = inlineVideoWordAudioHtml('word.mp3');
      String attr(String name) =>
          RegExp('$name="([^"]*)"').firstMatch(word)!.group(1)!;
      final String harness =
          '''
const assert = require('node:assert/strict');
process.on('unhandledRejection', () => { process.exitCode = 3; });
function media(visible) {
  return {
    attrs: {}, plays: 0, pauses: 0, currentTime: 2.5, onended: null,
    offsetParent: visible ? {} : null,
    getAttribute(k) { return this.attrs[k] || null; },
    setAttribute(k, v) { this.attrs[k] = v; },
    play() { this.plays++; return Promise.resolve(); },
    pause() { this.pauses++; },
  };
}
function page(videos, audios, words = []) {
  const lists = {
    'video.fushi-inline-video': videos,
    'audio.fushi-inline-audio': audios,
    'audio.fushi-word-audio': words,
  };
  global.document = {
    querySelectorAll(sel) {
      if (lists[sel]) return lists[sel];
      throw new Error('unexpected selector ' + sel);
    },
    querySelector(sel) {
      if (lists[sel]) return lists[sel][0] || null;
      const started = sel.match(/^(.*)\\[data-fushi-started\\]\$/);
      if (started && lists[started[1]]) {
        return lists[started[1]].find((a) => a.getAttribute('data-fushi-started')) || null;
      }
      throw new Error('unexpected selector ' + sel);
    },
  };
}
const body = new Function(${jsonEncode(videoCanplay)});
const click = new Function('event', ${jsonEncode(onclick)});
const canplay = new Function(${jsonEncode(oncanplay)});
const wordCanplay = new Function(${jsonEncode(attr('oncanplay'))});
const wordError = new Function(${jsonEncode(attr('onerror'))});
const wordClick = new Function('event', ${jsonEncode(attr('onclick'))});
const ev = { stopPropagation() {} };
const tick = () => new Promise((r) => setImmediate(r));

// ① Lapis 背面：Picture 三份（第二份可见），句子音频按钮被复制进两个容器。
const vs = [media(false), media(true), media(false)];
const as = [media(false), media(false)];
page(vs, as);
// 每份副本都会触发 canplay（隐藏的先就绪也一样），重播 seek 后还会再触发一轮。
[vs[2], vs[0], vs[1]].forEach((v) => body.call(v));
vs.forEach((v) => body.call(v));
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
body.call(denied[0]);
const deniedAudio = [media(false)];
deniedAudio[0].play = () => Promise.reject(new Error('NotAllowedError'));
page([], deniedAudio);
canplay.call(deniedAudio[0]);

(async () => {
  // ④ BUG-3442 Lapis 背面带单词音频：先只播单词（两份副本只响一份），播完才播可见片段。
  const v4 = [media(false), media(true), media(false)];
  const s4 = [media(false), media(false)];
  const w4 = [media(false), media(false)];
  page(v4, s4, w4);
  w4.forEach((w) => wordCanplay.call(w));
  s4.forEach((a) => canplay.call(a));
  v4.forEach((v) => body.call(v));
  v4.forEach((v) => body.call(v));
  assert.deepEqual(w4.map((w) => w.plays), [1, 0], 'word audio plays first, once');
  assert.deepEqual(v4.map((v) => v.plays), [0, 0, 0], 'clip waits for the word audio');
  assert.deepEqual(s4.map((a) => a.plays), [0, 0]);
  w4[0].onended();
  assert.deepEqual(v4.map((v) => v.plays), [0, 1, 0], 'clip starts after the word audio ends');
  assert.equal(w4[0].onended, null);
  wordClick(ev);
  assert.equal(w4[0].plays, 2, 'word replay button replays the word');
  assert.equal(w4[0].onended, null, 'word replay must not chain into the clip');
  assert.equal(v4[1].plays, 1);

  // ⑤ 单词还在播时手动重播句子：停掉单词、撤销接续，单词不会稍后再把片段拉一遍。
  const v5 = [media(true)];
  const w5 = [media(false)];
  page(v5, [media(false)], w5);
  body.call(v5[0]);
  assert.equal(typeof w5[0].onended, 'function');
  click(ev);
  assert.equal(w5[0].onended, null);
  assert.equal(w5[0].pauses, 1);
  assert.equal(v5[0].plays, 1);

  // ⑥ 单词文件坏掉（play 被拒但不是 NotAllowedError）：跳过单词照常播片段。
  const v6 = [media(true)];
  const w6 = [media(false)];
  w6[0].play = function () { this.plays++; return Promise.reject(Object.assign(new Error('x'), { name: 'NotSupportedError' })); };
  page(v6, [], w6);
  body.call(v6[0]);
  await tick();
  assert.equal(v6[0].plays, 1, 'broken word audio must not swallow the clip');

  // ⑦ 卡组关了自动播放：单词 play 被拒（NotAllowedError）→ 片段也不硬播、不抛未处理异常。
  const v7 = [media(true)];
  const w7 = [media(false)];
  w7[0].play = function () { this.plays++; return Promise.reject(Object.assign(new Error('x'), { name: 'NotAllowedError' })); };
  page(v7, [], w7);
  body.call(v7[0]);
  await tick();
  assert.equal(v7[0].plays, 0);

  // ⑧ 页面上没有片段（自定义模板把画面放在另一面）：单词先播、播完接句子音频。
  const s8 = [media(false)];
  const w8 = [media(false)];
  page([], s8, w8);
  canplay.call(s8[0]);
  wordCanplay.call(w8[0]);
  wordCanplay.call(w8[0]);
  assert.equal(w8[0].plays, 1);
  assert.equal(s8[0].plays, 0, 'sentence audio yields to the word audio');
  w8[0].onended();
  assert.equal(s8[0].plays, 1, 'sentence audio follows the word audio');

  // ⑨ 无片段且单词文件加载失败：直接放句子，不让整张卡静音。
  const s9 = [media(false)];
  const w9 = [media(false)];
  page([], s9, w9);
  canplay.call(s9[0]);
  wordError.call(w9[0]);
  wordError.call(w9[0]);
  assert.equal(s9[0].plays, 1);
})().catch((e) => { console.error(e); process.exitCode = 1; });
''';
      final ProcessResult result = await Process.run(_nodeExecutable!, <String>[
        '-e',
        harness,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    }, skip: _nodeExecutable == null ? 'node 不在 PATH 上：跳过实跑脚本的用例' : false);
  });

  group('AnkiConnect 同步 WebM 片段落卡', () {
    late Directory dir;
    late File webm;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('fushi_inline_video');
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
                    name: 'Fushi',
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

class _Composer with AnkiNoteComposer {
  Map<String, String> render({
    required String coverPath,
    required String coverRef,
    required Map<String, String> mappings,
    bool synchronized = true,
  }) => renderMediaPayload(
    settings: AnkiSettings(fieldMappings: mappings),
    payload: AnkiMiningPayload(expression: '言葉'),
    context: AnkiMiningContext(
      sentence: 'これは言葉です。',
      coverPath: coverPath,
      sentenceAudioPath: coverPath,
      synchronizedVideo: synchronized,
      source: AnkiMiningSource.video,
    ),
    coverRef: coverRef,
    sentenceAudioRef: null,
    processedAudio: '[sound:fushi_audio_word.mp3]',
    dictionaryMediaTags: const <String, String>{},
  ).fields;
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

/// PATH 上的 node 可执行文件；没有时返回 null，实跑脚本的用例据此 skip（与
/// `fushi/test/anki/exported_glossary_anchor_deeplink_test.dart` 同一判法）。
final String? _nodeExecutable = () {
  final String exe = Platform.isWindows ? 'node.exe' : 'node';
  final String pathEnv = Platform.environment['PATH'] ?? '';
  final String separator = Platform.isWindows ? ';' : ':';
  for (final String dir in pathEnv.split(separator)) {
    if (dir.isEmpty) continue;
    final File candidate = File('$dir${Platform.pathSeparator}$exe');
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}();
