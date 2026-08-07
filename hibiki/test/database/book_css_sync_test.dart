/// per-book CSS 跨端同步（LWW by updatedAt）DB 层测试：mergeRemoteBookCss 取较新、
/// 重置墓碑传播、忽略更旧、幂等。
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

FushiDatabase _memDb() => FushiDatabase.forTesting(NativeDatabase.memory());

void main() {
  late FushiDatabase db;
  setUp(() => db = _memDb());
  tearDown(() => db.close());

  test('远端更新内容 → 本地采用并回报变化', () async {
    final changed = await db.mergeRemoteBookCss('BookA', {
      'style.css': (content: 'body{color:red}', deleted: false, updatedAt: 100),
    });
    expect(changed, hasLength(1));
    expect(changed.single.relativePath, 'style.css');
    expect(changed.single.content, 'body{color:red}');
    expect(changed.single.deleted, isFalse);
    final rows = await db.getBookCssRows('BookA');
    expect(rows.single.content, 'body{color:red}');
    expect(rows.single.updatedAt, 100);
  });

  test('本地更新 → 远端更旧被忽略（保留本地、不回报变化）', () async {
    await db.upsertBookCss('BookA', 'style.css', 'LOCAL', 200);
    final changed = await db.mergeRemoteBookCss('BookA', {
      'style.css': (content: 'OLD', deleted: false, updatedAt: 100),
    });
    expect(changed, isEmpty);
    expect((await db.getBookCssRows('BookA')).single.content, 'LOCAL');
  });

  test('远端更新的重置墓碑(deleted) → 本地标记重置并传播', () async {
    await db.upsertBookCss('BookA', 'style.css', 'LOCAL', 100);
    final changed = await db.mergeRemoteBookCss('BookA', {
      'style.css': (content: '', deleted: true, updatedAt: 200),
    });
    expect(changed.single.deleted, isTrue);
    final row = (await db.getBookCssRows('BookA')).single;
    expect(row.deleted, isTrue);
    expect(row.content, '');
    expect(row.updatedAt, 200);
  });

  test('幂等：同一远端快照合并两次，第二次无变化', () async {
    final snap = {
      'a.css': (content: 'X', deleted: false, updatedAt: 100),
    };
    final first = await db.mergeRemoteBookCss('BookA', snap);
    final second = await db.mergeRemoteBookCss('BookA', snap);
    expect(first, hasLength(1));
    expect(second, isEmpty);
  });

  test('相等 updatedAt 不覆盖（防写放大）', () async {
    await db.upsertBookCss('BookA', 'a.css', 'LOCAL', 100);
    final changed = await db.mergeRemoteBookCss('BookA', {
      'a.css': (content: 'REMOTE', deleted: false, updatedAt: 100),
    });
    expect(changed, isEmpty);
    expect((await db.getBookCssRows('BookA')).single.content, 'LOCAL');
  });
}
