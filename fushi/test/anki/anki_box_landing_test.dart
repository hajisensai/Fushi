import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/anki_sync/anki_box_landing.dart';
import 'package:fushi_engine/anki_sync/pending_mine_relay.dart';
import 'package:fushi_engine/anki_sync/pending_mine_store.dart';
import 'package:fushi_engine/sync/forwarded_mine_payload.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';

/// 互联主机当落地设备：手机把卡经互联同步写进主机磁盘，主机直接对自己的目录跑
/// 同一份中转协议，落进 Anki 后写回执，手机下次同步出队。
///
/// 这里的「手机」用真实的 [PendingMineStore] + [PendingMineRelay]，资产层是
/// 同一块主机目录上的 [LocalDirectoryAssetStore]——与手机经 WebDAV 写进主机时
/// 落盘的位置完全相同（`<sync-data>/fushi-data/__pending_mines__/`）。
void main() {
  late Directory tmp;
  late Directory box;
  late FushiDatabase phoneDb;
  late FushiDatabase hostDb;
  late PendingMineStore phone;
  late PendingMineStore host;
  late List<String> mined;
  late MineOutcome Function() next;

  PendingMineStore storeAt(FushiDatabase db, String name) => PendingMineStore(
    db: () => db,
    root: () async =>
        Directory('${tmp.path}/$name/${PendingMineStore.dirName}'),
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('anki_box_landing');
    box = Directory('${tmp.path}/sync-data/fushi-data')
      ..createSync(recursive: true);
    phoneDb = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    hostDb = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    phone = storeAt(phoneDb, 'phone');
    host = storeAt(hostDb, 'host');
    mined = <String>[];
    next = () => const MineOutcome.success(noteId: 1, deckName: 'Mining');
  });

  tearDown(() async {
    await phoneDb.close();
    await hostDb.close();
    await tmp.delete(recursive: true);
  });

  AnkiBoxLanding landing({int claimedAt = 1000}) => AnkiBoxLanding(
    syncRoot: box,
    store: host,
    deviceId: 'host',
    deviceName: 'NAS',
    landingClaimedAt: () => claimedAt,
    mine: (String raw, AnkiMiningContext context) async {
      mined.add(raw);
      return next();
    },
  );

  Future<PendingMineRelayReport> phoneSync() => PendingMineRelay(
    store: phone,
    deviceId: 'phone',
    deviceName: 'Phone',
    landingClaimedAt: 0,
  ).run(LocalDirectoryAssetStore(box));

  Directory ns() => Directory('${box.path}/${PendingMineRelay.namespace}');

  Set<String> files() => ns().existsSync()
      ? <String>{
          for (final FileSystemEntity e in ns().listSync())
            e.uri.pathSegments.last,
        }
      : <String>{};

  Future<String> phoneMines(String word) => phone.enqueue(
    ForwardedMinePayload(
      rawPayloadJson: '{"expression":"$word"}',
      sentence: '',
    ),
    expression: word,
    reading: '',
  );

  test('手机的卡经主机目录落进 Anki，回执回来后手机出队', () async {
    final String id = await phoneMines('猫');

    // 主机先认领（手机要看到落地设备才上传）。
    await landing().runOnce();
    expect(files(), contains('landing.host.json'));

    expect((await phoneSync()).uploaded, 1);
    expect(files(), contains('$id.json'));

    final AnkiBoxLandingReport r = await landing().runOnce();
    expect(r.received, 1);
    expect(r.delivered, 1);
    expect(mined.single, contains('猫'));
    expect(files(), contains('$id.landed.json'));
    expect(files(), isNot(contains('$id.json')), reason: '落完撤掉记录');
    expect(await host.all(), isEmpty);

    expect((await phoneSync()).acknowledged, 1);
    expect(await phone.all(), isEmpty, reason: '回执回来才出队');
    expect(files(), isNot(contains('$id.landed.json')));
  });

  test('主机没配置 Anki：卡留着等下一轮，不写回执，配置好后再落', () async {
    await landing().runOnce();
    final String id = await phoneMines('猫');
    await phoneSync();

    next = () => const MineOutcome.notConfigured();
    final AnkiBoxLandingReport waiting = await landing().runOnce();
    expect(waiting.waiting, 1);
    expect(files(), isNot(contains('$id.landed.json')));

    next = () => const MineOutcome.success(noteId: 2, deckName: 'Mining');
    final AnkiBoxLandingReport done = await landing().runOnce();
    expect(done.delivered, 1);
    expect(files(), contains('$id.landed.json'));
  });

  test('Anki 里已经有这张卡：按送达处理（写回执）', () async {
    await landing().runOnce();
    final String id = await phoneMines('猫');
    await phoneSync();
    next = () => const MineOutcome.duplicate();
    expect((await landing().runOnce()).delivered, 1);
    expect(files(), contains('$id.landed.json'));
  });

  test('WebDAV 写了一半的记录：本轮跳过、不报错，写完后照常收', () async {
    await landing().runOnce();
    ns().createSync(recursive: true);
    final File half = File('${ns().path}/abc.json')
      ..writeAsStringSync('{"id":"abc","payload":{"rawPay');
    final AnkiBoxLandingReport r = await landing().runOnce();
    expect(r.received, 0);
    expect(mined, isEmpty);

    half.writeAsStringSync(
      '{"id":"abc","createdAt":1,"expression":"猫","reading":"",'
      '"originDeviceId":"phone","payload":{"rawPayloadJson":"{}","sentence":""}}',
    );
    expect((await landing().runOnce()).delivered, 1);
  });

  test('BUG-2778：中转记录里非随附的单词音频（本地路径 / URL）落卡前被剥掉', () async {
    await landing().runOnce();
    File('${ns().path}/evil.json').writeAsStringSync(
      '{"id":"evil","createdAt":1,"expression":"猫","reading":"",'
      '"originDeviceId":"attacker","payload":{"rawPayloadJson":'
      r'"{\"expression\":\"猫\",\"audio\":\"/etc/passwd\"}",'
      '"sentence":""}}',
    );
    expect((await landing().runOnce()).delivered, 1);
    final Map<String, Object?> fields =
        jsonDecode(mined.single) as Map<String, Object?>;
    expect(fields['expression'], '猫');
    expect(fields['audio'], '');
  });

  test('BUG-2778：文件名不合白名单的中转记录直接跳过', () async {
    await landing().runOnce();
    File('${ns().path}/..json').writeAsStringSync(
      '{"id":".","createdAt":1,"expression":"猫","reading":"",'
      '"originDeviceId":"attacker","payload":{"rawPayloadJson":"{}","sentence":""}}',
    );
    final AnkiBoxLandingReport r = await landing().runOnce();
    expect(r.received, 0);
    expect(mined, isEmpty);
  });

  test('别的设备后认领：主机不再是落地设备，不收卡', () async {
    await landing().runOnce();
    File('${ns().path}/landing.desktop.json').writeAsStringSync(
      '{"deviceId":"desktop","deviceName":"PC","claimedAt":2000}',
    );
    await phoneMines('猫');
    await phoneSync(); // 上传给 desktop
    final AnkiBoxLandingReport r = await landing().runOnce();
    expect(r.received, 0);
    expect(mined, isEmpty);
  });

  test('关掉落地：revokeClaim 立刻撤掉主机的认领，手机不再往这里传', () async {
    await landing().runOnce();
    expect(files(), contains('landing.host.json'));
    await landing(claimedAt: 0).revokeClaim();
    expect(files(), isNot(contains('landing.host.json')));
    await phoneMines('猫');
    expect((await phoneSync()).uploaded, 0, reason: '没有落地设备就不上传');
  });
}
