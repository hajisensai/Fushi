import 'package:fushi_core/fushi_core.dart';
import 'package:test/test.dart';

/// 一条备份：年龄（小时）+ 大小。
typedef _Item = ({String id, int ageHours, int bytes});

void main() {
  final DateTime now = DateTime.utc(2026, 11, 25, 12);

  List<String> doomed(
    List<_Item> items,
    BackupRetentionPolicy policy, {
    String? protect,
  }) => <String>[
    for (final _Item i in planBackupRetention<_Item>(
      items,
      timestampOf: (_Item i) => now.subtract(Duration(hours: i.ageHours)),
      now: now,
      policy: policy,
      sizeOf: (_Item i) => i.bytes,
      protect: protect == null ? null : (_Item i) => i.id == protect,
    ))
      i.id,
  ];

  test('分层：48 小时全留，之后每天 / 每周 / 每月各留最新一份', () {
    // 每 12 小时一份，覆盖 120 天（新 → 旧）。
    final List<_Item> items = <_Item>[
      for (int h = 0; h <= 120 * 24; h += 12)
        (id: 'h$h', ageHours: h, bytes: 1),
    ];
    final Set<String> gone = doomed(
      items,
      kRestorePointScheduledRetention,
    ).toSet();
    final Set<String> kept = <String>{
      for (final _Item i in items)
        if (!gone.contains(i.id)) i.id,
    };
    // 48 小时内全留（0..48，5 份）。
    for (int h = 0; h <= 48; h += 12) {
      expect(kept, contains('h$h'));
    }
    // 第 3..6 天每天一份：桶里最新的那份（整天数边界上的 72h、96h…）留下，同一天更旧的删。
    expect(kept, contains('h72'));
    expect(gone, contains('h84'));
    // 第 7..27 天每周一份：第 1 周桶最新 = 168h；同周更旧的 180h 删。
    expect(kept, contains('h168'));
    expect(gone, contains('h180'));
    // 第 28..89 天每月一份：第 1 个月桶（30..59 天）最新 = 720h。
    expect(kept, contains('h720'));
    expect(gone, contains('h732'));
    // 超过 90 天的全删。
    expect(gone, contains('h${100 * 24}'));
    expect(kept.length, lessThan(25));
  });

  test('总大小上限从最旧的删起，最新一份与受保护的那份不删', () {
    final List<_Item> items = <_Item>[
      (id: 'a', ageHours: 1, bytes: 4),
      (id: 'b', ageHours: 2, bytes: 4),
      (id: 'c', ageHours: 3, bytes: 4),
      (id: 'd', ageHours: 4, bytes: 4),
    ];
    const BackupRetentionPolicy capped = BackupRetentionPolicy(
      keepMinimum: 1,
      keepAllWithin: Duration(hours: 48),
      maxTotalBytes: 9,
    );
    expect(doomed(items, capped), <String>['c', 'd']);
    // 上限小到连最新一份都装不下：最新一份照留。
    expect(
      doomed(
        items,
        const BackupRetentionPolicy(keepMinimum: 1, maxTotalBytes: 1),
      ),
      <String>['b', 'c', 'd'],
    );
    // 受保护的那份（刚写好的）即使排在旧的位置也不删。
    expect(
      doomed(
        items,
        const BackupRetentionPolicy(
          keepAllWithin: Duration(hours: 48),
          maxTotalBytes: 4,
        ),
        protect: 'd',
      ),
      <String>['a', 'b', 'c'],
    );
  });

  test('Lapis 参数（至少 10 份 + 90 天）与旧行为一致', () {
    final List<_Item> items = <_Item>[
      for (int i = 0; i < 12; i++)
        (id: 'x$i', ageHours: 24 * 100 + i, bytes: 1),
      (id: 'young', ageHours: 24 * 89, bytes: 1),
    ];
    // 排序新 → 旧：young 在最前。
    items.insert(0, items.removeLast());
    const BackupRetentionPolicy lapis = BackupRetentionPolicy(
      keepMinimum: 10,
      keepAllWithin: Duration(days: 90),
    );
    expect(doomed(items, lapis), <String>['x9', 'x10', 'x11']);
    // 时刻读不出的一律保留。
    expect(
      planBackupRetention<int>(
        <int>[for (int i = 0; i < 20; i++) i],
        timestampOf: (int i) => null,
        now: now,
        policy: lapis,
      ),
      isEmpty,
    );
  });
}
