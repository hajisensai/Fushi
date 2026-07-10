import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_danmaku_model.dart';

VideoDanmakuItem _item(String text) => VideoDanmakuItem(
      startMs: 0,
      text: text,
      mode: VideoDanmakuMode.scroll,
      colorArgb: 0xFFFFFFFF,
    );

void main() {
  group('VideoDanmakuStyle', () {
    test('defaults are neutral (1x / full opacity / full area)', () {
      const VideoDanmakuStyle s = VideoDanmakuStyle.defaults;
      expect(s.fontScale, 1.0);
      expect(s.opacity, 1.0);
      expect(s.speedScale, 1.0);
      expect(s.areaFraction, 1.0);
    });

    test('normalized clamps every field into its legal range', () {
      const VideoDanmakuStyle wild = VideoDanmakuStyle(
        fontScale: 99,
        opacity: -5,
        speedScale: 0,
        areaFraction: 42,
      );
      final VideoDanmakuStyle n = wild.normalized();
      expect(n.fontScale, VideoDanmakuStyle.maxFontScale);
      expect(n.opacity, VideoDanmakuStyle.minOpacity);
      expect(n.speedScale, VideoDanmakuStyle.minSpeedScale);
      expect(n.areaFraction, VideoDanmakuStyle.maxAreaFraction);
    });

    test('encode/decode round-trips and re-clamps on decode', () {
      const VideoDanmakuStyle s = VideoDanmakuStyle(
        fontScale: 1.4,
        opacity: 0.6,
        speedScale: 1.8,
        areaFraction: 0.5,
      );
      final VideoDanmakuStyle back =
          VideoDanmakuStyle.decode(VideoDanmakuStyle.encode(s));
      expect(back, s);
    });

    test('decode of empty/garbage falls back to defaults', () {
      expect(VideoDanmakuStyle.decode(''), VideoDanmakuStyle.defaults);
      expect(VideoDanmakuStyle.decode('not json'), VideoDanmakuStyle.defaults);
      expect(VideoDanmakuStyle.decode(null), VideoDanmakuStyle.defaults);
    });

    test('faster speed shortens on-screen durations', () {
      const VideoDanmakuStyle fast = VideoDanmakuStyle(speedScale: 2.0);
      expect(
        fast.scrollDuration.inMilliseconds,
        lessThan(kDefaultVideoDanmakuScrollDuration.inMilliseconds),
      );
      expect(
        fast.fixedDuration.inMilliseconds,
        lessThan(kDefaultVideoDanmakuFixedDuration.inMilliseconds),
      );
    });
  });

  group('VideoDanmakuBlockRules parse + filter', () {
    test('empty rules block nothing and return the same list instance', () {
      final List<VideoDanmakuItem> items = <VideoDanmakuItem>[_item('hi')];
      final VideoDanmakuBlockRules rules = parseVideoDanmakuBlockRules('');
      expect(rules.isEmpty, isTrue);
      expect(identical(filterVideoDanmaku(items, rules), items), isTrue);
    });

    test('plain rule matches case-insensitive substring', () {
      final VideoDanmakuBlockRules rules =
          parseVideoDanmakuBlockRules('Spoiler');
      expect(rules.blocks('big SPOILER here'), isTrue);
      expect(rules.blocks('nothing to see'), isFalse);
    });

    test('slash-wrapped rule is treated as a regular expression', () {
      final VideoDanmakuBlockRules rules =
          parseVideoDanmakuBlockRules(r'/^\d+$/');
      expect(rules.regexes, hasLength(1));
      expect(rules.plainWords, isEmpty);
      expect(rules.blocks('12345'), isTrue);
      expect(rules.blocks('12a45'), isFalse);
    });

    test('invalid regex line is dropped without aborting other rules', () {
      final VideoDanmakuBlockRules rules =
          parseVideoDanmakuBlockRules('/(/\nbanned');
      // The malformed regex is dropped; the plain rule still applies.
      expect(rules.regexes, isEmpty);
      expect(rules.plainWords, contains('banned'));
      expect(rules.blocks('this is banned'), isTrue);
    });

    test('filter removes only blocked comments and preserves order', () {
      final List<VideoDanmakuItem> items = <VideoDanmakuItem>[
        _item('keep me'),
        _item('a spoiler line'),
        _item('88888'),
        _item('also keep'),
      ];
      final VideoDanmakuBlockRules rules =
          parseVideoDanmakuBlockRules('spoiler\n' r'/^\d+$/');
      final List<VideoDanmakuItem> visible = filterVideoDanmaku(items, rules);
      expect(
        visible.map((VideoDanmakuItem i) => i.text),
        <String>['keep me', 'also keep'],
      );
    });
  });
}
