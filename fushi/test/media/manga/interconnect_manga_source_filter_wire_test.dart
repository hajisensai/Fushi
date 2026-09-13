/// Mihon 过滤器 ↔ 互联 wire 往返：host 下发定义、client 弹窗改状态、回传给 host
/// 还原成 [MihonFilter] 喂运行时——三段之间不能丢 kind / 选项 / 状态 / 子项。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/interconnect/interconnect_manga_source_host_impl.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';

void main() {
  test('select / checkBox / text / sort / group 往返后逐字段相等', () {
    const List<MihonFilter> original = <MihonFilter>[
      MihonFilter(
        name: 'Genre',
        kind: MihonFilterKind.select,
        state: 2,
        values: <String>['Any', 'Action', 'Comedy'],
      ),
      MihonFilter(
        name: 'Completed',
        kind: MihonFilterKind.checkBox,
        state: true,
      ),
      MihonFilter(name: 'Author', kind: MihonFilterKind.text, state: 'oda'),
      MihonFilter(
        name: 'Order',
        kind: MihonFilterKind.sort,
        state: <String, Object?>{'index': 1, 'ascending': false},
        values: <String>['Latest', 'Popular'],
      ),
      MihonFilter(
        name: 'Tags',
        kind: MihonFilterKind.group,
        children: <MihonFilter>[
          MihonFilter(
            name: 'Isekai',
            kind: MihonFilterKind.checkBox,
            state: false,
          ),
          MihonFilter(name: 'School', kind: MihonFilterKind.triState, state: 1),
        ],
      ),
    ];
    final List<MihonFilter> roundTripped = <MihonFilter>[
      for (final MihonFilter f in original)
        mihonFilterFromWire(mihonFilterToWire(f)),
    ];
    for (int i = 0; i < original.length; i++) {
      final MihonFilter a = original[i];
      final MihonFilter b = roundTripped[i];
      expect(b.name, a.name);
      expect(b.kind, a.kind);
      expect(b.values, a.values);
      if (a.kind == MihonFilterKind.sort) {
        final Map<String, Object?> s = b.state! as Map<String, Object?>;
        expect(s['index'], 1);
        expect(s['ascending'], false);
      } else {
        expect(b.state, a.state);
      }
      expect(b.children.length, a.children.length);
      for (int j = 0; j < a.children.length; j++) {
        expect(b.children[j].name, a.children[j].name);
        expect(b.children[j].kind, a.children[j].kind);
        expect(b.children[j].state, a.children[j].state);
      }
    }
  });
}
