import 'package:test/test.dart';

import 'package:fushi/src/media/import/import_inbox.dart';

/// HBK-AUDIT-019 复审：[ImportInbox.planRootAdoption] 是纯函数，iOS（APFS 区分大小写）
/// 上才可能出现的「只差大小写的两个文件并存」在任何宿主文件系统上都能钉住。
void main() {
  List<String> plan(List<String> root, [List<String> existing = const []]) =>
      ImportInbox.planRootAdoption(rootNames: root, existingNames: existing);

  Set<String> lower(Iterable<String> names) => <String>{
    for (final String n in names) n.toLowerCase(),
  };

  test('只差大小写的两个视频不会被分到同一个目标名（rename 会无声覆盖）', () {
    final List<String> targets = plan(<String>['EP01.mkv', 'ep01.mkv']);
    expect(lower(targets), hasLength(2));
    expect(targets.first, 'EP01.mkv');
  });

  test('只差大小写的两个字幕也不会落到同一个目标名', () {
    final List<String> targets = plan(<String>[
      'EP01.mkv',
      'EP01.srt',
      'ep01.srt',
    ]);
    expect(lower(targets), hasLength(3));
    expect(targets.sublist(0, 2), <String>['EP01.mkv', 'EP01.srt']);
  });

  test('已有条目只差大小写也算占用：整组换 stem，不与旧视频交叉配对', () {
    expect(
      plan(<String>['EP01.mkv', 'EP01.srt'], <String>['ep01.MKV']),
      <String>['EP01 (2).mkv', 'EP01 (2).srt'],
    );
  });

  test('先分配的组占用的名字后面的组也避开', () {
    expect(
      plan(<String>['EP01 (2).mkv', 'EP01.mkv'], <String>['EP01.mkv']),
      <String>['EP01 (2).mkv', 'EP01 (3).mkv'],
    );
  });

  test('结果与输入一一对应、同序', () {
    expect(plan(<String>['b.srt', 'a.mkv', 'b.mkv', 'a.ja.srt']), <String>[
      'b.srt',
      'a.mkv',
      'b.mkv',
      'a.ja.srt',
    ]);
  });
}
