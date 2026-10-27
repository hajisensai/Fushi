import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/src/ops/ctl_online_filters.dart';

Matcher _status(int status) => throwsA(
  isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', status),
);

const List<MihonFilter> _mihon = <MihonFilter>[
  MihonFilter(name: 'Note', kind: MihonFilterKind.header),
  MihonFilter(name: 'Title', kind: MihonFilterKind.text, state: ''),
  MihonFilter(
    name: 'Status',
    kind: MihonFilterKind.select,
    state: 0,
    values: <String>['All', 'Ongoing', 'Completed'],
  ),
  MihonFilter(
    name: 'Sort',
    kind: MihonFilterKind.sort,
    state: <String, Object?>{'index': 0, 'ascending': true},
    values: <String>['Popular', 'Latest'],
  ),
  MihonFilter(
    name: 'Genre',
    kind: MihonFilterKind.group,
    children: <MihonFilter>[
      MihonFilter(name: 'Action', kind: MihonFilterKind.triState, state: 0),
      MihonFilter(name: 'Comedy', kind: MihonFilterKind.checkBox, state: false),
    ],
  ),
];

void main() {
  group('Mihon 筛选', () {
    test('JSON：1 起层级路径、可设置标记、选项', () {
      final List<Map<String, Object?>> json = ctlMihonFiltersJson(_mihon);
      expect(json[0]['settable'], isFalse);
      expect(json[2]['path'], '3');
      expect(json[2]['options'], <String>['All', 'Ongoing', 'Completed']);
      final List<Object?> children = json[4]['children']! as List<Object?>;
      expect((children[1]! as Map<String, Object?>)['path'], '5.2');
    });

    test('按名字 / 序号赋值，形状同筛选弹窗，未提到的项不动', () {
      final List<MihonFilter> applied =
          applyCtlMihonFilters(_mihon, <String, String>{
            'title': '芙莉莲',
            '3': 'completed',
            'Sort': 'Latest:desc',
            'Genre/Action': 'exclude',
            '5.2': 'on',
          });
      expect(applied[1].state, '芙莉莲');
      expect(applied[2].state, 2);
      expect(applied[3].state, <String, Object?>{
        'index': 1,
        'ascending': false,
      });
      expect(applied[4].children[0].state, 2);
      expect(applied[4].children[1].state, isTrue);
      // 原列表不被改写（const 也改不了，这里断言返回的是新列表）。
      expect(identical(applied, _mihon), isFalse);
      expect(applyCtlMihonFilters(_mihon, <String, String>{})[2].state, 0);
    });

    test('#N 选项与只改排序方向', () {
      final List<MihonFilter> applied = applyCtlMihonFilters(
        _mihon,
        <String, String>{'Status': '#2', 'Sort': ':desc'},
      );
      expect(applied[2].state, 1);
      expect(applied[3].state, <String, Object?>{
        'index': 0,
        'ascending': false,
      });
    });

    test('坏地址 / 坏取值 / 不可设置的项抛 400', () {
      for (final Map<String, String> bad in <Map<String, String>>[
        <String, String>{'Nope': 'x'},
        <String, String>{'9': 'x'},
        <String, String>{'Status': 'Paused'},
        <String, String>{'Status': '#9'},
        <String, String>{'Genre': 'x'},
        <String, String>{'Note': 'x'},
        <String, String>{'Genre/Action': 'maybe'},
        <String, String>{'Genre/Comedy': 'maybe'},
        <String, String>{'Sort': 'Latest:sideways'},
      ]) {
        expect(
          () => applyCtlMihonFilters(_mihon, bad),
          _status(400),
          reason: '$bad',
        );
      }
    });
  });

  group('LNReader 筛选', () {
    final List<LnReaderFilter> filters = <LnReaderFilter>[
      const LnReaderFilter(
        key: 'sort',
        label: 'Sort',
        type: LnReaderFilterType.picker,
        value: 'pop',
        options: <LnReaderFilterOption>[
          LnReaderFilterOption(label: 'Popular', value: 'pop'),
          LnReaderFilterOption(label: 'New', value: 'new'),
        ],
      ),
      const LnReaderFilter(
        key: 'done',
        label: 'Completed only',
        type: LnReaderFilterType.toggle,
        value: false,
      ),
      const LnReaderFilter(
        key: 'genres',
        label: 'Genres',
        type: LnReaderFilterType.excludableCheckbox,
        value: <String, List<String>>{
          'include': <String>[],
          'exclude': <String>[],
        },
        options: <LnReaderFilterOption>[
          LnReaderFilterOption(label: 'Action', value: 'a'),
          LnReaderFilterOption(label: 'Romance', value: 'r'),
        ],
      ),
    ];

    test('按 key / 显示名赋值，传给插件的形状正确', () {
      final List<LnReaderFilter> applied = applyCtlLnReaderFilters(
        filters,
        <String, String>{
          'sort': 'New',
          'completed only': 'yes',
          'genres': 'action,-r',
        },
      );
      expect(lnReaderFilterValues(applied), <String, Object?>{
        'sort': <String, Object?>{'type': 'Picker', 'value': 'new'},
        'done': <String, Object?>{'type': 'Switch', 'value': true},
        'genres': <String, Object?>{
          'type': 'XCheckbox',
          'value': <String, List<String>>{
            'include': <String>['a'],
            'exclude': <String>['r'],
          },
        },
      });
      expect(ctlLnReaderFiltersJson(filters)[0]['options'], hasLength(2));
    });

    test('未知 key / 选项抛 400', () {
      expect(
        () => applyCtlLnReaderFilters(filters, <String, String>{'x': '1'}),
        _status(400),
      );
      expect(
        () => applyCtlLnReaderFilters(filters, <String, String>{'sort': 'Hot'}),
        _status(400),
      );
    });
  });

  group('Mihon 源偏好', () {
    const MihonPreference list = MihonPreference(
      key: 'quality',
      kind: MihonPreferenceKind.list,
      title: 'Quality',
      value: 0,
      entries: <String>['Low', 'High'],
      entryValues: <String>['l', 'h'],
    );
    const MihonPreference multi = MihonPreference(
      key: 'langs',
      kind: MihonPreferenceKind.multiSelect,
      title: 'Languages',
      value: <String>[],
      entries: <String>['Japanese', 'English'],
      entryValues: <String>['ja', 'en'],
    );
    const MihonPreference toggle = MihonPreference(
      key: 'nsfw',
      kind: MihonPreferenceKind.switchControl,
      title: 'NSFW',
      value: false,
    );

    test('取值换成偏好弹窗写出的形状', () {
      expect(ctlMihonPreferenceWithValue(list, 'High').value, 1);
      expect(ctlMihonPreferenceWithValue(list, 'l').value, 0);
      expect(ctlMihonPreferenceWithValue(list, '#2').value, 1);
      expect(ctlMihonPreferenceWithValue(multi, 'english, ja').value, <String>[
        'en',
        'ja',
      ]);
      expect(ctlMihonPreferenceWithValue(multi, '').value, <String>[]);
      expect(ctlMihonPreferenceWithValue(toggle, 'on').value, isTrue);
      final MihonPreference changed = ctlMihonPreferenceWithValue(list, 'h');
      expect(changed.key, 'quality');
      expect(changed.entries, list.entries);
    });

    test('JSON 带 valueLabel；找不到 key 404；坏取值 400；不支持的 422', () {
      expect(
        ctlMihonPreferencesJson(<MihonPreference>[list]).single['valueLabel'],
        'Low',
      );
      expect(
        () => findCtlMihonPreference(<MihonPreference>[list], 'nope'),
        _status(404),
      );
      expect(() => ctlMihonPreferenceWithValue(list, 'Mid'), _status(400));
      expect(() => ctlMihonPreferenceWithValue(toggle, 'maybe'), _status(400));
      expect(
        () => ctlMihonPreferenceWithValue(
          const MihonPreference(
            key: 'x',
            kind: MihonPreferenceKind.unsupported,
            title: 'X',
            value: null,
          ),
          '1',
        ),
        _status(422),
      );
    });
  });
}
