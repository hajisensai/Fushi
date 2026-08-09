/// 编排层测试：契约 §2.5 的失败语义（部分失败降级 / 全部失败才抛）与 ID 直取路径。
/// 用假 adapter，**零真实网络**。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_adapter.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_merge.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_service.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_source.dart';

/// 可编程的假 adapter：想返回什么、想抛什么，都由构造参数决定。
class _FakeAdapter implements GalgameMetadataAdapter {
  _FakeAdapter({
    required this.source,
    this.draft,
    this.error,
    this.candidates = const <SourceCandidate>[],
  });

  @override
  final GalgameMetadataSource source;

  final GalgameMetadataDraft? draft;
  final Object? error;
  final List<SourceCandidate> candidates;

  /// 假 adapter 一律用「纯数字即合法 ID」的规则（够覆盖 service 的分支了）。
  final String idPattern = r'^\d+$';

  int fetchCalls = 0;
  int searchCalls = 0;
  bool closed = false;

  @override
  bool validateId(String id) => RegExp(idPattern).hasMatch(id.trim());

  @override
  String externalUrl(String id) => 'https://fake.invalid/${source.key}/$id';

  @override
  Future<GalgameMetadataDraft?> fetchById(String id) async {
    fetchCalls++;
    final Object? err = error;
    if (err != null) {
      // 故意允许抛任意对象：service 的容错要对「adapter 抛了个非 Exception」也成立。
      // ignore: only_throw_errors
      throw err;
    }
    return draft;
  }

  @override
  Future<List<SourceCandidate>> searchByName(String name,
      {int limit = 10}) async {
    searchCalls++;
    return candidates.take(limit).toList(growable: false);
  }

  @override
  void close() => closed = true;
}

const GalgameMetadataDraft _bgmDraft = GalgameMetadataDraft(
  name: 'bgm-name',
  developer: 'bgm-dev',
  rank: 12,
  externalId: '8',
);

const GalgameMetadataDraft _vndbDraft = GalgameMetadataDraft(
  name: 'vndb-name',
  developer: 'vndb-dev',
  averageHours: 30.0,
  externalId: 'v17',
);

GalgameMetadataService _service(Map<GalgameMetadataSource, _FakeAdapter> map) =>
    GalgameMetadataService(
      adapters: Map<GalgameMetadataSource, GalgameMetadataAdapter>.from(map),
    );

void main() {
  group('registry', () {
    test('availableSources 按枚举声明顺序列出已注册源', () {
      final GalgameMetadataService service =
          _service(<GalgameMetadataSource, _FakeAdapter>{
        GalgameMetadataSource.vndb:
            _FakeAdapter(source: GalgameMetadataSource.vndb),
        GalgameMetadataSource.bgm:
            _FakeAdapter(source: GalgameMetadataSource.bgm),
      });
      expect(service.availableSources, <GalgameMetadataSource>[
        GalgameMetadataSource.bgm,
        GalgameMetadataSource.vndb
      ]);
    });

    test('未注册的源抛异常，不静默返回空', () {
      final GalgameMetadataService service =
          _service(<GalgameMetadataSource, _FakeAdapter>{
        GalgameMetadataSource.bgm:
            _FakeAdapter(source: GalgameMetadataSource.bgm),
      });
      expect(
        () => service.adapterFor(GalgameMetadataSource.vndb),
        throwsA(isA<GalgameMetadataException>()),
      );
    });

    test('externalUrl 委托给 adapter；close 传播到所有 adapter', () {
      final _FakeAdapter bgm = _FakeAdapter(source: GalgameMetadataSource.bgm);
      final _FakeAdapter vndb =
          _FakeAdapter(source: GalgameMetadataSource.vndb);
      final GalgameMetadataService service =
          _service(<GalgameMetadataSource, _FakeAdapter>{
        GalgameMetadataSource.bgm: bgm,
        GalgameMetadataSource.vndb: vndb,
      });
      expect(service.externalUrl(GalgameMetadataSource.bgm, '8'),
          'https://fake.invalid/bgm/8');
      service.close();
      expect(bgm.closed, isTrue);
      expect(vndb.closed, isTrue);
    });
  });

  group('searchCandidates', () {
    test('输入即 ID → 跳过搜索直接 fetchById，并包成单条候选', () async {
      final _FakeAdapter bgm = _FakeAdapter(
        source: GalgameMetadataSource.bgm,
        draft: const GalgameMetadataDraft(
          name: 'Fate/stay night',
          nameCn: '命运之夜',
          coverUrl: 'https://bgm.invalid/c.jpg',
          releaseDate: '2004-01-30',
          summary: '简介',
          externalId: '8',
        ),
      );
      final GalgameMetadataService service =
          _service(<GalgameMetadataSource, _FakeAdapter>{
        GalgameMetadataSource.bgm: bgm,
      });

      final List<SourceCandidate> candidates =
          await service.searchCandidates(GalgameMetadataSource.bgm, ' 8 ');
      expect(bgm.fetchCalls, 1);
      expect(bgm.searchCalls, 0);
      expect(candidates, hasLength(1));
      expect(candidates.single.externalId, '8');
      expect(candidates.single.nameCn, '命运之夜');
      expect(candidates.single.summary, '简介');
    });

    test('ID 直取查不到 → 空表', () async {
      final _FakeAdapter bgm = _FakeAdapter(source: GalgameMetadataSource.bgm);
      final GalgameMetadataService service =
          _service(<GalgameMetadataSource, _FakeAdapter>{
        GalgameMetadataSource.bgm: bgm,
      });
      expect(
        await service.searchCandidates(GalgameMetadataSource.bgm, '8'),
        isEmpty,
      );
      expect(bgm.fetchCalls, 1);
    });

    test('非 ID → 走搜索，limit 生效', () async {
      final _FakeAdapter bgm = _FakeAdapter(
        source: GalgameMetadataSource.bgm,
        candidates: const <SourceCandidate>[
          SourceCandidate(
              source: GalgameMetadataSource.bgm, externalId: '8', name: 'A'),
          SourceCandidate(
              source: GalgameMetadataSource.bgm, externalId: '9', name: 'B'),
        ],
      );
      final GalgameMetadataService service =
          _service(<GalgameMetadataSource, _FakeAdapter>{
        GalgameMetadataSource.bgm: bgm,
      });
      expect(
        await service.searchCandidates(GalgameMetadataSource.bgm, 'fate',
            limit: 1),
        hasLength(1),
      );
      expect(bgm.searchCalls, 1);
      expect(bgm.fetchCalls, 0);
    });

    test('空查询不打网络', () async {
      final _FakeAdapter bgm = _FakeAdapter(source: GalgameMetadataSource.bgm);
      final GalgameMetadataService service =
          _service(<GalgameMetadataSource, _FakeAdapter>{
        GalgameMetadataSource.bgm: bgm,
      });
      expect(
        await service.searchCandidates(GalgameMetadataSource.bgm, '  '),
        isEmpty,
      );
      expect(bgm.fetchCalls, 0);
      expect(bgm.searchCalls, 0);
    });
  });

  group('resolveMixed 失败语义（§2.5）', () {
    test('两源都成功 → 合并结果 + 无失败', () async {
      final GalgameMetadataService service =
          _service(<GalgameMetadataSource, _FakeAdapter>{
        GalgameMetadataSource.bgm:
            _FakeAdapter(source: GalgameMetadataSource.bgm, draft: _bgmDraft),
        GalgameMetadataSource.vndb:
            _FakeAdapter(source: GalgameMetadataSource.vndb, draft: _vndbDraft),
      });

      final GalgameMixedResolution result = await service.resolveMixed(
        externalIds: <GalgameMetadataSource, String>{
          GalgameMetadataSource.bgm: '8',
          GalgameMetadataSource.vndb: 'v17',
        },
      );
      expect(result.hasFailures, isFalse);
      expect(result.bySource, hasLength(2));
      expect(result.notFound, isEmpty);
      expect(result.merged.name, 'bgm-name');
      expect(result.merged.developer, 'vndb-dev');
      expect(result.merged.rank, 12);
      expect(result.merged.averageHours, 30.0);
    });

    test('部分源失败 → 降级为该源为空，结果照常返回并带失败原因', () async {
      final GalgameMetadataService service =
          _service(<GalgameMetadataSource, _FakeAdapter>{
        GalgameMetadataSource.bgm: _FakeAdapter(
          source: GalgameMetadataSource.bgm,
          error: const GalgameMetadataException(
            'Bangumi request failed: down',
            source: GalgameMetadataSource.bgm,
          ),
        ),
        GalgameMetadataSource.vndb:
            _FakeAdapter(source: GalgameMetadataSource.vndb, draft: _vndbDraft),
      });

      final GalgameMixedResolution result = await service.resolveMixed(
        externalIds: <GalgameMetadataSource, String>{
          GalgameMetadataSource.bgm: '8',
          GalgameMetadataSource.vndb: 'v17',
        },
      );
      expect(result.hasAnyData, isTrue);
      expect(result.bySource.keys, <GalgameMetadataSource>[
        GalgameMetadataSource.vndb,
      ]);
      expect(result.failures[GalgameMetadataSource.bgm], contains('down'));
      expect(result.merged.name, 'vndb-name');
    });

    test('全部源失败 → 抛异常，消息里带逐源原因', () async {
      final GalgameMetadataService service =
          _service(<GalgameMetadataSource, _FakeAdapter>{
        GalgameMetadataSource.bgm: _FakeAdapter(
          source: GalgameMetadataSource.bgm,
          error: const GalgameMetadataException('bgm down'),
        ),
        GalgameMetadataSource.vndb: _FakeAdapter(
          source: GalgameMetadataSource.vndb,
          error: const GalgameMetadataException('vndb down'),
        ),
      });

      await expectLater(
        service.resolveMixed(
          externalIds: <GalgameMetadataSource, String>{
            GalgameMetadataSource.bgm: '8',
            GalgameMetadataSource.vndb: 'v17',
          },
        ),
        throwsA(
          isA<GalgameMetadataException>().having(
            (GalgameMetadataException e) => e.message,
            'message',
            allOf(contains('bgm down'), contains('vndb down')),
          ),
        ),
      );
    });

    test('非 GalgameMetadataException 的意外异常也被收进 failures，不逃逸', () async {
      final GalgameMetadataService service =
          _service(<GalgameMetadataSource, _FakeAdapter>{
        GalgameMetadataSource.bgm: _FakeAdapter(
          source: GalgameMetadataSource.bgm,
          error: StateError('unexpected'),
        ),
        GalgameMetadataSource.vndb:
            _FakeAdapter(source: GalgameMetadataSource.vndb, draft: _vndbDraft),
      });

      final GalgameMixedResolution result = await service.resolveMixed(
        externalIds: <GalgameMetadataSource, String>{
          GalgameMetadataSource.bgm: '8',
          GalgameMetadataSource.vndb: 'v17',
        },
      );
      expect(
        result.failures[GalgameMetadataSource.bgm],
        contains('unexpected'),
      );
      expect(result.bySource, hasLength(1));
    });

    test('源侧「没这条」不算失败，进 notFound', () async {
      final GalgameMetadataService service =
          _service(<GalgameMetadataSource, _FakeAdapter>{
        GalgameMetadataSource.bgm:
            _FakeAdapter(source: GalgameMetadataSource.bgm),
        GalgameMetadataSource.vndb: _FakeAdapter(
          source: GalgameMetadataSource.vndb,
          error: const GalgameMetadataException('vndb down'),
        ),
      });

      final GalgameMixedResolution result = await service.resolveMixed(
        externalIds: <GalgameMetadataSource, String>{
          GalgameMetadataSource.bgm: '8',
          GalgameMetadataSource.vndb: 'v17',
        },
      );
      // 一个 notFound + 一个失败：不是「全部失败」，所以不抛。
      expect(
          result.notFound, <GalgameMetadataSource>{GalgameMetadataSource.bgm});
      expect(result.failures, hasLength(1));
      expect(result.hasAnyData, isFalse);
      expect(result.merged.isEmpty, isTrue);
    });

    test('空 externalIds → 只剩 custom 覆盖层，不抛', () async {
      final GalgameMetadataService service =
          _service(<GalgameMetadataSource, _FakeAdapter>{
        GalgameMetadataSource.bgm:
            _FakeAdapter(source: GalgameMetadataSource.bgm),
      });
      final GalgameMixedResolution result = await service.resolveMixed(
        externalIds: const <GalgameMetadataSource, String>{},
        custom: const GalgameCustomData(name: '纯手填'),
      );
      expect(result.merged.name, '纯手填');
      expect(result.hasFailures, isFalse);
      expect(result.bySource, isEmpty);
    });

    test('custom 覆盖层在 mixed 结果上生效', () async {
      final GalgameMetadataService service =
          _service(<GalgameMetadataSource, _FakeAdapter>{
        GalgameMetadataSource.bgm:
            _FakeAdapter(source: GalgameMetadataSource.bgm, draft: _bgmDraft),
      });
      final GalgameMixedResolution result = await service.resolveMixed(
        externalIds: <GalgameMetadataSource, String>{
          GalgameMetadataSource.bgm: '8',
        },
        custom: const GalgameCustomData(name: '我改的名', tags: <String>['我的tag']),
      );
      expect(result.merged.name, '我改的名');
      expect(result.merged.tags, <String>['我的tag']);
    });
  });

  group('fetchDraft', () {
    test('透传 adapter 结果', () async {
      final GalgameMetadataService service =
          _service(<GalgameMetadataSource, _FakeAdapter>{
        GalgameMetadataSource.vndb:
            _FakeAdapter(source: GalgameMetadataSource.vndb, draft: _vndbDraft),
      });
      final GalgameMetadataDraft? draft =
          await service.fetchDraft(GalgameMetadataSource.vndb, 'v17');
      expect(draft?.externalId, 'v17');
    });

    test('adapter 异常原样上抛（不吞）', () async {
      final GalgameMetadataService service =
          _service(<GalgameMetadataSource, _FakeAdapter>{
        GalgameMetadataSource.vndb: _FakeAdapter(
          source: GalgameMetadataSource.vndb,
          error: const GalgameMetadataException('vndb down'),
        ),
      });
      await expectLater(
        service.fetchDraft(GalgameMetadataSource.vndb, 'v17'),
        throwsA(isA<GalgameMetadataException>()),
      );
    });
  });
}
