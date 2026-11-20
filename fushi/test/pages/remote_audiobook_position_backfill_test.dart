import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';

import '../helpers/interconnect_legacy_host_scope.dart';

/// gap-novelmisc-6：互联下载编排里「拉回 host 端听书断点」三处收成一个函数后的契约。
class _Host extends InterconnectSyncBackend with LegacyInterconnectHostScope {
  _Host() : super.withProbe((String url, String token) async => true);

  final Map<String, ({int positionMs, int updatedAtMs})> audio =
      <String, ({int positionMs, int updatedAtMs})>{};
  Object? error;
  final List<String> asked = <String>[];

  @override
  Future<({int positionMs, int updatedAtMs})> remoteAudiobookPosition(
    String bookKey,
  ) async {
    asked.add(bookKey);
    final Object? e = error;
    if (e != null) throw e;
    return audio[bookKey] ?? (positionMs: 0, updatedAtMs: 0);
  }
}

void main() {
  late FushiDatabase db;
  late _Host host;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    host = _Host();
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> backfill() => backfillRemoteAudiobookPosition(
    client: host,
    database: db,
    remoteKey: 'host-key',
    localKey: 'local-key',
    logSource: 'test.backfill',
  );

  test('用 host 端 key 拉、写本机 key 的断点与时间戳两键', () async {
    host.audio['host-key'] = (positionMs: 4321, updatedAtMs: 99);
    await backfill();
    expect(host.asked, <String>['host-key']);
    expect(
      await db.getPrefTyped<int>(audiobookPositionPrefKey('local-key'), 0),
      4321,
    );
    expect(
      await db.getPrefTyped<int>(audiobookPositionAtPrefKey('local-key'), 0),
      99,
    );
    expect(
      await db.getPrefTyped<int>(audiobookPositionPrefKey('host-key'), -1),
      -1,
    );
  });

  test('host 没有记录不写，本机已有断点保留', () async {
    await db.setPrefTyped<int>(audiobookPositionPrefKey('local-key'), 777);
    await backfill();
    expect(
      await db.getPrefTyped<int>(audiobookPositionPrefKey('local-key'), 0),
      777,
    );
  });

  test('拉取出错记日志后吞掉，不阻断下载', () async {
    host.error = StateError('host down');
    await ErrorLogService.instance.clear();
    await backfill();
    expect(
      ErrorLogService.instance.entries.map((ErrorLogEntry e) => e.source),
      contains('test.backfill'),
    );
  });
}
