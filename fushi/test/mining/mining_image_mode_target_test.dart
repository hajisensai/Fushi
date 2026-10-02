import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/mining_image_mode_target.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart';

/// [definition] 为 null = 后端读不到模板；[throwOnRead] = 读取失败。
class _Repo implements BaseAnkiRepository {
  _Repo({this.definition, this.throwOnRead = false});

  final AnkiNoteTypeDefinition? definition;
  final bool throwOnRead;
  int reads = 0;

  @override
  Future<AnkiSettings> loadSettings() async => const AnkiSettings(
    selectedNoteTypeId: 1,
    availableNoteTypes: <AnkiNoteType>[
      AnkiNoteType(id: 1, name: 'Target', fields: <String>['Picture']),
    ],
    fieldMappings: <String, String>{'Picture': '{card-image}'},
  );

  @override
  Future<AnkiNoteTypeDefinition?> readNoteTypeDefinition(
    String modelName,
  ) async {
    reads++;
    if (throwOnRead) throw StateError('AnkiConnect unreachable');
    return definition;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AnkiNoteTypeDefinition _withBack(String back) => AnkiNoteTypeDefinition(
  name: 'Target',
  fields: const <String>['Picture'],
  templates: <AnkiCardTemplate>[
    AnkiCardTemplate(name: 'Card 1', front: '', back: back),
  ],
  css: '',
);

void main() {
  test('非片段模式原样返回，不读模板', () async {
    final _Repo repo = _Repo(definition: _withBack(''));
    for (final VideoMiningImageMode mode in VideoMiningImageMode.values) {
      if (mode.isVideoClip) continue;
      expect(await resolveTargetMiningImageMode(mode, repo: repo), mode);
    }
    expect(repo.reads, 0);
  });

  test('模板不原样渲染图片字段 → gif', () async {
    expect(
      await resolveTargetMiningImageMode(
        VideoMiningImageMode.videoClip,
        repo: _Repo(
          definition: _withBack(
            '<template data-field="Picture">{{Picture}}</template>',
          ),
        ),
      ),
      VideoMiningImageMode.gif,
    );
  });

  test('模板原样渲染图片字段 → 保留片段', () async {
    expect(
      await resolveTargetMiningImageMode(
        VideoMiningImageMode.videoClip,
        repo: _Repo(definition: _withBack('<div>{{Picture}}</div>')),
      ),
      VideoMiningImageMode.videoClip,
    );
  });

  test('读不到模板 / 读取失败 → 无法证明不支持，保留片段', () async {
    expect(
      await resolveTargetMiningImageMode(
        VideoMiningImageMode.videoClip,
        repo: _Repo(),
      ),
      VideoMiningImageMode.videoClip,
    );
    expect(
      await resolveTargetMiningImageMode(
        VideoMiningImageMode.videoClip,
        repo: _Repo(throwOnRead: true),
      ),
      VideoMiningImageMode.videoClip,
    );
  });
}
