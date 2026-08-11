import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/tags/tag_drop.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// 拖标签落库失败不再静默的守卫。
///
/// 五个调用点（书 / 字幕书 / 视频 / 书架合集 / 视频合集）此前各抄一遍
/// 「查重 → 幂等提示 → 落库 → 成功提示」，且**都没有 try/catch**，又都以 unawaited
/// Future 挂在 `onTagDropped` 这个 `void` 回调上。写失败时异常直接漂进 zone，用户
/// 看到的是「拖了没反应」——而在这个交互里，「拖了没反应」恰恰又是**成功幂等**
/// （标签本来就在）的样子。他会以为打上了，实际一个都没写进去。
const BookTagRow _tag = BookTagRow(
  id: 7,
  name: 'fav',
  colorValue: 0,
  sortOrder: 0,
  createdAt: 0,
);

void main() {
  test('未打过 → 落库并返回 added，且不发任何提示', () async {
    final List<(String, ToastSeverity)> told = <(String, ToastSeverity)>[];
    int writes = 0;

    final TagAddOutcome outcome = await addTagToTarget(
      tag: _tag,
      isAlreadyTagged: () async => false,
      addToDb: () async => writes += 1,
      alreadyTaggedMessage: 'already',
      notify: (String message, ToastSeverity severity) =>
          told.add((message, severity)),
    );

    expect(outcome, TagAddOutcome.added);
    expect(writes, 1);
    // 成功提示归调用方（要 `mounted` 才能报），这里只确认没有多余提示。
    expect(told, isEmpty);
  });

  test('已打过 → 不落库、给 warning 提示、返回 alreadyPresent', () async {
    final List<(String, ToastSeverity)> told = <(String, ToastSeverity)>[];
    int writes = 0;

    final TagAddOutcome outcome = await addTagToTarget(
      tag: _tag,
      isAlreadyTagged: () async => true,
      addToDb: () async => writes += 1,
      alreadyTaggedMessage: 'already',
      notify: (String message, ToastSeverity severity) =>
          told.add((message, severity)),
    );

    expect(outcome, TagAddOutcome.alreadyPresent);
    expect(writes, 0, reason: '已存在时不该再写一次');
    expect(told, <(String, ToastSeverity)>[('already', ToastSeverity.warning)]);
  });

  test('落库抛出 → 不外泄、给 error 提示、返回 failed', () async {
    final List<(String, ToastSeverity)> told = <(String, ToastSeverity)>[];

    final TagAddOutcome outcome = await addTagToTarget(
      tag: _tag,
      isAlreadyTagged: () async => false,
      addToDb: () async => throw StateError('db locked'),
      alreadyTaggedMessage: 'already',
      notify: (String message, ToastSeverity severity) =>
          told.add((message, severity)),
    );

    expect(outcome, TagAddOutcome.failed);
    expect(told, hasLength(1));
    expect(told.single.$2, ToastSeverity.error,
        reason: '落库失败必须是 error 语义，不能与「已存在」的 warning 混同');
  });

  group('reorderTagsSafely', () {
    test('写成功 → true，且不打扰用户（顺序当场变了就是反馈）', () async {
      final List<(String, ToastSeverity)> told = <(String, ToastSeverity)>[];

      final bool ok = await reorderTagsSafely(
        write: () async {},
        notify: (String message, ToastSeverity severity) =>
            told.add((message, severity)),
      );

      expect(ok, isTrue);
      expect(told, isEmpty);
    });

    test('写失败 → false + error 提示，不外泄', () async {
      final List<(String, ToastSeverity)> told = <(String, ToastSeverity)>[];

      final bool ok = await reorderTagsSafely(
        write: () async => throw StateError('db locked'),
        notify: (String message, ToastSeverity severity) =>
            told.add((message, severity)),
      );

      expect(ok, isFalse, reason: '返回 false 才能让调用方跳过 invalidate，不把没落库的顺序当成已生效');
      expect(told.single.$2, ToastSeverity.error);
    });
  });

  test('查重本身抛出 → 一样归 failed 并提示，绝不当成「没打过」硬写', () async {
    final List<(String, ToastSeverity)> told = <(String, ToastSeverity)>[];
    int writes = 0;

    final TagAddOutcome outcome = await addTagToTarget(
      tag: _tag,
      isAlreadyTagged: () async => throw StateError('read failed'),
      addToDb: () async => writes += 1,
      alreadyTaggedMessage: 'already',
      notify: (String message, ToastSeverity severity) =>
          told.add((message, severity)),
    );

    expect(outcome, TagAddOutcome.failed);
    expect(writes, 0);
    expect(told.single.$2, ToastSeverity.error);
  });
}
