/// 一轮同步里 G8-7b 补上的几步（内核 `gen4/cmd/sync_oldroot.rs`、`gen4/cmd/media_sync.rs`、`cmd/sync.rs`
/// `obsolete_former`）：[srsSync2Round] 按顺序调。
///
/// - [srsSync4TakeOldRoot]：协议 3 旧根 `v3/` 上的段收进本机承袭日志（收完新根之后、发件之前）。
/// - [srsSync4UploadHeritage]：本机承袭日志里位置上缺的区间作为承袭段写到 `v4/devices/<本机>/hrt-…`（先于本机原生段）。
/// - [srsSync4MediaManifestsIn] / [srsSync4MediaManifestsOut]：媒体「在不在」的清单收发（收在发件之前，发在 head 之后）。
/// - [srsSync4SweepFormer]：本机旧身份目录里的旧 head（`obsolete` 回包的 `former`）。
library;

import 'dart:typed_data';

import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsSync2Result;

List<String> _strings(Object? list) => <String>[
  for (final Object? p in (list as List?) ?? const <Object?>[]) p! as String,
];

void _addErrors(SrsSync2Report report, Object? errors, [String prefix = '']) {
  for (final Object? e in (errors as List?) ?? const <Object?>[]) {
    report.errors.add('$prefix$e');
  }
}

/// [paths] 按 [sizeOf] 的大小切成每批不超过 [budgetBytes] 的几批（单个超预算的自成一批），原顺序。
List<List<String>> srsChunkBySize(
  List<String> paths,
  Map<String, int> sizeOf,
  int budgetBytes,
) {
  final List<List<String>> out = <List<String>>[];
  List<String> cur = <String>[];
  int bytes = 0;
  for (final String p in paths) {
    final int n = sizeOf[p] ?? 0;
    if (cur.isNotEmpty && bytes + n > budgetBytes) {
      out.add(cur);
      cur = <String>[];
      bytes = 0;
    }
    cur.add(p);
    bytes += n;
  }
  if (cur.isNotEmpty) out.add(cur);
  return out;
}

/// 捡旧根每个写事务最多做的新工作（内核 `oldroot_ingest` 的 `maxItems`）：与收新根的段同一个取值
/// （`SrsDbStore.kSrsSync2IngestSliceItems`，作答最多等 1～2 s）。旧根段不在中途切，一个事务最多超出一段。
const int kSrsSync4OldRootSliceItems = 256;

/// 捡旧根（设计 §6.2 第 1–4 步；内核 `oldroot_scan` / `oldroot_ingest`）：列 [oldRoot] 的 `devices/` 交内核；清单指纹
/// 没变就什么都不读。变了：先读要学公钥的协议 3 head，再按 [budgetBytes] 分批读段；每批再按
/// [kSrsSync4OldRootSliceItems] 切成几个写事务交内核（回包 `rest` = 交完的段数，剩下的下一个事务再交；`drainMore` =
/// 收尾投递没投完，不带段再交），复习写入在事务之间进得来。每个事务都带这一轮的指纹 `fp`，内核把交完的段的结论记到
/// 它名下（跨事务累计）；段都交完后不带段、带 `settle` 与清单再交一次，内核核对「待读的每段都在这一轮名下有了结论」后
/// 记下指纹（还收不了的段没有结论，下一轮清单不变也照样重读）。围栏由这一轮开头的 `location_root` 写好。落了东西
/// 计进 [SrsSync2Report.applied] / `changed`，逐段没收的原因进 `errors`。
Future<void> srsSync4TakeOldRoot({
  required SrsSync2Host host,
  required SrsLocationStore oldRoot,
  required String locationId,
  required String? keyHex,
  required SrsSync2Report report,
  required int Function() nowMs,
  int budgetBytes = kSrsSync2IngestBudgetBytes,
  int sliceItems = kSrsSync4OldRootSliceItems,
  bool Function()? shouldStop,
  SrsSyncStepCallback? onStep,
}) async {
  onStep?.call('oldRoot list');
  final List<String> dirs = <String>[
    for (final SrsLocationEntry d in await oldRoot.list('devices'))
      if (d.isFolder) 'devices/${d.name}',
  ];
  final List<Map<String, Object?>> listing = <Map<String, Object?>>[
    for (final (String dir, List<SrsLocationEntry> files) in await srsRunPooled(
      dirs,
      kSrsSync2Concurrency,
      (String dir) async => (dir, await oldRoot.list(dir)),
    ))
      for (final SrsLocationEntry f in files)
        if (!f.isFolder)
          <String, Object?>{
            'path': '$dir/${f.name}',
            'size': f.size ?? 0,
            'modified': f.modifiedAt,
          },
  ];
  final Map<String, Object?> first = (await host.sync2Command(<String, Object?>{
    'op': 'oldroot_scan',
    'location': locationId,
    'listing': listing,
  })).map;
  if (first['changed'] != true) return;
  final Object? fp = first['fp'];
  final Map<String, int> sizeOf = <String, int>{
    for (final Map<String, Object?> e in listing)
      e['path']! as String: (e['size'] as int?) ?? 0,
  };
  final List<Uint8List> heads = <Uint8List>[
    for (final Uint8List? b in await srsRunPooled(
      _strings(first['heads']),
      kSrsSync2Concurrency,
      oldRoot.get,
    ))
      ?b,
  ];

  /// 交一个写事务；回包计进报告。
  Future<Map<String, Object?>> step(
    List<String> paths,
    List<Uint8List> blobs, {
    List<Uint8List> heads = const <Uint8List>[],
    bool settle = false,
  }) async {
    final Map<String, Object?> r = (await host.sync2Command(
      <String, Object?>{
        'op': 'oldroot_ingest',
        'location': locationId,
        'fp': fp,
        'paths': paths,
        'heads': heads.length,
        'key': keyHex,
        'now': nowMs(),
        'maxItems': sliceItems,
        if (settle) 'settle': true,
        if (settle) 'listing': listing,
      },
      blobs: <Uint8List>[...heads, ...blobs],
    )).map;
    final int applied = (r['applied'] as int?) ?? 0;
    report.applied += applied;
    report.changed = report.changed || applied > 0;
    _addErrors(report, r['errors'], 'old root: ');
    return r;
  }

  /// 一批（按字节预算切出来的）按 `maxItems` 切成几个事务交完；`drainMore` 时不带段接着交。[settle] = 这是收尾那一次。
  Future<void> ingest(
    List<String> paths, {
    List<Uint8List> heads = const <Uint8List>[],
    bool settle = false,
  }) async {
    final List<Uint8List?> got = await srsRunPooled(
      paths,
      kSrsSync2Concurrency,
      oldRoot.get,
    );
    // 列出来之后被删掉的（旧版本还在写）：不交它；它没有结论，收尾时内核不记指纹，下一轮再核对。
    List<String> rest = <String>[
      for (int i = 0; i < paths.length; i++)
        if (got[i] != null) paths[i],
    ];
    List<Uint8List> blobs = <Uint8List>[for (final Uint8List? b in got) ?b];
    if (rest.isEmpty && heads.isEmpty && !settle) return;
    List<Uint8List> h = heads;
    while (true) {
      final Map<String, Object?> r = await step(
        rest,
        blobs,
        heads: h,
        settle: settle,
      );
      h = const <Uint8List>[];
      final int done = (r['rest'] as int?) ?? rest.length;
      final int spent = (r['spent'] as int?) ?? 0;
      if (done >= rest.length) {
        if (r['drainMore'] != true) return;
        // 收尾投递按片：投递片必有进展，否则契约坏了，不原地打转。
        if (rest.isEmpty && spent == 0) {
          throw StateError('oldroot ingest drain made no progress: $r');
        }
        rest = const <String>[];
        blobs = const <Uint8List>[];
        continue;
      }
      if (done == 0 && spent == 0) {
        throw StateError('oldroot ingest slice made no progress: $r');
      }
      rest = rest.sublist(done);
      blobs = blobs.sublist(done);
    }
  }

  final List<List<String>> chunks = srsChunkBySize(
    _strings(first['fetch']),
    sizeOf,
    budgetBytes,
  );
  // 收段会话：内核把 RWKV 刷新键攒到会话结束（与收新根的段同一套，[SrsSync2Host.sync2IngestBegin]）。
  await host.sync2IngestBegin();
  try {
    for (int i = 0; i < chunks.length; i++) {
      onStep?.call('oldRoot ingest ${i + 1}/${chunks.length}');
      await ingest(chunks[i], heads: i == 0 ? heads : const <Uint8List>[]);
      if (shouldStop?.call() ?? false) return;
    }
    onStep?.call('oldRoot settle');
    await ingest(const <String>[], settle: true);
  } finally {
    await host.sync2IngestEnd();
  }
}

/// 一轮 [listed]（`devices/<设备>` → 文件名）换成内核 `listing` 的形（设备 → 文件名）。
Map<String, List<String>> srsDeviceListing(Map<String, List<String>> listed) =>
    <String, List<String>>{
      for (final MapEntry<String, List<String>> e in listed.entries)
        e.key.substring(e.key.indexOf('/') + 1): e.value,
    };

void _noteWritten(Map<String, List<String>> listed, String path) {
  final int slash = path.lastIndexOf('/');
  final List<String> names = listed.putIfAbsent(
    path.substring(0, slash),
    () => <String>[],
  );
  final String name = path.substring(slash + 1);
  if (!names.contains(name)) names.add(name);
}

/// 承袭上传（D19；内核 `heritage_plan` / `heritage_outbox` / `heritage_ack`）：本机承袭日志（迁移带来的旧历史、捡旧根
/// 收来的）里位置上缺的区间写成承袭段。指纹（位置上的承袭段文件名 + 本机各承袭日志的末尾与已清除条数）没变就什么都
/// 不读；变了才读位置上与本机承袭日志相关的承袭段、交内核打包要传的。全部写上、且没有传不上去的地方（`blocked` /
/// `keptForked`，报进 `errors`）才 `heritage_ack` 记指纹。[listed] 随写上的文件更新（之后的发件 / 清理用同一份）。
Future<void> srsSync4UploadHeritage({
  required SrsSync2Host host,
  required SrsLocationStore location,
  required String progressId,
  required String? keyHex,
  required Map<String, List<String>> listed,
  required SrsSync2Report report,
  SrsSyncStepCallback? onStep,
}) async {
  final Map<String, Object?> plan = (await host.sync2Command(<String, Object?>{
    'op': 'heritage_plan',
    'progress': progressId,
    'listing': srsDeviceListing(listed),
  })).map;
  // 两种回包都带：指纹没变（`skip`）时本机照样可能还扣着待确认作者的承袭日志，提示不能因此消失。
  report.heritageUnvouched = _strings(plan['unvouched']);
  report.heritagePending = _strings(plan['pending']);
  if (plan['skip'] == true) return;
  onStep?.call('heritage');
  final List<String> read = _strings(plan['read']);
  final List<Uint8List?> got = await srsRunPooled(
    read,
    kSrsSync2Concurrency,
    location.get,
  );
  final SrsSync2Result out = await host.sync2Command(
    <String, Object?>{
      'op': 'heritage_outbox',
      'key': keyHex,
      'paths': <String>[
        for (int i = 0; i < read.length; i++)
          if (got[i] != null) read[i],
      ],
    },
    blobs: <Uint8List>[for (final Uint8List? b in got) ?b],
  );
  await srsRunPooled(out.files, kSrsSync2Concurrency, (
    (String, Uint8List) f,
  ) async {
    await location.put(f.$1, f.$2);
    _noteWritten(listed, f.$1);
    report.uploaded++;
  });
  _addErrors(report, out.map['errors'], 'heritage: ');
  final List<Object?> blocked = (out.map['blocked'] as List?) ?? const [];
  final List<Object?> forked = (out.map['keptForked'] as List?) ?? const [];
  for (final Object? b in blocked) {
    report.errors.add('heritage: no cut point to upload $b');
  }
  for (final Object? f in forked) {
    report.errors.add('heritage: forked segment kept at $f');
  }
  if (blocked.isNotEmpty || forked.isNotEmpty || got.contains(null)) return;
  await host.sync2Command(<String, Object?>{
    'op': 'heritage_ack',
    'progress': progressId,
    'listing': srsDeviceListing(listed),
  });
}

/// 收位置上别的设备的媒体清单（内核 `media_manifests` / `media_manifest_ingest`）：本机媒体对账（`media_known`）据此
/// 知道位置上有什么，不必列目录。同一个作者的清单按代号升序，一份收不了内核就停在它（下一轮再来）。
Future<void> srsSync4MediaManifestsIn({
  required SrsSync2Host host,
  required SrsLocationStore location,
  required String locationId,
  required Map<String, List<String>> listed,
  required SrsSync2Report report,
  required int Function() nowMs,
}) async {
  final List<String> fetch = _strings(
    (await host.sync2Command(<String, Object?>{
      'op': 'media_manifests',
      'location': locationId,
      'listing': srsDeviceListing(listed),
    })).map['fetch'],
  );
  if (fetch.isEmpty) return;
  final List<Uint8List?> got = await srsRunPooled(
    fetch,
    kSrsSync2Concurrency,
    location.get,
  );
  final Map<String, Object?> r = (await host.sync2Command(
    <String, Object?>{
      'op': 'media_manifest_ingest',
      'location': locationId,
      'paths': fetch,
      'present': <bool>[for (final Uint8List? b in got) b != null],
      'now': nowMs(),
    },
    blobs: <Uint8List>[for (final Uint8List? b in got) ?b],
  )).map;
  _addErrors(report, r['errors'], 'media manifest: ');
}

/// 本机待发的媒体事实（`media_record` 记下的）打成清单写上位置（内核 `media_manifest_build` → 写 →
/// `media_manifest_published`）。没有待发的什么都不写、不烧代号。
Future<void> srsSync4MediaManifestsOut({
  required SrsSync2Host host,
  required SrsLocationStore location,
  required String locationId,
  required String loc,
  required String self,
  required Map<String, List<String>> listed,
}) async {
  final List<int> own = <int>[
    for (final String n in listed['devices/$self'] ?? const <String>[])
      if (n.startsWith('mf-'))
        if (int.tryParse(n.substring(3).split('-').first) case final int g) g,
  ];
  final SrsSync2Result built = await host.sync2Command(<String, Object?>{
    'op': 'media_manifest_build',
    'location': locationId,
    'loc': loc,
    'ownGens': own,
  });
  if (built.map['built'] != true) return;
  final (String path, Uint8List bytes) = built.files.single;
  await location.put(path, bytes);
  _noteWritten(listed, path);
  await host.sync2Command(
    <String, Object?>{'op': 'media_manifest_published', 'location': locationId},
    blobs: <Uint8List>[bytes],
  );
}

/// 转发（内核 `cmd/sync_relay.rs`，G8-7b）：本机同步着多个位置时，把收到过、而这个位置缺的别的设备的段（中继件
/// `rly-`，按本位置的钥匙封装）与段都到位之后的 head（`rhd-`）写上去。一批写完 `relay_ack` 再要下一批（head 要等它
/// 引用的段确认写上才给）；最后删掉被新转发取代的旧件（归档位置不删）并报回内核。写失败的这一轮停下，下一轮从内核
/// 记账接着来；删失败的留在内核的待删清单里，下一轮再删。
Future<void> srsSync4Relay({
  required SrsSync2Host host,
  required SrsLocationStore location,
  required String locationId,
  required String? keyHex,
  required bool archive,
  required SrsSync2Report report,
  bool Function()? shouldStop,
}) async {
  List<String> delete = const <String>[];
  while (true) {
    final SrsSync2Result out = await host.sync2Command(<String, Object?>{
      'op': 'relay_outbox',
      'location': locationId,
      'key': keyHex,
    });
    await srsRunPooled(out.files, kSrsSync2Concurrency, (
      (String, Uint8List) f,
    ) async {
      await location.put(f.$1, f.$2);
      report.relayed++;
    });
    final Map<String, Object?> ack = (await host.sync2Command(<String, Object?>{
      'op': 'relay_ack',
      'location': locationId,
      'paths': <String>[for (final (String, Uint8List) f in out.files) f.$1],
    })).map;
    delete = _strings(ack['delete']);
    if (out.map['more'] != true || out.files.isEmpty) break;
    if (shouldStop?.call() ?? false) return;
  }
  if (delete.isEmpty) return;
  final List<String> deleted = <String>[];
  if (archive) {
    // 归档位置只写不删：按策略跳过，同样报回去（内核不再列它们）。
    deleted.addAll(delete);
  } else {
    await srsRunPooled(delete, kSrsSync2Concurrency, (String p) async {
      try {
        await location.delete(p);
        deleted.add(p);
      } on Object catch (e) {
        report.errors.add('relay delete $p: $e');
      }
    });
  }
  if (deleted.isEmpty) return;
  await host.sync2Command(<String, Object?>{
    'op': 'relay_ack',
    'location': locationId,
    'deleted': deleted,
  });
}

/// 用户移除了同步位置 [locationId]（内核 `location_forget`，G8-7c）：本机忘掉这个位置的全部同步状态——加密记忆 / loc
/// 标记 / `last_ok`、各设备的 head 记录、转发记账、旧根核对——并且不再向它转发（为它留着的原文按剩下的位置重判）。
/// 位置上的文件、本机的卡片与复习记录一个不动；已传水位与媒体代号留着（同一个位置加回来时 head 代号接着往上）。
/// 没记过这个位置也照常返回。G10 的 host 目录 / 通道位置的移除同样调这一个。回包 `{forgotten, relayDropped}`。
///
/// 位置配置是设备级的（所有 profile 共用），所以内核在库文件里**每一个**集合里各忘一次，不只 [host] 的 profile 的
/// （[host] 的 profile 没有集合也照常忘别的集合）。
Future<Map<String, Object?>> srsSync4ForgetLocation(
  SrsSync2Host host,
  String locationId,
) async => (await host.sync2Command(<String, Object?>{
  'op': 'location_forget',
  'location': locationId,
})).map;

/// 本机旧身份（`obsolete` 回包的 [former]）目录里的旧 head（内核 `obsolete_former`：只删比最新 head 旧两代以上的，
/// 段一个不删）。删不掉的记进 [SrsSync2Report.formerSweepErrors]，下一轮再删。
Future<void> srsSync4SweepFormer({
  required SrsSync2Host host,
  required SrsLocationStore location,
  required Object? former,
  required Map<String, List<String>> listed,
  required bool archive,
  required SrsSync2Report report,
}) async {
  for (final String device in _strings(former)) {
    final List<String> delete = _strings(
      (await host.sync2Command(<String, Object?>{
        'op': 'obsolete_former',
        'device': device,
        'present': listed['devices/$device'] ?? const <String>[],
        'archive': archive,
      })).map['delete'],
    );
    await srsRunPooled(delete, kSrsSync2Concurrency, (String p) async {
      try {
        await location.delete(p);
      } on Object catch (e) {
        report.formerSweepErrors.add('$p: $e');
      }
    });
  }
}
