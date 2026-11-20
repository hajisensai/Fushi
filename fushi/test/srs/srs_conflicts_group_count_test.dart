// BUG-4949（反馈 3sGnx0FYRr）：同步冲突页每条卡片显示「同类」组条数，早先 build 里对每条卡片
// 各扫一遍整张列表（O(N²)），扣住的删除上万条时一次 build 占住 iOS 主线程好几秒，系统要求退出时
// 5 秒内没响应、被看门狗 0x8BADF00D 杀掉（三份崩溃栈都停在 _sameCount → _heldGroup）。
// 修法：组条数在加载时一趟数完（srsSameGroupCounts），build 只查表。
import 'dart:collection';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_conflict_groups.dart';

/// 记录被遍历了多少个元素的 Iterable：用来断言「只扫一趟」。
class _CountingIterable extends IterableBase<String> {
  _CountingIterable(this._items);

  final List<String> _items;
  int visited = 0;

  @override
  Iterator<String> get iterator => _CountingIterator(this);
}

class _CountingIterator implements Iterator<String> {
  _CountingIterator(this._owner);

  final _CountingIterable _owner;
  int _i = -1;

  @override
  String get current => _owner._items[_i];

  @override
  bool moveNext() {
    _i++;
    if (_i >= _owner._items.length) return false;
    _owner.visited++;
    return true;
  }
}

String _identity(String group) => group;

void main() {
  test('srsSameGroupCounts 按组计数，没出现的组不在表里', () {
    final Map<String, int> counts = srsSameGroupCounts(<String>[
      'held/delete_edit',
      'card/flag',
      'held/delete_edit',
      'held/delete_review',
      'card/flag',
      'held/delete_edit',
    ], _identity);
    expect(counts, <String, int>{
      'held/delete_edit': 3,
      'card/flag': 2,
      'held/delete_review': 1,
    });
    expect(counts['deck/name'], isNull);
    expect(srsSameGroupCounts(const <String>[], _identity), isEmpty);
  });

  test('上万条扣住的删除：数组条数只遍历一趟（线性，不是每条各扫一遍）', () {
    const int n = 20000;
    final _CountingIterable groups = _CountingIterable(<String>[
      for (int i = 0; i < n; i++)
        'held/${i.isEven ? 'delete_edit' : 'delete_review'}',
    ]);
    final Map<String, int> counts = srsSameGroupCounts(groups, _identity);
    // 页面对每条卡片各查一次组条数。
    for (int i = 0; i < n; i++) {
      final String g = 'held/${i.isEven ? 'delete_edit' : 'delete_review'}';
      expect(counts[g], n ~/ 2);
    }
    expect(groups.visited, n);
  });

  test('冲突页 build 路径不再扫列表数同类条数（守卫）', () {
    final String src = File(
      'lib/src/pages/implementations/srs/srs_conflicts_page.dart',
    ).readAsStringSync();
    final RegExpMatch? sameCount = RegExp(
      r'int _sameCount\(String group\)[^;]*;',
    ).firstMatch(src);
    expect(sameCount, isNotNull);
    expect(sameCount![0], isNot(contains('.where(')));
    expect(sameCount[0], contains('_sameCounts['));
    final int body = src.indexOf('Widget _buildBody(BuildContext context)');
    final int end = src.indexOf('\nclass ', body);
    expect(body, greaterThan(0));
    expect(src.substring(body, end), isNot(contains('.where(')));
  });
}
