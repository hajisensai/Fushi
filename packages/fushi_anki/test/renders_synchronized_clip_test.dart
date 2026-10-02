import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// 设置与模板出自同一个后端的最小仓库。
class _Repo extends BaseAnkiRepository {
  _Repo({this.editable = true, this.selected = true, this.definition});

  final bool editable;
  final bool selected;
  final AnkiNoteTypeDefinition? definition;
  final List<String> reads = <String>[];

  @override
  bool get supportsNoteTypeEditing => editable;

  @override
  Future<AnkiSettings> loadSettings() async => AnkiSettings(
    selectedNoteTypeId: selected ? 1 : null,
    availableNoteTypes: const <AnkiNoteType>[
      AnkiNoteType(id: 1, name: 'Target', fields: <String>['Picture']),
    ],
    fieldMappings: const <String, String>{'Picture': '{card-image}'},
  );

  @override
  Future<AnkiNoteTypeDefinition?> readNoteTypeDefinition(
    String modelName,
  ) async {
    reads.add(modelName);
    return definition;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AnkiNoteTypeDefinition _def(List<String> backs) => AnkiNoteTypeDefinition(
  name: 'Target',
  fields: const <String>['Picture'],
  templates: <AnkiCardTemplate>[
    for (final String back in backs)
      AnkiCardTemplate(name: 'Card', front: '', back: back),
  ],
  css: '',
);

void main() {
  test('读选中笔记类型的模板并按判据回答', () async {
    final _Repo raw = _Repo(
      definition: _def(<String>['<div>{{Picture}}</div>']),
    );
    expect(await raw.rendersSynchronizedClip(), isTrue);
    expect(raw.reads, <String>['Target']);

    final _Repo kiku = _Repo(
      definition: _def(<String>[
        '<template data-field="Picture">{{Picture}}</template>',
      ]),
    );
    expect(await kiku.rendersSynchronizedClip(), isFalse);
  });

  test('读不到就是未知：不支持读模板 / 没选笔记类型 / 无定义 / 空模板列表', () async {
    final _Repo readOnly = _Repo(
      editable: false,
      definition: _def(<String>['x']),
    );
    expect(await readOnly.rendersSynchronizedClip(), isNull);
    expect(readOnly.reads, isEmpty);

    final _Repo noSelection = _Repo(
      selected: false,
      definition: _def(<String>['x']),
    );
    expect(await noSelection.rendersSynchronizedClip(), isNull);
    expect(noSelection.reads, isEmpty);

    expect(await _Repo().rendersSynchronizedClip(), isNull);
    // AnkiDroid 游标为空时回空模板列表——不能当成「模板不渲染」去降级。
    expect(
      await _Repo(definition: _def(<String>[])).rendersSynchronizedClip(),
      isNull,
    );
  });
}
