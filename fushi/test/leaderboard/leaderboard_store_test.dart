import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/leaderboard/leaderboard_store.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/leaderboard/leaderboard_identity.dart';
import 'package:fushi_engine/leaderboard/leaderboard_sync.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('lb_store_'));
  tearDown(() => root.deleteSync(recursive: true));

  final String code = LeaderboardIdentity.generate(
    random: Random(5),
  ).toRecoveryCode();

  LeaderboardLocalAccount account() => LeaderboardLocalAccount(
    recoveryCode: code,
    accountId: 'AccountId0000001',
    consentAt: 123,
    serverUrl: 'https://rank.example',
    syncState: const LeaderboardSyncState(
      entries: <String, SyncedEntry>{
        'book:a': SyncedEntry(hash: 'h', workId: 'W1'),
      },
      daily: <String, int>{'2026-09-01': 5},
      shelfCount: 1,
    ),
    lastSyncAt: 999,
    isbnBackfilledAt: 42,
  );

  test('每 Profile 一个文件，写入后读回一致；原子写不留临时文件', () async {
    final LeaderboardStore s1 = LeaderboardStore(
      supportRoot: root,
      profileId: 1,
    );
    final LeaderboardStore s2 = LeaderboardStore(
      supportRoot: root,
      profileId: 2,
    );
    expect(await s1.read(), isNull);
    await s1.write(account());
    expect(s1.file.path, p.join(root.path, 'leaderboard', 'profile_1.json'));
    expect(File('${s1.file.path}.tmp').existsSync(), isFalse);
    expect(await s2.read(), isNull, reason: 'Profile 隔离');

    final LeaderboardLocalAccount back = (await s1.read())!;
    expect(back.recoveryCode, code);
    expect(back.accountId, 'AccountId0000001');
    expect(back.consentAt, 123);
    expect(back.uploadEnabled, isTrue);
    expect(back.serverUrl, 'https://rank.example');
    expect(back.syncState.entries['book:a']!.workId, 'W1');
    expect(back.syncState.daily, <String, int>{'2026-09-01': 5});
    expect(back.syncState.shelfCount, 1);
    expect(back.lastSyncAt, 999);
    expect(back.isbnBackfilledAt, 42);

    // 覆盖写。
    await s1.write(back.copyWith(uploadEnabled: false));
    expect((await s1.read())!.uploadEnabled, isFalse);

    await s1.delete();
    expect(await s1.read(), isNull);
  });

  test('uploadingProfileIds：只认同意上传且没被顶掉的账户文件（BUG-2870）', () async {
    expect(await LeaderboardStore.uploadingProfileIds(root), isEmpty);
    LeaderboardStore s(int id) =>
        LeaderboardStore(supportRoot: root, profileId: id);
    await s(1).write(account());
    await s(2).write(account().copyWith(uploadEnabled: false));
    await s(3).write(account().copyWith(uploadBlockedByOtherDevice: true));
    await s(7).write(account());
    // 临时文件、无关文件、坏文件都不算。
    File(
      p.join(root.path, 'leaderboard', 'profile_9.json.tmp'),
    ).writeAsStringSync('{}');
    File(p.join(root.path, 'leaderboard', 'notes.txt')).writeAsStringSync('x');
    await s(8).file.writeAsString('{');
    expect(await LeaderboardStore.uploadingProfileIds(root), <int>{1, 7});
  });

  test('坏文件视为未开启，日志里不带文件内容（私钥）', () async {
    final LeaderboardStore s = LeaderboardStore(
      supportRoot: root,
      profileId: 3,
    );
    await s.file.parent.create(recursive: true);
    // 截断的 JSON：jsonDecode 的 FormatException 会回显源文本。
    await s.file.writeAsString('{"version":1,"recoveryCode":"$code"');
    final int before = ErrorLogService.instance.entries.length;
    expect(await s.read(), isNull);
    final List<ErrorLogEntry> added = ErrorLogService.instance.entries
        .skip(before)
        .toList();
    expect(added, isNotEmpty);
    for (final ErrorLogEntry e in added) {
      expect(e.error.contains(code), isFalse);
      expect((e.stackTrace ?? '').contains(code), isFalse);
    }

    await s.file.writeAsString(jsonEncode(<String, Object?>{'version': 1}));
    expect(await s.read(), isNull, reason: '缺字段');
  });

  test('只有 syncState 坏：账户照常可用，同步状态退回空（下次 reset 对账）', () async {
    final LeaderboardStore s = LeaderboardStore(
      supportRoot: root,
      profileId: 4,
    );
    final Map<String, Object?> j = account().toJson()
      ..['syncState'] = <String, Object?>{'entries': 7};
    await s.file.parent.create(recursive: true);
    await s.file.writeAsString(jsonEncode(j));
    final LeaderboardLocalAccount back = (await s.read())!;
    expect(back.accountId, 'AccountId0000001');
    expect(back.syncState.neverSynced, isTrue);
  });
}
