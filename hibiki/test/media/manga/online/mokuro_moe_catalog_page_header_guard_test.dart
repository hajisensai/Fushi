import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _navigationBranch(String source) {
  final int branchStart = source.indexOf('if (navigation != null)');
  if (branchStart < 0) return '';
  final int branchEnd = source.indexOf(
    'return FushiPageHeader(',
    branchStart,
  );
  if (branchEnd <= branchStart) return '';
  return source.substring(branchStart, branchEnd);
}

bool _preservesSelectedSeriesIdentity(String branch) {
  return branch.contains('snapshot.seriesName') &&
      branch.contains('Text(') &&
      branch.contains('seriesName');
}

void main() {
  test('segmented catalog header keeps selected Mokuro series identity', () {
    final String source = File(
      'lib/src/media/manga/online/mokuro_moe_catalog_page.dart',
    ).readAsStringSync();
    final String branch = _navigationBranch(source);

    expect(branch, isNotEmpty);
    expect(
      _preservesSelectedSeriesIdentity(branch),
      isTrue,
      reason: '进入系列后，导航同行化不能丢掉 snapshot.seriesName',
    );

    final String mutant = branch.replaceFirst('snapshot.seriesName', 'null');
    expect(
      _preservesSelectedSeriesIdentity(mutant),
      isFalse,
      reason: '移除系列身份的 mutation 必须把守卫杀红',
    );
  });
}
