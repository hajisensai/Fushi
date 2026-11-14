// 设备信任的共用入口（engine srs_devices.dart：app 冲突中心与服务端管理接口走同一条路径，BUG-4306）：真实
// SrsDbStore 两台设备，库非空之后才认识的设备的删除扣住 → 经 srsSetDeviceTrust 确认 → 两端收敛。
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_devices.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:test/test.dart';

import 'support/srs_sync2_peers.dart';
import 'support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000d7a57';

void main() {
  late SrsMemoryLocationStore loc;

  setUp(() => loc = SrsMemoryLocationStore());

  Future<SrsDbStore> device(String id) async {
    final SrsStorage storage = await openTestSrsStorage();
    return SrsDbStore.open(
      db: storage.db,
      core: storage.core,
      profileUid: kProfile,
      deviceId: id,
    );
  }

  Future<String> addNote(SrsDbStore s, String expression) => s.createNote(
    noteTypeId: s.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(kProfile, 'Expression'): expression,
    },
  );

  Future<bool> hidden(SrsDbStore s, String noteId) async =>
      (await s.cardsOfNote(noteId)).single.hidden;

  /// A 先有内容、B 后加入并删掉 A 的笔记：B 在 A 上待确认，删除扣着。
  Future<(SrsDbStore, SrsDbStore, String)> heldOnA() async {
    final SrsDbStore a = await device('trust-a');
    final String noteId = await addNote(a, '魚');
    final SrsDbStore b = await device('trust-b');
    await srsSyncPeers(<SrsDbStore>[a, b], loc);
    expect(await hidden(b, noteId), isFalse);
    await b.deleteNote(noteId);
    await srsSyncPeers(<SrsDbStore>[a, b], loc);
    expect(await hidden(b, noteId), isTrue);
    expect(await hidden(a, noteId), isFalse, reason: 'B 的删除在 A 上扣着');
    return (a, b, noteId);
  }

  test('列出待确认的设备：名字 / 首次出现 / 扣着的删除数；本机与可信设备不在列', () async {
    final (SrsDbStore a, SrsDbStore b, _) = await heldOnA();
    final List<SrsDeviceView> all = await srsLoadDevices(a);
    expect(all.where((SrsDeviceView d) => d.self), hasLength(1));
    final SrsDeviceView pending = srsUntrustedDevices(all).single;
    expect(srsDeviceKey(pending.id), srsDeviceKey(b.sync2Device!));
    expect(pending.trust, SrsDeviceTrust.pending);
    expect(pending.needsTrust, isTrue);
    expect(pending.heldDeletes, 1);
    expect(pending.heldPurges, 0);
    expect(pending.trustSince, isNotNull);
    final Map<String, Object?> json = pending.toJson();
    expect(json['trust'], 'pending');
    expect(json['heldDeletes'], 1);
    expect(json['trustSince'], pending.trustSince);
    // B 是全新库首轮认识的 A：A 在 B 上可信，B 那边没有待确认的设备。
    expect(srsUntrustedDevices(await srsLoadDevices(b)), isEmpty);
  });

  test('信任：扣着的删除立即生效，与作者收敛；设备 ID 大小写 / 连字符不敏感', () async {
    final (SrsDbStore a, SrsDbStore b, String noteId) = await heldOnA();
    final String bareUpper = b.sync2Device!.replaceAll('-', '').toUpperCase();
    final SrsDeviceView after = await srsSetDeviceTrust(
      a,
      bareUpper,
      trust: true,
    );
    expect(after.trust, SrsDeviceTrust.trusted);
    expect(after.heldDeletes, 0);
    expect(await hidden(a, noteId), isTrue);
    expect(srsUntrustedDevices(await srsLoadDevices(a)), isEmpty);
    await srsSyncPeers(<SrsDbStore>[a, b], loc);
    expect(await hidden(a, noteId), isTrue);
    expect(await hidden(b, noteId), isTrue);
    expect(await a.userNoteCount(), await b.userNoteCount());
  });

  test('拒绝：继续扣着、改列为已拒绝；之后改为信任时放行', () async {
    final (SrsDbStore a, SrsDbStore b, String noteId) = await heldOnA();
    final SrsDeviceView rejected = await srsSetDeviceTrust(
      a,
      b.sync2Device!,
      trust: false,
    );
    expect(rejected.trust, SrsDeviceTrust.rejected);
    expect(rejected.needsTrust, isFalse);
    expect(rejected.heldDeletes, 1);
    await srsSyncPeers(<SrsDbStore>[a, b], loc);
    expect(await hidden(a, noteId), isFalse);
    expect(
      srsUntrustedDevices(await srsLoadDevices(a)).single.trust,
      SrsDeviceTrust.rejected,
    );

    await srsSetDeviceTrust(a, b.sync2Device!, trust: true);
    expect(await hidden(a, noteId), isTrue);
    expect(srsUntrustedDevices(await srsLoadDevices(a)), isEmpty);
  });

  test('拒绝执行：不认识的设备 / 本机 / 已可信的设备，不进内核', () async {
    final (SrsDbStore a, SrsDbStore b, _) = await heldOnA();
    Future<SrsDeviceTrustRefusal?> refusal(String id, bool trust) async {
      try {
        await srsSetDeviceTrust(a, id, trust: trust);
        return null;
      } on SrsDeviceTrustException catch (e) {
        return e.refusal;
      }
    }

    expect(
      await refusal('01928c3e-0000-7000-8000-00000000dead', true),
      SrsDeviceTrustRefusal.unknownDevice,
    );
    expect(
      await refusal(a.sync2Device!, true),
      SrsDeviceTrustRefusal.selfDevice,
    );
    await srsSetDeviceTrust(a, b.sync2Device!, trust: true);
    expect(
      await refusal(b.sync2Device!, false),
      SrsDeviceTrustRefusal.alreadyTrusted,
    );
    expect(
      await refusal(b.sync2Device!, true),
      SrsDeviceTrustRefusal.alreadyTrusted,
    );
  });
}
