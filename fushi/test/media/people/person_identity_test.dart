import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/people/person_identity.dart';

/// 人物身份图（作品图谱 L5）：只按可靠外部 id 合并，名字相同只作建议。
void main() {
  group('normalizePersonExternalId', () {
    test('各 scheme 规范化与拒收', () {
      expect(normalizePersonExternalId(PersonIdScheme.anidb, ' 167 '), '167');
      expect(normalizePersonExternalId(PersonIdScheme.anidb, '0'), isNull);
      expect(normalizePersonExternalId(PersonIdScheme.mal, 'x1'), isNull);
      expect(normalizePersonExternalId(PersonIdScheme.vndb, 'S566'), 's566');
      expect(normalizePersonExternalId(PersonIdScheme.vndb, '566'), 's566');
      expect(
        normalizePersonExternalId(PersonIdScheme.vndb, 'v17'),
        isNull,
        reason: 'VN id 不是人物 id',
      );
      expect(
        normalizePersonExternalId(
          PersonIdScheme.musicbrainz,
          '0E14DED6-0FAE-474D-869D-5446345F345E',
        ),
        '0e14ded6-0fae-474d-869d-5446345f345e',
      );
      expect(
        normalizePersonExternalId(PersonIdScheme.wikidata, '1155136'),
        'Q1155136',
      );
      expect(
        normalizePersonExternalId(PersonIdScheme.wikidata, 'Q1" } ; DROP'),
        isNull,
        reason: '拼进 SPARQL 前必须挡住注入',
      );
      expect(normalizePersonExternalId('bangumi', '1'), isNull);
    });

    test('provider 名映射只收 AniDB / MAL / TMDB', () {
      expect(personSchemeOfVideoProvider('AniDB'), PersonIdScheme.anidb);
      expect(personSchemeOfVideoProvider('tmdb'), PersonIdScheme.tmdb);
      expect(personSchemeOfVideoProvider('bangumi'), isNull);
    });

    test('parsePersonNode', () {
      expect(parsePersonNode('ref:video:person:anidb:167'), (
        kind: 'ref',
        head: 'video',
        value: 'person:anidb:167',
      ));
      expect(parsePersonNode('id:anidb:167')?.value, '167');
      expect(parsePersonNode('junk'), isNull);
    });
  });

  group('PersonGraph', () {
    final PersonRecord video = PersonRecord(
      domain: PersonRefDomain.video,
      key: 'person:anidb:232',
      name: 'Shitaya Noriko',
      idNodes: <String>[personIdNode(PersonIdScheme.anidb, '232')!],
    );
    final PersonRecord game = PersonRecord(
      domain: PersonRefDomain.game,
      key: 's71',
      name: 'Shitaya Noriko',
      originalName: '下屋 則子',
      idNodes: <String>[
        personIdNode(PersonIdScheme.vndb, 's71')!,
        personIdNode(PersonIdScheme.anidb, '232')!,
        personIdNode(
          PersonIdScheme.musicbrainz,
          '8d41ed72-5c9b-4db8-9253-685f9763ae4d',
        )!,
      ],
    );
    final PersonRecord music = PersonRecord(
      domain: PersonRefDomain.music,
      key: 'artist-1',
      name: '下屋則子',
      idNodes: <String>[
        personIdNode(
          PersonIdScheme.musicbrainz,
          '8d41ed72-5c9b-4db8-9253-685f9763ae4d',
        )!,
      ],
    );
    final PersonRecord namesake = PersonRecord(
      domain: PersonRefDomain.video,
      key: 'person:tmdb:999',
      name: 'Noriko Shitaya',
      idNodes: <String>[personIdNode(PersonIdScheme.tmdb, '999')!],
    );

    test('共享外部 id 跨三域合并；只同名的不合并、进建议', () {
      final PersonGraph g = PersonGraph.build(
        records: <PersonRecord>[video, game, music, namesake],
      );
      final PersonCluster c = g.clusterOf(music.node)!;
      expect(c.records.map((PersonRecord r) => r.node).toSet(), <String>{
        video.node,
        game.node,
        music.node,
      });
      expect(c.displayName, '下屋 則子', reason: '优先游戏侧原文名');
      expect(c.idsOf(PersonIdScheme.vndb), <String>['s71']);
      final List<PersonSuggestion> s = g.suggestionsFor(c);
      expect(s.single.other.records.single.node, namesake.node);
      expect(
        g.clusterOf(namesake.node)!.records,
        hasLength(1),
        reason: '名字相同（段序互换）绝不自动合并',
      );
    });

    test('Wikidata / 手动等价边合并；否决墓碑只压建议', () {
      final PersonGraph bridged = PersonGraph.build(
        records: <PersonRecord>[video, namesake],
        sameAs: <(String, String)>[
          (
            personIdNode(PersonIdScheme.tmdb, '999')!,
            personIdNode(PersonIdScheme.anidb, '232')!,
          ),
        ],
      );
      expect(bridged.clusterOf(video.node)!.records, hasLength(2));

      final PersonGraph rejected = PersonGraph.build(
        records: <PersonRecord>[video, namesake],
        rejected: <(String, String)>[(namesake.node, video.node)],
      );
      expect(rejected.suggestionsFor(rejected.clusterOf(video.node)!), isEmpty);
    });

    test('图里没有的节点返回 null', () {
      final PersonGraph g = PersonGraph.build(records: <PersonRecord>[video]);
      expect(g.clusterOf('ref:music:none'), isNull);
    });
  });

  test('personNameKeys：全角 / 空白 / 段序归一；单字不出键', () {
    expect(personNameKeys('下屋 則子'), contains('下屋則子'));
    expect(
      personNameKeys(
        'Kasahara Hiroko',
      ).intersection(personNameKeys('ＨＩＲＯＫＯ　kasahara')),
      isNotEmpty,
    );
    expect(personNameKeys('A'), isEmpty);
  });
}
