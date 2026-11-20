// BUG-4950：冲突中心每张卡片的「同类还有几条」过去在 build 里逐卡全表扫（O(n²)），
// 同步扣住几千条删除时一次重建在主线程上跑几秒，iOS 退出被看门狗（0x8BADF00D）杀掉。
// 现在数据载入时一趟算好、build 只查表。
import 'dart:io';

import 'package:test/test.dart';
import 'package:fushi/src/srs/srs_conflict_groups.dart';

void main() {
  test('按组计数正确，groupOf 对每个元素恰好调用一次（线性，不随卡片数平方增长）', () {
    const int n = 5000;
    final List<int> items = <int>[for (int i = 0; i < n; i++) i];
    int calls = 0;
    final Map<String, int> counts = srsSameGroupCounts<int>(items, (int i) {
      calls++;
      return 'held/${i % 3 == 0 ? 'delete_edit' : 'delete_review'}';
    });
    expect(calls, n);
    expect(counts, <String, int>{
      'held/delete_edit': 1667,
      'held/delete_review': 3333,
    });
  });

  test('空列表得空表', () {
    expect(srsSameGroupCounts<String>(<String>[], (String s) => s), isEmpty);
  });

  test('冲突页 build 用的 _sameCount 只查载入时算好的表，不再扫列表', () {
    final String src = File(
      'lib/src/pages/implementations/srs/srs_conflicts_page.dart',
    ).readAsStringSync();
    final RegExp sameCount = RegExp(
      r'int _sameCount\(String group\)\s*=>\s*([^;]*);',
    );
    final RegExpMatch? m = sameCount.firstMatch(src);
    expect(m, isNotNull, reason: '_sameCount 应是一行表达式');
    expect(m!.group(1)!.trim(), '_sameCounts[group] ?? 0');
    expect(
      src.contains('srsSameGroupCounts(held, _heldGroup)') &&
          src.contains(
            'srsSameGroupCounts(conflicts, (_Conflict c) => c.group)',
          ),
      isTrue,
      reason: '扣住的删除与被替换的设置都要在载入时一趟算好组计数',
    );
  });
}
