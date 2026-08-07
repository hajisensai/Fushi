/// [GalgameMetadataDraft] / [SourceCandidate] 的容错解析测试：脏 JSON 一律降级，不崩。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_source.dart';

void main() {
  group('GalgameMetadataDraft 序列化', () {
    test('toJson 省略 null 与空表，encode/decode 往返一致', () {
      const GalgameMetadataDraft draft = GalgameMetadataDraft(
        name: '月姫',
        nameCn: '月姬',
        aliases: <String>['Tsukihime'],
        allTitles: <String>['月姫', 'Tsukihime'],
        summary: '简介',
        tags: <String>['吸血鬼'],
        developer: 'TYPE-MOON',
        releaseDate: '2000-12-29',
        score: 8.64,
        rank: 12,
        nsfw: true,
        averageHours: 30.0,
        coverUrl: 'https://example.invalid/cv.jpg',
        externalId: 'v17',
      );

      final Map<String, Object?> json = draft.toJson();
      expect(json.containsKey('name'), isTrue);
      expect(json['score'], 8.64);

      final GalgameMetadataDraft back = GalgameMetadataDraft.decode(
        draft.encode(),
      );
      expect(back.name, '月姫');
      expect(back.nameCn, '月姬');
      expect(back.aliases, <String>['Tsukihime']);
      expect(back.allTitles, <String>['月姫', 'Tsukihime']);
      expect(back.summary, '简介');
      expect(back.tags, <String>['吸血鬼']);
      expect(back.developer, 'TYPE-MOON');
      expect(back.releaseDate, '2000-12-29');
      expect(back.score, 8.64);
      expect(back.rank, 12);
      expect(back.nsfw, isTrue);
      expect(back.averageHours, 30.0);
      expect(back.coverUrl, 'https://example.invalid/cv.jpg');
      expect(back.externalId, 'v17');
    });

    test('空 draft 的 toJson 是空 map，isEmpty 为真', () {
      const GalgameMetadataDraft draft = GalgameMetadataDraft();
      expect(draft.toJson(), isEmpty);
      expect(draft.isEmpty, isTrue);
      expect(draft.encode(), '{}');
    });

    test('只有 externalId 时 isEmpty 仍为真（isEmpty 只看内容字段）', () {
      const GalgameMetadataDraft draft = GalgameMetadataDraft(externalId: '8');
      expect(draft.isEmpty, isTrue);
    });
  });

  group('GalgameMetadataDraft.decode 容错', () {
    test('空串 / 空白串 → 空 draft', () {
      expect(GalgameMetadataDraft.decode('').isEmpty, isTrue);
      expect(GalgameMetadataDraft.decode('   ').isEmpty, isTrue);
    });

    test('非法 JSON / 非对象 JSON → 空 draft，不抛', () {
      expect(GalgameMetadataDraft.decode('{not json').isEmpty, isTrue);
      expect(GalgameMetadataDraft.decode('[1,2,3]').isEmpty, isTrue);
      expect(GalgameMetadataDraft.decode('"just a string"').isEmpty, isTrue);
      expect(GalgameMetadataDraft.decode('null').isEmpty, isTrue);
    });

    test('字段类型全错 → 逐字段降级为 null / 空表，不抛', () {
      final GalgameMetadataDraft draft = GalgameMetadataDraft.fromJson(
        <Object?, Object?>{
          'name': 123,
          'nameCn': <String>['不是字符串'],
          'aliases': 'not a list',
          'allTitles': <String, String>{'k': 'v'},
          'summary': '   ',
          'tags': <Object?>[null, 1, <String>[]],
          'developer': true,
          'releaseDate': '2004',
          'score': 'NaN',
          'rank': 'abc',
          'nsfw': 'maybe',
          'averageHours': double.infinity,
          'coverUrl': '',
          'externalId': <Object?>[],
        },
      );
      expect(draft.name, isNull);
      expect(draft.nameCn, isNull);
      expect(draft.aliases, isEmpty);
      expect(draft.allTitles, isEmpty);
      expect(draft.summary, isNull);
      expect(draft.tags, isEmpty);
      expect(draft.developer, isNull);
      expect(draft.releaseDate, isNull);
      expect(draft.score, isNull);
      expect(draft.rank, isNull);
      expect(draft.nsfw, isNull);
      expect(draft.averageHours, isNull);
      expect(draft.coverUrl, isNull);
      expect(draft.externalId, isNull);
      expect(draft.isEmpty, isTrue);
    });

    test('数字/布尔的字符串形式被接受，列表去重保序并去空白', () {
      final GalgameMetadataDraft draft = GalgameMetadataDraft.fromJson(
        <Object?, Object?>{
          'score': '8.6',
          'rank': '12',
          'nsfw': 'true',
          'averageHours': 30,
          'aliases': <Object?>[' A ', 'A', 'B', '', null, 'B'],
        },
      );
      expect(draft.score, 8.6);
      expect(draft.rank, 12);
      expect(draft.nsfw, isTrue);
      expect(draft.averageHours, 30.0);
      expect(draft.aliases, <String>['A', 'B']);
    });

    test('nsfw 接受 0/1 数值', () {
      expect(
        GalgameMetadataDraft.fromJson(<Object?, Object?>{'nsfw': 1}).nsfw,
        isTrue,
      );
      expect(
        GalgameMetadataDraft.fromJson(<Object?, Object?>{'nsfw': 0}).nsfw,
        isFalse,
      );
    });
  });

  group('draftDate 只认完整 YYYY-MM-DD', () {
    test('合法日期原样返回', () {
      expect(draftDate('2004-01-30'), '2004-01-30');
    });

    test('半截日期 / 占位串 / 越界月日 → null（排序列不能塞脏值）', () {
      expect(draftDate('2004'), isNull);
      expect(draftDate('2004-01'), isNull);
      expect(draftDate('TBA'), isNull);
      expect(draftDate('unknown'), isNull);
      expect(draftDate('2004-13-01'), isNull);
      expect(draftDate('2004-01-32'), isNull);
      expect(draftDate(20040130), isNull);
      expect(draftDate(null), isNull);
    });
  });

  group('summaryExcerpt', () {
    test('短文本原样返回，长文本截断加省略号', () {
      expect(summaryExcerpt('短'), '短');
      final String long = 'あ' * 260;
      final String? excerpt = summaryExcerpt(long);
      expect(excerpt, isNotNull);
      expect(excerpt!.runes.length, kSourceCandidateSummaryRunes + 1);
      expect(excerpt.endsWith('…'), isTrue);
    });

    test('自定义上限；空 / 非字符串 → null', () {
      expect(summaryExcerpt('abcdef', maxRunes: 3), 'abc…');
      expect(summaryExcerpt('   '), isNull);
      expect(summaryExcerpt(42), isNull);
      expect(summaryExcerpt(null), isNull);
    });
  });

  group('SourceCandidate', () {
    test('displayName 优先中文名，其次原名，最后外部 ID', () {
      const SourceCandidate withCn = SourceCandidate(
        source: GalgameMetadataSource.bgm,
        externalId: '8',
        name: 'Fate/stay night',
        nameCn: '命运之夜',
      );
      expect(withCn.displayName, '命运之夜');

      const SourceCandidate onlyName = SourceCandidate(
        source: GalgameMetadataSource.vndb,
        externalId: 'v17',
        name: '月姫',
      );
      expect(onlyName.displayName, '月姫');

      const SourceCandidate bare = SourceCandidate(
        source: GalgameMetadataSource.vndb,
        externalId: 'v17',
      );
      expect(bare.displayName, 'v17');
    });
  });

  group('GalgameMetadataSource.fromKey', () {
    test('合法键解析，大小写与空白容错', () {
      expect(GalgameMetadataSource.fromKey('bgm'), GalgameMetadataSource.bgm);
      expect(
          GalgameMetadataSource.fromKey(' VNDB '), GalgameMetadataSource.vndb);
    });

    test('未知 / 空 / 非字符串 → null', () {
      expect(GalgameMetadataSource.fromKey('ymgal'), isNull);
      expect(GalgameMetadataSource.fromKey(''), isNull);
      expect(GalgameMetadataSource.fromKey(null), isNull);
      expect(GalgameMetadataSource.fromKey(42), isNull);
      expect(GalgameMetadataSource.fromKey('mixed'), isNull);
    });
  });
}
