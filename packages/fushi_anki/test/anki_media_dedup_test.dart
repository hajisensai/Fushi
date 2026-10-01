import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

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

  // BUG-2824：本地对照表的匹配必须与 Anki `findNotes "<文件名>"` 同口径——
  // 少匹配一处就会把仍被引用的副本删掉。
  group('MediaNameMatcher', () {
    test('朴素子串、大小写不敏感（与 Anki 文本检索一致），报原大小写', () {
      final MediaNameMatcher m = MediaNameMatcher(<String>['a.mp3', 'Pic.PNG']);
      expect(m.namesIn('[sound:A.MP3] <img src="pic.png">'), <String>{
        'a.mp3',
        'Pic.PNG',
      });
      // 子串即命中（不判边界）：交给改写阶段判断「改不动就不删」。
      expect(m.namesIn('[sound:ba.mp3x]'), <String>{'a.mp3'});
      expect(m.namesIn('a.mp4 pic.pn'), isEmpty);
    });

    test('同扩展名、不同长度的名字在同一处都能被认出', () {
      final MediaNameMatcher m = MediaNameMatcher(<String>[
        'b.mp3',
        'ab.mp3',
        'xab.mp3',
        'q.mp3',
      ]);
      expect(m.namesIn('<x>xab.mp3</x>'), <String>{
        'b.mp3',
        'ab.mp3',
        'xab.mp3',
      });
    });

    test('多个点、无扩展名、仅大小写不同的名字', () {
      final MediaNameMatcher m = MediaNameMatcher(<String>[
        'a.b.mp3',
        'noext',
        'Dup.jpg',
        'dup.jpg',
        '',
      ]);
      expect(m.namesIn('a.b.mp3'), <String>{'a.b.mp3'});
      expect(m.namesIn('xx NOEXT yy'), <String>{'noext'});
      expect(m.namesIn('DUP.JPG'), <String>{'Dup.jpg', 'dup.jpg'});
      expect(m.namesIn(''), isEmpty);
    });

    test('namesInAll 合并一条笔记的全部字段', () {
      final MediaNameMatcher m = MediaNameMatcher(<String>['a.mp3', 'b.jpg']);
      expect(
        m.namesInAll(<String>['[sound:a.mp3]', '<img src="b.jpg">']),
        <String>{'a.mp3', 'b.jpg'},
      );
    });

    test('与逐个 contains 的朴素实现结果一致（随机语料对拍）', () {
      final List<String> names = <String>[
        for (int i = 0; i < 300; i++)
          'f${i * 7}_${i % 13}.${<String>['mp3', 'jpg', 'png', 'ogg'][i % 4]}',
      ];
      final MediaNameMatcher m = MediaNameMatcher(names);
      // 固定种子：抽一部分真名（随机改大小写、前后粘上文件名字符）与诱饵
      // （换扩展名 / 截掉一位）混进 HTML 片段。
      final Random rng = Random(2824);
      for (int round = 0; round < 20; round++) {
        final StringBuffer text = StringBuffer();
        for (int k = 0; k < 60; k++) {
          String n = names[rng.nextInt(names.length)];
          switch (rng.nextInt(5)) {
            case 0:
              n = n.toUpperCase();
            case 1:
              n = 'x$n.bak';
            case 2:
              n = n.replaceFirst(RegExp(r'\.\w+$'), '.webm');
            case 3:
              n = n.substring(1);
          }
          text.write(rng.nextBool() ? '<img src="$n">' : '[sound:$n] 釈義');
        }
        final String body = text.toString();
        final Set<String> naive = <String>{
          for (final String n in names)
            if (body.toLowerCase().contains(n.toLowerCase())) n,
        };
        expect(naive, isNotEmpty);
        expect(m.namesIn(body), naive, reason: body);
      }
    });

    test('上万个文件名 × 大字段仍是线性代价（不按名字个数放大）', () {
      final List<String> names = <String>[
        for (int i = 0; i < 20000; i++) 'yomitan_dictionary_media_$i.mp3',
      ];
      final MediaNameMatcher m = MediaNameMatcher(names);
      final String field =
          '${'釈義テキスト' * 20000}[sound:yomitan_dictionary_media_123.mp3]';
      final Stopwatch sw = Stopwatch()..start();
      for (int i = 0; i < 50; i++) {
        expect(m.namesIn(field), <String>{'yomitan_dictionary_media_123.mp3'});
      }
      // 朴素实现是 2 万 × 12 万字符 × 50 次；这里应远低于一秒级。
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });

  group('复核检索式', () {
    test('有改写笔记时限定在 edited 或这些 nid 上，文件名逐个加引号 OR', () {
      expect(
        mediaDedupRecheckQuery(
          <String>['a.mp3', 'b c.jpg'],
          editedDays: 2,
          noteIds: <int>[30, 10],
        ),
        '(edited:2 OR nid:10,30) ("a.mp3" OR "b c.jpg")',
      );
      expect(
        mediaDedupRecheckQuery(<String>['a.mp3'], editedDays: 3),
        'edited:3 ("a.mp3")',
      );
    });

    test('edited 天数覆盖到建表时刻，跨日界线多看一天', () {
      expect(mediaDedupRecheckEditedDays(Duration.zero), 2);
      expect(mediaDedupRecheckEditedDays(const Duration(hours: 23)), 2);
      expect(mediaDedupRecheckEditedDays(const Duration(hours: 25)), 3);
    });
  });
}
