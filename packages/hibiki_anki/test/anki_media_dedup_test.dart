import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

void main() {
  group('planMediaDedupGroups', () {
    test('哈希相同的分成一组，单文件不产出，输出确定有序', () {
      final List<MediaDedupGroup> groups =
          planMediaDedupGroups(<String, String>{
        'b.jpg': 'h1',
        'a.jpg': 'h1',
        'c.jpg': 'h2',
        'z.png': 'h3',
        'y.png': 'h3',
        'x.png': 'h3',
      });
      expect(groups, hasLength(2));
      expect(groups[0].canonical, 'a.jpg');
      expect(groups[0].duplicates, <String>['b.jpg']);
      expect(groups[1].canonical, 'x.png');
      expect(groups[1].duplicates, <String>['y.png', 'z.png']);
    });
  });

  group('chooseCanonicalMediaName', () {
    test('下划线前缀优先（Anki 不清 _ 前缀的模板资产）', () {
      expect(
        chooseCanonicalMediaName(<String>['aaa.js', '_lib.js', 'shorter.js']),
        '_lib.js',
      );
    });

    test('无下划线时取最短名，平手取字典序', () {
      expect(chooseCanonicalMediaName(<String>['longer-name.jpg', 'ab.jpg']),
          'ab.jpg');
      expect(chooseCanonicalMediaName(<String>['bb.jpg', 'aa.jpg']), 'aa.jpg');
    });
  });

  group('rewriteMediaReferences', () {
    test('覆盖 src= / [sound:] / url() 三种引用形态', () {
      expect(
        rewriteMediaReferences('<img src="a.jpg">', 'a.jpg', 'b.jpg'),
        '<img src="b.jpg">',
      );
      expect(
        rewriteMediaReferences('[sound:a.mp3]', 'a.mp3', 'b.mp3'),
        '[sound:b.mp3]',
      );
      expect(
        rewriteMediaReferences('background: url(a.png);', 'a.png', 'b.png'),
        'background: url(b.png);',
      );
    });

    test('文件名边界安全：不误伤更长的名字', () {
      expect(
        rewriteMediaReferences('<img src="ba.jpg">', 'a.jpg', 'c.jpg'),
        '<img src="ba.jpg">',
      );
      expect(
        rewriteMediaReferences('<img src="a.jpg.bak">', 'a.jpg', 'c.jpg'),
        '<img src="a.jpg.bak">',
      );
      // 正则元字符文件名不炸。
      expect(
        rewriteMediaReferences('<img src="a(1).jpg">', 'a(1).jpg', 'c.jpg'),
        '<img src="c.jpg">',
      );
    });

    test('同名/无命中时原样返回', () {
      expect(rewriteMediaReferences('x', 'a.jpg', 'a.jpg'), 'x');
      expect(rewriteMediaReferences('nothing here', 'a.jpg', 'b.jpg'),
          'nothing here');
    });
  });

  group('shouldRunPeriodicMediaDedup', () {
    const int day = 24 * 60 * 60 * 1000;

    test('从未跑过 → 到期', () {
      expect(shouldRunPeriodicMediaDedup(lastRunMs: null, nowMs: 0), isTrue);
    });

    test('不满 7 天不跑，满 7 天跑', () {
      expect(
        shouldRunPeriodicMediaDedup(lastRunMs: 0, nowMs: 6 * day),
        isFalse,
      );
      expect(
        shouldRunPeriodicMediaDedup(lastRunMs: 0, nowMs: 7 * day),
        isTrue,
      );
    });
  });

  group('AnkiSettings 媒体去重字段', () {
    test('默认开启 + JSON 往返', () {
      const AnkiSettings fresh = AnkiSettings();
      expect(fresh.mediaDedupAutoEnabled, isTrue);
      expect(fresh.lastMediaDedupAtMs, isNull);

      final AnkiSettings round = AnkiSettings.fromJson(fresh
          .copyWith(mediaDedupAutoEnabled: false, lastMediaDedupAtMs: 123)
          .toJson());
      expect(round.mediaDedupAutoEnabled, isFalse);
      expect(round.lastMediaDedupAtMs, 123);
    });
  });
}
