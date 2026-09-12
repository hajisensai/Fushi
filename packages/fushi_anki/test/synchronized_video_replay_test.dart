import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

void main() {
  test(
    'Lapis delegates user replay once and preserves native autoplay order',
    () async {
      final String back = LapisNoteType.back;
      final int start = back.indexOf('    function addAudioButtons()');
      final int end = back.indexOf('    function getPitchCategories()', start);
      final String function = back
          .substring(start, end)
          .replaceAll(
            '{{ExpressionAudio}}',
            '<a class="replay-button" data-file="word.mp3"></a>',
          )
          .replaceAll(
            '{{SentenceAudio}}',
            '<a class="replay-button" data-file="sentence.mp4"></a>',
          );
      final String onclick = RegExp(
        r'onclick="([^"]*)"',
      ).firstMatch(synchronizedVideoReplayHtml)!.group(1)!;
      final String script =
          '''
const assert = require('node:assert/strict');
let clicks = 0, selection = '', marker = true;
const replay = {click() {clicks++;}};
const containers = [{innerHTML:''}, {innerHTML:''}, {innerHTML:''}];
const sentences = [{addEventListener(type, callback) {this.callback = callback;}}];
global.window = {getSelection() {return selection;}};
global.document = {
  querySelectorAll(selector) {
    return selector.includes('audio-buttons') ? containers : sentences;
  },
  querySelector(selector) {
    if (selector === '.fushi-synced-video-replay') return marker ? {} : null;
    assert.match(selector, /fushi-(?:synced-sentence-media|sentence-audio)/);
    return replay;
  }
};
$function
addAudioButtons();
assert.equal(clicks, 0, 'initialization must leave autoplay to Anki');
for (const container of containers) {
  assert(container.innerHTML.indexOf('word.mp3') < container.innerHTML.indexOf('sentence.mp4'));
  assert.equal((container.innerHTML.match(/sentence.mp4/g) || []).length, 1);
}
const plain = {target: {closest() {return null;}}};
sentences[0].callback(plain);
assert.equal(clicks, 1);
sentences[0].callback({target: {closest() {return {};}}});
assert.equal(clicks, 1, 'native button click must not also trigger sentence replay');
selection = 'selected text'; sentences[0].callback(plain);
assert.equal(clicks, 1, 'selecting sentence text must not start playback');
selection = ''; marker = false; sentences[0].callback(plain);
assert.equal(clicks, 1, 'ordinary sentence audio must retain its behavior');
let stopped = 0;
new Function('event', ${jsonEncode(onclick)})({stopPropagation() {stopped++;}});
assert.equal(clicks, 2);
assert.equal(stopped, 1);
''';
      final ProcessResult result = await Process.run('node', <String>[
        '-e',
        script,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
  );
}
