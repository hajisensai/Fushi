import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-685 (TODO-1361 ⑤) guard: the Netflix batch-mining seek→record handoff
/// must gate recording on the seek actually settling at the `<video>` element
/// level AND the video genuinely advancing (currentTime moving), not on a
/// single fixed-delay `v.paused` snapshot.
///
/// Root cause it locks against: the old gate ran `v.play()` then retried only
/// 8×60ms (=480ms) and skipped the sentence if `v.paused` was still true at
/// that one moment. `v.paused === false` is not "playing" (the element can
/// still be `seeking`/frozen), and Netflix's seek→resume latency varies, so
/// recordable sentences were skipped — the video seeked in then immediately
/// seeked out with no clip recorded ("跳转过去以后马上跳转走了，根本没制卡").
///
/// Asserted in BOTH extension mirrors (bundled assets/ + real source tools/);
/// their byte-identity is enforced separately by
/// browser_extension_dict_media_mirror_guard_test.dart.
///
/// flutter test cwd is the hibiki package root.
void main() {
  const Map<String, String> mirrors = <String, String>{
    'assets': 'assets/browser_extension',
    'tools': '../tools/browser-extension',
  };

  mirrors.forEach((String name, String root) {
    test(
        '[$name] batch record gates on seek-settle + advancing, not a '
        'fixed-delay v.paused snapshot', () {
      final String content = File('$root/content.js').readAsStringSync();

      // The fragile 480ms fixed-retry + single v.paused skip must be gone.
      expect(content.contains('for (let i = 0; i < 8 && v.paused'), isFalse,
          reason: '$root content.js must not reintroduce the 480ms fixed-retry '
              'v.paused skip (BUG-685 seek-in-then-out root cause)');

      // Seek must be confirmed settled at the <video> element level.
      expect(content.contains('function hibikiWaitForSeekSettled'), isTrue,
          reason: '$root content.js missing hibikiWaitForSeekSettled helper');
      expect(
          content
              .contains('await hibikiWaitForSeekSettled(v, targetSec, 4000)'),
          isTrue,
          reason: '$root content.js must await seek-settle before recording');
      // Settle judged by "not seeking AND currentTime near target".
      expect(content.contains('!v.seeking'), isTrue,
          reason:
              '$root content.js seek-settle must wait for v.seeking to clear');

      // Recording must wait for the video to genuinely advance.
      expect(content.contains('function hibikiWaitForPlaying'), isTrue,
          reason: '$root content.js missing hibikiWaitForPlaying helper');
      expect(content.contains('const advancing = await hibikiWaitForPlaying'),
          isTrue,
          reason: '$root content.js must gate the clip on the video advancing');
      // The advancing judge must be "currentTime moved past a baseline",
      // NOT merely "!v.paused".
      expect(content.contains('v.currentTime > base + 0.02'), isTrue,
          reason:
              '$root content.js advancing gate must use currentTime progress, '
              'not just v.paused');

      // Ordering: the advancing gate runs BEFORE beginClip (record start).
      final int advancingIdx = content.indexOf('hibikiWaitForPlaying(v, 4000)');
      final int beginClipIdx = content.indexOf("type: 'beginClip'");
      expect(advancingIdx, greaterThan(0),
          reason: '$root content.js missing advancing gate call');
      expect(beginClipIdx, greaterThan(advancingIdx),
          reason: '$root content.js must confirm the video is advancing before '
              'beginClip');

      // A recordable sentence that never advances still fails (BUG-675 path):
      // the skip must be gated on the advancing result, not removed.
      expect(content.contains('if (!advancing) { fail++;'), isTrue,
          reason:
              '$root content.js must still fail-count (not silently drop) a '
              'sentence that never starts advancing (BUG-675 leftover count)');

      // Content-script version marker bumped so a stale cached extension is
      // visibly distinguishable.
      expect(content.contains("data-hibiki-cs', 'v45'"), isTrue,
          reason: '$root content.js version marker must be bumped to v45 '
              '(v44=seek gate, v45=BUG-688 shadow-DOM popup + TODO-1219/1363 subtitle list replay/universal providers)');

      // Adjacent BUG-681 tail-pad fix must remain intact (no regression).
      expect(content.contains('kNfClipTailPadSec'), isTrue,
          reason: '$root content.js must keep the BUG-681 clip tail pad');
    });
  });
}
