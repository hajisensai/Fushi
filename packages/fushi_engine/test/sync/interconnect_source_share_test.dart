import 'package:fushi_engine/sync/interconnect_source_share.dart';
import 'package:test/test.dart';

void main() {
  test('配置摘要与键顺序无关、值不同则不同', () {
    final String a = sourceShareConfigDigest(<String, Object?>{
      'id': 'x',
      'nested': <String, Object?>{
        'b': 1,
        'a': <Object?>[1, 'two'],
      },
    });
    final String b = sourceShareConfigDigest(<String, Object?>{
      'nested': <String, Object?>{
        'a': <Object?>[1, 'two'],
        'b': 1,
      },
      'id': 'x',
    });
    expect(a, b);
    expect(
      sourceShareConfigDigest(<String, Object?>{'id': 'y'}),
      isNot(sourceShareConfigDigest(<String, Object?>{'id': 'x'})),
    );
  });

  test('目录逐条容错：坏条目与重复 kind/id 丢弃，版本不认识抛', () {
    final InterconnectSourceShareCatalog catalog =
        InterconnectSourceShareCatalog.fromJson(<String, Object?>{
          'schemaVersion': 1,
          'sources': <Object?>[
            <String, Object?>{
              'kind': 'opds',
              'id': 'a',
              'label': 'A',
              'digest': 'd',
              'config': <String, Object?>{'id': 'a'},
            },
            <String, Object?>{'kind': 'opds', 'id': 'a', 'digest': 'dup'},
            <String, Object?>{'kind': 'opds', 'digest': 'no-id'},
            'junk',
            <String, Object?>{
              'kind': 'musicPlugin',
              'id': 'p',
              'digest': 'pd',
              'signer': 'key',
            },
          ],
        });
    expect(catalog.sources.map((InterconnectSharedSource s) => s.key), <String>[
      'opds/a',
      'musicPlugin/p',
    ]);
    expect(catalog.sources.first.digest, 'd');
    expect(catalog.sources.last.label, 'p');
    expect(catalog.sources.last.signer, 'key');
    final InterconnectSourceShareCatalog round =
        InterconnectSourceShareCatalog.fromJson(catalog.toJson());
    expect(round.sources.first.config, <String, Object?>{'id': 'a'});
    expect(
      () => InterconnectSourceShareCatalog.fromJson(<String, Object?>{
        'schemaVersion': 2,
        'sources': <Object?>[],
      }),
      throwsFormatException,
    );
  });

  test('kinds 与 unavailable 条目往返；没带 kinds 的目录按「什么都没枚举」处理', () {
    final InterconnectSourceShareCatalog catalog =
        InterconnectSourceShareCatalog.fromJson(<String, Object?>{
          'schemaVersion': 1,
          'kinds': <Object?>['opds', 'musicPlugin', 3],
          'sources': <Object?>[
            <String, Object?>{
              'kind': 'musicPlugin',
              'id': 'p',
              'label': 'P',
              'unavailable': true,
            },
          ],
        });
    expect(catalog.kinds, <String>{'opds', 'musicPlugin'});
    expect(catalog.sources.single.unavailable, isTrue);
    expect(catalog.sources.single.digest, isEmpty);
    final InterconnectSourceShareCatalog round =
        InterconnectSourceShareCatalog.fromJson(catalog.toJson());
    expect(round.kinds, catalog.kinds);
    expect(round.sources.single.unavailable, isTrue);
    expect(
      InterconnectSourceShareCatalog.fromJson(<String, Object?>{
        'schemaVersion': 1,
        'sources': <Object?>[],
      }).kinds,
      isEmpty,
    );
  });
}
