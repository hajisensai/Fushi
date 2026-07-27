import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

void main() {
  group('planMediaDedupGroups', () {
    test('哈希相同的分成一组，单文件不产出，输出确定有序', () {
      final List<MediaDedupGroup> groups = planMediaDedupGroups(
        <String, String>{
          'b.jpg': 'h1',
          'a.jpg': 'h1',
          'c.jpg': 'h2',
          'z.png': 'h3',
          'y.png': 'h3',
          'x.png': 'h3',
        },
        sizes: <String, int>{
          'b.jpg': 10,
          'a.jpg': 10,
          'c.jpg': 20,
          'z.png': 30,
          'y.png': 30,
          'x.png': 30,
        },
      );
      expect(groups, hasLength(2));
      expect(groups[0].canonical, 'a.jpg');
      expect(groups[0].duplicates, <String>['b.jpg']);
      expect(groups[1].canonical, 'x.png');
      expect(groups[1].duplicates, <String>['y.png', 'z.png']);
    });

    test('哈希撞车但字节数不同 → 绝不归为一组', () {
      final List<MediaDedupGroup> groups = planMediaDedupGroups(
        <String, String>{'a.jpg': 'same', 'b.jpg': 'same'},
        sizes: <String, int>{'a.jpg': 10, 'b.jpg': 11},
      );
      expect(groups, isEmpty);
    });

    test('缺字节数的条目直接丢弃（长度未知不判等）', () {
      final List<MediaDedupGroup> groups = planMediaDedupGroups(
        <String, String>{'a.jpg': 'h', 'b.jpg': 'h'},
        sizes: <String, int>{'a.jpg': 10},
      );
      expect(groups, isEmpty);
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

  group('textReferencesMediaName', () {
    test('CSS url() / @import / 相对引用都算引用', () {
      expect(
          textReferencesMediaName('src: url(_f.woff2);', '_f.woff2'), isTrue);
      expect(
          textReferencesMediaName("@import '_base.css';", '_base.css'), isTrue);
      expect(textReferencesMediaName('url("./_f.woff2")', '_f.woff2'), isTrue);
    });

    test('边界安全：更长的名字不算引用', () {
      expect(textReferencesMediaName('url(_f.woff2.bak)', '_f.woff2'), isFalse);
      expect(textReferencesMediaName('url(x_f.woff2)', '_f.woff2'), isFalse);
    });
  });

  group('isReferencingMediaFile', () {
    test('只把会引用别人的文本格式算进扫描面', () {
      expect(isReferencingMediaFile('_style.CSS'), isTrue);
      expect(isReferencingMediaFile('a.js'), isTrue);
      expect(isReferencingMediaFile('a.svg'), isTrue);
      expect(isReferencingMediaFile('a.jpg'), isFalse);
      expect(isReferencingMediaFile('a.woff2'), isFalse);
      expect(isReferencingMediaFile('noext'), isFalse);
      expect(isReferencingMediaFile('trailing.'), isFalse);
    });
  });

  group('AnkiMediaDedupReport', () {
    test('数量与字节数从明细派生，JSON 带逐条清单', () {
      const AnkiMediaDedupReport report = AnkiMediaDedupReport(
        dryRun: true,
        groupCount: 1,
        deletions: <MediaDedupDeletion>[
          MediaDedupDeletion(filename: 'b.jpg', canonical: 'a.jpg', bytes: 30),
          MediaDedupDeletion(filename: 'c.jpg', canonical: 'a.jpg', bytes: 12),
        ],
        notesRewritten: 2,
        modelsRewritten: 0,
        skipped: 1,
      );
      expect(report.duplicatesRemoved, 2);
      expect(report.bytesSaved, 42);
      expect(report.toJson()['deletions'], hasLength(2));
    });
  });

  group('AnkiSettings 媒体去重字段', () {
    // 用户后来要求「加一个可以打开的自动处理」，所以开关存在——但**默认必须
    // 是关的**（方案 A 的核心：Hibiki 不主动帮你省空间），而且「自动直接删除」
    // 是独立的第二个开关，打开自动处理不等于授权自动删。
    test('两个自动开关默认都关，时刻字段默认为空', () {
      const AnkiSettings fresh = AnkiSettings();
      expect(fresh.lastMediaDedupAtMs, isNull);
      expect(fresh.lastMediaDedupScanAtMs, isNull);
      expect(fresh.mediaDedupAutoEnabled, isFalse);
      expect(fresh.mediaDedupAutoDelete, isFalse);
    });

    test('JSON 往返保住开关状态；旧 JSON 缺键回落到关', () {
      const AnkiSettings fresh = AnkiSettings();
      final AnkiSettings round = AnkiSettings.fromJson(fresh
          .copyWith(
            lastMediaDedupAtMs: 123,
            lastMediaDedupScanAtMs: 456,
            mediaDedupAutoEnabled: true,
            mediaDedupAutoDelete: true,
          )
          .toJson());
      expect(round.lastMediaDedupAtMs, 123);
      expect(round.lastMediaDedupScanAtMs, 456);
      expect(round.mediaDedupAutoEnabled, isTrue);
      expect(round.mediaDedupAutoDelete, isTrue);

      final AnkiSettings legacy = AnkiSettings.fromJson(<String, dynamic>{
        'lastMediaDedupAtMs': 7,
      });
      expect(legacy.lastMediaDedupAtMs, 7);
      expect(legacy.mediaDedupAutoEnabled, isFalse);
      expect(legacy.mediaDedupAutoDelete, isFalse);
    });
  });
}
