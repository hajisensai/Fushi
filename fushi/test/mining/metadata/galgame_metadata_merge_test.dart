/// 契约 §2.4 逐字段合并优先级 + §1.3 custom 覆盖层的纯函数测试。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_merge.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_source.dart';

/// 两个源都填满、且逐字段取值互不相同的 fixture，便于断言「到底选了谁」。
const GalgameMetadataDraft _bgm = GalgameMetadataDraft(
  name: 'bgm-name',
  nameCn: 'bgm-中文名',
  aliases: <String>['bgm-别名A', '共同别名'],
  allTitles: <String>['bgm-title', '共同标题'],
  summary: 'bgm-简介',
  tags: <String>['bgm-tag', '共同tag'],
  developer: 'bgm-开发商',
  releaseDate: '2004-01-30',
  score: 8.6,
  rank: 12,
  nsfw: true,
  coverUrl: 'https://bgm.invalid/cover.jpg',
  externalId: '8',
);

const GalgameMetadataDraft _vndb = GalgameMetadataDraft(
  name: 'vndb-name',
  nameCn: 'vndb-中文名',
  aliases: <String>['vndb-别名A', '共同别名'],
  allTitles: <String>['vndb-title', '共同标题'],
  summary: 'vndb-简介',
  tags: <String>['vndb-tag', '共同tag'],
  developer: 'vndb-开发商',
  releaseDate: '2000-12-29',
  score: 8.64,
  averageHours: 30.0,
  coverUrl: 'https://vndb.invalid/cover.jpg',
  externalId: 'v17',
);

void main() {
  group('mergeDrafts 优先级（两源都有值）', () {
    final GalgameMetadataDraft merged =
        mergeDrafts(<GalgameMetadataSource, GalgameMetadataDraft>{
      GalgameMetadataSource.bgm: _bgm,
      GalgameMetadataSource.vndb: _vndb,
    });

    test('name / nameCn / summary / releaseDate / score / nsfw 取 bgm', () {
      expect(merged.name, 'bgm-name');
      expect(merged.nameCn, 'bgm-中文名');
      expect(merged.summary, 'bgm-简介');
      expect(merged.releaseDate, '2004-01-30');
      expect(merged.score, 8.6);
      expect(merged.nsfw, isTrue);
    });

    test('developer 反向：取 vndb', () {
      expect(merged.developer, 'vndb-开发商');
    });

    test('coverUrl 默认取 bgm', () {
      expect(merged.coverUrl, 'https://bgm.invalid/cover.jpg');
    });

    test('rank 仅 bgm，averageHours 仅 vndb', () {
      expect(merged.rank, 12);
      expect(merged.averageHours, 30.0);
    });

    test('aliases / tags / allTitles 是并集，去重且保序（bgm 在前）', () {
      expect(merged.aliases, <String>['bgm-别名A', '共同别名', 'vndb-别名A']);
      expect(merged.tags, <String>['bgm-tag', '共同tag', 'vndb-tag']);
      expect(merged.allTitles, <String>['bgm-title', '共同标题', 'vndb-title']);
    });

    test('externalId 恒为 null（合并结果没有单一外部 ID）', () {
      expect(merged.externalId, isNull);
    });
  });

  group('mergeDrafts 单源缺字段时逐字段回退', () {
    test('bgm 缺的标量落到 vndb', () {
      const GalgameMetadataDraft sparseBgm = GalgameMetadataDraft(
        nameCn: 'bgm-中文名',
        rank: 3,
      );
      final GalgameMetadataDraft merged =
          mergeDrafts(<GalgameMetadataSource, GalgameMetadataDraft>{
        GalgameMetadataSource.bgm: sparseBgm,
        GalgameMetadataSource.vndb: _vndb,
      });
      expect(merged.name, 'vndb-name');
      expect(merged.nameCn, 'bgm-中文名');
      expect(merged.summary, 'vndb-简介');
      expect(merged.releaseDate, '2000-12-29');
      expect(merged.score, 8.64);
      expect(merged.coverUrl, 'https://vndb.invalid/cover.jpg');
      expect(merged.rank, 3);
      expect(merged.averageHours, 30.0);
    });

    test('只有 vndb：rank 为空，developer 仍取 vndb', () {
      final GalgameMetadataDraft merged =
          mergeDrafts(<GalgameMetadataSource, GalgameMetadataDraft>{
        GalgameMetadataSource.vndb: _vndb,
      });
      expect(merged.rank, isNull);
      expect(merged.developer, 'vndb-开发商');
      expect(merged.name, 'vndb-name');
    });

    test('只有 bgm：averageHours 为空，developer 回退 bgm', () {
      final GalgameMetadataDraft merged =
          mergeDrafts(<GalgameMetadataSource, GalgameMetadataDraft>{
        GalgameMetadataSource.bgm: _bgm,
      });
      expect(merged.averageHours, isNull);
      expect(merged.developer, 'bgm-开发商');
    });
  });

  group('custom 覆盖层：覆盖 vs 并集两种语义', () {
    test('name / summary / developer / nsfw 是覆盖', () {
      final GalgameMetadataDraft merged = mergeDrafts(
        <GalgameMetadataSource, GalgameMetadataDraft>{
          GalgameMetadataSource.bgm: _bgm,
          GalgameMetadataSource.vndb: _vndb,
        },
        custom: const GalgameCustomData(
          name: '我改的名',
          summary: '我改的简介',
          developer: '我改的开发商',
          nsfw: false,
        ),
      );
      expect(merged.name, '我改的名');
      expect(merged.summary, '我改的简介');
      expect(merged.developer, '我改的开发商');
      expect(merged.nsfw, isFalse);
      // 未被覆盖的字段不受影响。
      expect(merged.nameCn, 'bgm-中文名');
      expect(merged.score, 8.6);
    });

    test('aliases / tags 是并集：源值在前，用户值追加，去重', () {
      final GalgameMetadataDraft merged = mergeDrafts(
        <GalgameMetadataSource, GalgameMetadataDraft>{
          GalgameMetadataSource.bgm: _bgm,
          GalgameMetadataSource.vndb: _vndb,
        },
        custom: const GalgameCustomData(
          aliases: <String>['我的别名', '共同别名'],
          tags: <String>['我的tag', 'bgm-tag'],
        ),
      );
      expect(
        merged.aliases,
        <String>['bgm-别名A', '共同别名', 'vndb-别名A', '我的别名'],
      );
      expect(merged.tags, <String>['bgm-tag', '共同tag', 'vndb-tag', '我的tag']);
    });

    test('coverSource 手选 vndb → 封面取 vndb', () {
      final GalgameMetadataDraft merged = mergeDrafts(
        <GalgameMetadataSource, GalgameMetadataDraft>{
          GalgameMetadataSource.bgm: _bgm,
          GalgameMetadataSource.vndb: _vndb,
        },
        custom: const GalgameCustomData(
          coverSource: GalgameMetadataSource.vndb,
        ),
      );
      expect(merged.coverUrl, 'https://vndb.invalid/cover.jpg');
    });

    test('手选源没有封面 → 回退默认优先级，不留空', () {
      final GalgameMetadataDraft merged = mergeDrafts(
        <GalgameMetadataSource, GalgameMetadataDraft>{
          GalgameMetadataSource.bgm: _bgm,
          GalgameMetadataSource.vndb:
              const GalgameMetadataDraft(name: 'vndb-name'),
        },
        custom: const GalgameCustomData(
          coverSource: GalgameMetadataSource.vndb,
        ),
      );
      expect(merged.coverUrl, 'https://bgm.invalid/cover.jpg');
    });

    test('userRating / userReview 不进 draft（只是「我的评价」）', () {
      final GalgameMetadataDraft merged = mergeDrafts(
        <GalgameMetadataSource, GalgameMetadataDraft>{
          GalgameMetadataSource.bgm: _bgm,
        },
        custom: const GalgameCustomData(userRating: 9.5, userReview: '神作'),
      );
      expect(merged.score, 8.6);
    });
  });

  group('空输入', () {
    test('空 map + 无 custom → 空 draft，不抛', () {
      final GalgameMetadataDraft merged =
          mergeDrafts(const <GalgameMetadataSource, GalgameMetadataDraft>{});
      expect(merged.isEmpty, isTrue);
      expect(merged.externalId, isNull);
    });

    test('空 map + custom → 只剩用户值', () {
      final GalgameMetadataDraft merged = mergeDrafts(
        const <GalgameMetadataSource, GalgameMetadataDraft>{},
        custom: const GalgameCustomData(
          name: '纯手填',
          tags: <String>['手填tag'],
        ),
      );
      expect(merged.name, '纯手填');
      expect(merged.tags, <String>['手填tag']);
      expect(merged.score, isNull);
    });

    test('两个空 draft 合并仍是空 draft', () {
      final GalgameMetadataDraft merged =
          mergeDrafts(<GalgameMetadataSource, GalgameMetadataDraft>{
        GalgameMetadataSource.bgm: const GalgameMetadataDraft(),
        GalgameMetadataSource.vndb: const GalgameMetadataDraft(),
      });
      expect(merged.isEmpty, isTrue);
    });
  });

  group('GalgameCustomData 序列化容错', () {
    test('encode/decode 往返一致', () {
      const GalgameCustomData custom = GalgameCustomData(
        name: '名',
        coverSource: GalgameMetadataSource.vndb,
        aliases: <String>['别名'],
        summary: '简介',
        tags: <String>['标签'],
        developer: '开发商',
        nsfw: false,
        userRating: 8.5,
        userReview: '我的评价',
      );
      final GalgameCustomData back = GalgameCustomData.decode(custom.encode());
      expect(back.name, '名');
      expect(back.coverSource, GalgameMetadataSource.vndb);
      expect(back.aliases, <String>['别名']);
      expect(back.summary, '简介');
      expect(back.tags, <String>['标签']);
      expect(back.developer, '开发商');
      expect(back.nsfw, isFalse);
      expect(back.userRating, 8.5);
      expect(back.userReview, '我的评价');
      expect(back.isEmpty, isFalse);
    });

    test('null / 空串 / 非法 JSON / 非对象 → 空覆盖层', () {
      expect(GalgameCustomData.decode(null).isEmpty, isTrue);
      expect(GalgameCustomData.decode('').isEmpty, isTrue);
      expect(GalgameCustomData.decode('{oops').isEmpty, isTrue);
      expect(GalgameCustomData.decode('[]').isEmpty, isTrue);
    });

    test('未知 coverSource 键降级为 null，其余字段照常解析', () {
      final GalgameCustomData custom = GalgameCustomData.decode(
        '{"coverSource":"ymgal","name":"名","tags":"不是数组"}',
      );
      expect(custom.coverSource, isNull);
      expect(custom.name, '名');
      expect(custom.tags, isEmpty);
    });

    test('空覆盖层的 toJson 是空 map', () {
      expect(const GalgameCustomData().toJson(), isEmpty);
    });
  });
}
