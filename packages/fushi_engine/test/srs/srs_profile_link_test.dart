// 复习同步的 profile 关联（铁律 E）：profileUid 每台设备本机随机生成，同步目录按 uid 分区，
// 不关联时两台设备各写各的目录、复习数据从不互通。
import 'dart:io';

import 'package:fushi_engine/srs/srs_profile_link.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart' show kSrs4Root;
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:test/test.dart';

const String kMine = '01928c3e-0000-7000-8000-00000000000b';
const String kOther = '01928c3e-0000-7000-8000-00000000000a';
const String kDevice = 'phone';

SrsProfileLinkDecision decide({
  bool localHasNotes = false,
  String localName = 'Default',
  int localProfileCount = 1,
  required List<SrsRemoteProfile> remote,
  String? v2Device,
}) => srsDecideProfileLink(
  localUid: kMine,
  localName: localName,
  deviceId: kDevice,
  localHasNotes: localHasNotes,
  localProfileCount: localProfileCount,
  remote: remote,
  v2Device: v2Device,
);

void main() {
  group('srsDecideProfileLink', () {
    test('目录里没有别的 profile：保持', () {
      expect(
        decide(remote: const <SrsRemoteProfile>[]),
        isA<SrsProfileLinkKeep>(),
      );
      expect(
        decide(
          remote: const <SrsRemoteProfile>[
            SrsRemoteProfile(uid: kMine, writers: <String>['phone#1']),
          ],
        ),
        isA<SrsProfileLinkKeep>(),
      );
    });

    test('本机没有笔记、目录里有同名且有笔记的 profile：采用（即使本机已发布过自己的目录）', () {
      final SrsProfileLinkDecision d = decide(
        remote: const <SrsRemoteProfile>[
          SrsRemoteProfile(uid: kMine, writers: <String>['phone#1']),
          SrsRemoteProfile(
            uid: kOther,
            writers: <String>['host#1'],
            names: <String>{'Default'},
            hasNotes: true,
          ),
        ],
      );
      expect(d, isA<SrsProfileLinkAdopt>());
      expect((d as SrsProfileLinkAdopt).uid, kOther);
    });

    test('名字对不上（语言不同 / 旧版本没说明文件）但两边都只有一个 profile：采用', () {
      expect(
        decide(
          localName: '默认',
          remote: const <SrsRemoteProfile>[
            SrsRemoteProfile(
              uid: kOther,
              writers: <String>['host#1'],
              names: <String>{'Default'},
              hasNotes: true,
            ),
          ],
        ),
        isA<SrsProfileLinkAdopt>(),
      );
      expect(
        decide(
          remote: const <SrsRemoteProfile>[
            SrsRemoteProfile(uid: kOther, writers: <String>['host#1']),
          ],
        ),
        isA<SrsProfileLinkAdopt>(),
      );
    });

    test('本机有多个 profile、名字对不上：不猜', () {
      expect(
        decide(
          localName: 'JP',
          localProfileCount: 2,
          remote: const <SrsRemoteProfile>[
            SrsRemoteProfile(
              uid: kOther,
              writers: <String>['host#1'],
              names: <String>{'EN'},
              hasNotes: true,
            ),
          ],
        ),
        isA<SrsProfileLinkKeep>(),
      );
    });

    test('本机 uid 的目录里已有别的设备（别人采用了本机的 uid）：保持', () {
      expect(
        decide(
          remote: const <SrsRemoteProfile>[
            SrsRemoteProfile(uid: kMine, writers: <String>['phone#1', 'tab#3']),
            SrsRemoteProfile(
              uid: kOther,
              writers: <String>['host#1'],
              names: <String>{'Default'},
              hasNotes: true,
            ),
          ],
        ),
        isA<SrsProfileLinkKeep>(),
      );
    });

    test('只有本设备旧化身留下的目录不算别人的数据', () {
      expect(
        decide(
          remote: const <SrsRemoteProfile>[
            SrsRemoteProfile(
              uid: kOther,
              writers: <String>['phone#1'],
              names: <String>{'Default'},
              hasNotes: true,
            ),
          ],
        ),
        isA<SrsProfileLinkKeep>(),
      );
    });

    test('同步 v2 设备目录：本机 v2 设备写的目录算本设备的，别的 v2 设备算别人的', () {
      const List<SrsRemoteProfile> remote = <SrsRemoteProfile>[
        SrsRemoteProfile(
          uid: kOther,
          writers: <String>['v2:dev-phone'],
          names: <String>{'Default'},
          hasNotes: true,
        ),
      ];
      expect(
        decide(remote: remote, v2Device: 'dev-phone'),
        isA<SrsProfileLinkKeep>(),
        reason: '只有本设备（v2 身份）留下的目录',
      );
      final SrsProfileLinkDecision d = decide(
        remote: remote,
        v2Device: 'dev-other',
      );
      expect(d, isA<SrsProfileLinkAdopt>());
      expect((d as SrsProfileLinkAdopt).uid, kOther);
      // 本机 uid 下已有别的 v2 设备：已经关联上了，保持。
      expect(
        decide(
          v2Device: 'dev-phone',
          remote: const <SrsRemoteProfile>[
            SrsRemoteProfile(
              uid: kMine,
              writers: <String>['v2:dev-phone', 'v2:dev-tab'],
            ),
            SrsRemoteProfile(
              uid: kOther,
              writers: <String>['v2:dev-host'],
              names: <String>{'Default'},
              hasNotes: true,
            ),
          ],
        ),
        isA<SrsProfileLinkKeep>(),
      );
    });

    test('两边都有笔记：报告无法自动关联', () {
      final SrsProfileLinkDecision d = decide(
        localHasNotes: true,
        remote: const <SrsRemoteProfile>[
          SrsRemoteProfile(
            uid: kOther,
            writers: <String>['host#1'],
            names: <String>{'Default'},
            hasNotes: true,
          ),
        ],
      );
      expect(d, isA<SrsProfileLinkChoose>());
      expect(
        (d as SrsProfileLinkChoose).candidates.single.displayName,
        'Default',
      );
    });

    // BUG-4296：对方已经选定把它的 profile 并入别处、只是并入暂缓着（还按旧 uid 同步），说明文件里写着 `mergingInto`。
    // 本机不能再被问要不要并进那个旧 profile——选了就会把本机并进对方正在离开的 profile，两边从此分叉。
    test('对方的写入者已选定并入别处（mergingInto，并入暂缓中）：它的旧 profile 不再是候选', () {
      for (final String into in <String>[
        kMine,
        '01928c3e-0000-7000-8000-0000000000ff',
      ]) {
        final SrsProfileLinkDecision d = decide(
          localHasNotes: true,
          v2Device: 'phone-v2',
          remote: <SrsRemoteProfile>[
            const SrsRemoteProfile(
              uid: kMine,
              writers: <String>['v2:phone-v2'],
            ),
            SrsRemoteProfile(
              uid: kOther,
              writers: const <String>['v2:host'],
              names: const <String>{'Default'},
              hasNotes: true,
              mergingInto: <String, String>{'v2:host': into},
            ),
          ],
        );
        expect(d, isA<SrsProfileLinkKeep>(), reason: 'merging into $into');
        expect((d as SrsProfileLinkKeep).linked, isFalse);
      }
      // 本机没有笔记时也不自动采用它。
      expect(
        decide(
          remote: const <SrsRemoteProfile>[
            SrsRemoteProfile(
              uid: kOther,
              writers: <String>['v2:host'],
              names: <String>{'Default'},
              hasNotes: true,
              mergingInto: <String, String>{'v2:host': kMine},
            ),
          ],
        ),
        isA<SrsProfileLinkKeep>(),
      );
    });

    test('mergingInto 只让那一个写入者不算数：旧 profile 里还有留下的设备，照样是候选', () {
      final SrsProfileLinkDecision d = decide(
        localHasNotes: true,
        remote: const <SrsRemoteProfile>[
          SrsRemoteProfile(
            uid: kOther,
            writers: <String>['v2:host', 'v2:tablet'],
            names: <String>{'Default'},
            hasNotes: true,
            mergingInto: <String, String>{'v2:host': kMine},
          ),
        ],
      );
      expect(d, isA<SrsProfileLinkChoose>());
      expect((d as SrsProfileLinkChoose).candidates.single.uid, kOther);
    });

    test('本机 uid 目录里别的设备正在并入别处：不算已关联', () {
      final SrsProfileLinkDecision d = decide(
        remote: const <SrsRemoteProfile>[
          SrsRemoteProfile(
            uid: kMine,
            writers: <String>['phone#1', 'v2:tablet'],
            mergingInto: <String, String>{'v2:tablet': kOther},
          ),
        ],
      );
      expect(d, isA<SrsProfileLinkKeep>());
      expect((d as SrsProfileLinkKeep).linked, isFalse);
    });

    // 实测布局（三台设备各自随机生成 uid、都叫 Default）：电脑 PC（有笔记）、iPhone（有笔记）、平板（空）、一个旧版本留下
    // 的无说明文件目录。以前平板按名字匹配到两个就静默保持，永远按自己的空 profile 同步、拉不到任何数据。
    const String kPc = '01a13df1-0000-7000-8000-000000000001';
    const String kPhone = '01a13dd3-0000-7000-8000-000000000002';
    const String kTablet = '01a17876-0000-7000-8000-000000000003';
    const String kLegacy = '01a14b6c-0000-7000-8000-000000000004';
    const List<SrsRemoteProfile> layout = <SrsRemoteProfile>[
      SrsRemoteProfile(
        uid: kPc,
        writers: <String>['v2:pc'],
        names: <String>{'Default'},
        hasNotes: true,
      ),
      SrsRemoteProfile(
        uid: kPhone,
        writers: <String>['v2:phone'],
        names: <String>{'Default'},
        hasNotes: true,
      ),
      SrsRemoteProfile(
        uid: kTablet,
        writers: <String>['v2:tablet'],
        names: <String>{'Default'},
        hasNotes: false,
      ),
      SrsRemoteProfile(uid: kLegacy, writers: <String>['old#1']),
    ];
    SrsProfileLinkDecision decideAs(String uid, String device, bool notes) =>
        srsDecideProfileLink(
          localUid: uid,
          localName: 'Default',
          deviceId: device,
          localHasNotes: notes,
          localProfileCount: 1,
          remote: layout,
          v2Device: device,
        );

    test('多台设备同名：没有笔记的平板不再静默保持，让用户在有数据的候选里选', () {
      final SrsProfileLinkDecision d = decideAs(kTablet, 'tablet', false);
      expect(d, isA<SrsProfileLinkChoose>());
      expect(
        (d as SrsProfileLinkChoose).candidates.map(
          (SrsRemoteProfile c) => c.uid,
        ),
        <String>[kPhone, kPc],
        reason: '空的平板自己与名字对不上的旧目录不算候选；按 uid 排序',
      );
    });

    test('多台设备同名：有笔记的 iPhone 与电脑各自让用户选（只列对方有数据的）', () {
      final SrsProfileLinkDecision phone = decideAs(kPhone, 'phone', true);
      expect(
        (phone as SrsProfileLinkChoose).candidates.map(
          (SrsRemoteProfile c) => c.uid,
        ),
        <String>[kPc],
      );
      final SrsProfileLinkDecision pc = decideAs(kPc, 'pc', true);
      expect(
        (pc as SrsProfileLinkChoose).candidates.map(
          (SrsRemoteProfile c) => c.uid,
        ),
        <String>[kPhone],
      );
    });

    test('候选全是空 profile：本机也空时收敛到 uid 最小的那个', () {
      const List<SrsRemoteProfile> empties = <SrsRemoteProfile>[
        SrsRemoteProfile(
          uid: kPhone,
          writers: <String>['v2:phone'],
          names: <String>{'Default'},
          hasNotes: false,
        ),
        SrsRemoteProfile(
          uid: kTablet,
          writers: <String>['v2:tablet'],
          names: <String>{'Default'},
          hasNotes: false,
        ),
      ];
      final SrsProfileLinkDecision d = srsDecideProfileLink(
        localUid: kPc,
        localName: 'Default',
        deviceId: 'pc',
        localHasNotes: false,
        localProfileCount: 1,
        remote: empties,
        v2Device: 'pc',
      );
      expect((d as SrsProfileLinkAdopt).uid, kPhone);
    });

    test('本机有笔记、对方只有内置行：保持（等对方来采用）', () {
      expect(
        decide(
          localHasNotes: true,
          remote: const <SrsRemoteProfile>[
            SrsRemoteProfile(
              uid: kOther,
              writers: <String>['host#1'],
              names: <String>{'Default'},
              hasNotes: false,
            ),
          ],
        ),
        isA<SrsProfileLinkKeep>(),
      );
    });

    test('两边都只有内置行：只有 uid 较大的一边采用，不会互相采用', () {
      // kMine > kOther：本机采用。
      expect(
        decide(
          remote: const <SrsRemoteProfile>[
            SrsRemoteProfile(
              uid: kOther,
              writers: <String>['host#1'],
              names: <String>{'Default'},
              hasNotes: false,
            ),
          ],
        ),
        isA<SrsProfileLinkAdopt>(),
      );
      // 对面视角（uid 较小的一边）：保持。
      expect(
        srsDecideProfileLink(
          localUid: kOther,
          localName: 'Default',
          deviceId: 'host',
          localHasNotes: false,
          localProfileCount: 1,
          remote: const <SrsRemoteProfile>[
            SrsRemoteProfile(
              uid: kMine,
              writers: <String>['phone#1'],
              names: <String>{'Default'},
              hasNotes: false,
            ),
          ],
        ),
        isA<SrsProfileLinkKeep>(),
      );
    });
  });

  group('说明文件读写 / 孤儿目录清理（真目录）', () {
    late Directory root;
    late LocalDirectoryAssetStore store;
    setUp(() {
      root = Directory.systemTemp.createTempSync('fushi_srs_link_');
      store = LocalDirectoryAssetStore(root);
    });
    tearDown(() => root.deleteSync(recursive: true));

    test('发布后列得出名字与有无笔记；说明文件落在新代根 v4/ 的设备目录里（旧根不碰）', () async {
      await srsPublishProfileInfo(
        store,
        profileUid: kOther,
        writerId: 'host#1',
        name: 'Default',
        hasNotes: true,
      );
      // 覆盖写（Google Drive 等允许同名多文件的后端先删再写）。
      await srsPublishProfileInfo(
        store,
        profileUid: kOther,
        writerId: 'host#1',
        name: 'Main',
        hasNotes: true,
      );
      final List<SrsRemoteProfile> list = await srsListRemoteProfiles(store);
      expect(list.single.uid, kOther);
      expect(list.single.writers, <String>[srsV2WriterName('host#1')]);
      expect(list.single.names, <String>{'Main'});
      expect(list.single.hasNotes, isTrue);
      expect(
        File(
          '${root.path}/$kSrsSync2Namespace/$kOther/$kSrs4Root/devices/'
          'host#1/$kSrsProfileInfoName',
        ).existsSync(),
        isTrue,
      );
      expect(
        Directory(
          '${root.path}/$kSrsSync2Namespace/$kOther/$kSrsSync2Folder',
        ).existsSync(),
        isFalse,
      );
    });

    // 第五波 G9 身份收尾（交接 §34「没做」）：新代全新集合只有 `v4/` 根，说明文件在 `v4/devices/<设备>/`（规划 G-6）。
    // 列表（WebUI 勾选列表、关联候选）读得出名字、设备名与笔记数；旧根 `v3/devices/` 里协议 3 设备的说明文件照样读，
    // 同一台设备两边都有只算一个写入者；只有 head 的新代设备目录不算写入者。
    test('新代全新集合：v4/devices 里的说明文件列得出名字与笔记数，与旧根同名设备只算一次', () async {
      await srsPublishProfileInfo(
        store,
        profileUid: kOther,
        writerId: 'd4',
        name: 'Main',
        hasNotes: true,
        device: 'Pixel 9',
        noteCount: 12,
      );
      final String ns = await store.ensureNamespace(kSrsSync2Namespace);
      final String profile = await store.ensureFolder(ns, kOther);
      final String v4 = await store.ensureFolder(profile, kSrs4Root);
      await store.ensureFolder(await store.ensureFolder(v4, 'devices'), 'bare');
      SrsRemoteProfile p = (await srsListRemoteProfiles(store)).single;
      expect(p.names, <String>{'Main'});
      expect(p.displayName, 'Main');
      expect(p.noteCount, 12);
      expect(p.devices, <String>['Pixel 9']);
      expect(p.writers, <String>[srsV2WriterName('d4')]);
      // 协议 3 的设备（旧根）与同一台设备的旧说明文件：都读，写入者不重复。
      final String v3 = await store.ensureFolder(profile, kSrsSync2Folder);
      final String v3devices = await store.ensureFolder(v3, 'devices');
      for (final (String dev, String json) in <(String, String)>[
        ('d4', '{"v":1,"name":"Main","hasNotes":true,"notes":3}'),
        ('p3', '{"v":1,"name":"Old","hasNotes":true,"notes":20}'),
      ]) {
        final String w = await store.ensureFolder(v3devices, dev);
        final File f = File('${root.path}/info.json')..writeAsStringSync(json);
        await store.putAsset(w, kSrsProfileInfoName, f);
        f.deleteSync();
      }
      p = (await srsListRemoteProfiles(store)).single;
      expect(p.names, <String>{'Main', 'Old'});
      expect(p.noteCount, 20);
      expect(p.writers.toSet(), <String>{
        srsV2WriterName('d4'),
        srsV2WriterName('p3'),
      });
      expect(p.writers.length, 2);
    });

    // 复核 major：同一台设备升级前把说明文件写在旧根 `v3/devices/`，升级后写 `v4/devices/`，旧那份没人删。两份都用同一个
    // 写入者名，以前后读的覆盖先读的，采信哪份跟着目录列举顺序走（Linux ext4 上是哈希序）。现在当前发布位置 `v4/` 优先，
    // 与两份的修改时刻谁新无关；名字集合（displayName 取第一个）也按时刻 + 写入者名排。两种列举顺序各跑一遍。
    test('同一设备 v3 旧说明文件 + v4 新说明文件：两种列举顺序都只采信 v4 那份', () async {
      final String ns = await store.ensureNamespace(kSrsSync2Namespace);
      final String profile = await store.ensureFolder(ns, kOther);
      final String v3devices = await store.ensureFolder(
        await store.ensureFolder(profile, kSrsSync2Folder),
        'devices',
      );
      final String oldDir = await store.ensureFolder(v3devices, 'devA');
      final File f = File('${root.path}/info.json')
        ..writeAsStringSync(
          '{"v":1,"name":"OldName","hasNotes":true,"mergingInto":"$kMine"}',
        );
      await store.putAsset(oldDir, kSrsProfileInfoName, f);
      f.deleteSync();
      await srsPublishProfileInfo(
        store,
        profileUid: kOther,
        writerId: 'devA',
        name: 'NewName',
        hasNotes: true,
      );
      await srsPublishProfileInfo(
        store,
        profileUid: kOther,
        writerId: 'devB',
        name: 'B',
        hasNotes: true,
      );
      final File oldInfo = File('$oldDir/$kSrsProfileInfoName');
      final File newInfo = File(
        '${root.path}/$kSrsSync2Namespace/$kOther/$kSrs4Root/devices/devA/'
        '$kSrsProfileInfoName',
      );
      final File bInfo = File(
        '${root.path}/$kSrsSync2Namespace/$kOther/$kSrs4Root/devices/devB/'
        '$kSrsProfileInfoName',
      );
      final DateTime t = DateTime(2026, 11, 1);
      newInfo.setLastModifiedSync(t);
      bInfo.setLastModifiedSync(t.subtract(const Duration(hours: 1)));
      // 旧文件比新文件旧（真实场景）与比新文件新（钉住「位置优先于时刻」）各一遍。
      for (final Duration oldShift in <Duration>[
        const Duration(days: -1),
        const Duration(days: 1),
      ]) {
        oldInfo.setLastModifiedSync(t.add(oldShift));
        for (final bool reversed in <bool>[false, true]) {
          final SrsRemoteProfile r = (await srsListRemoteProfiles(
            _OrderedDirectoryStore(root, reversed: reversed),
          )).single;
          final String why = 'reversed=$reversed oldShift=$oldShift';
          expect(r.nameOf, <String, String>{
            srsV2WriterName('devA'): 'NewName',
            srsV2WriterName('devB'): 'B',
          }, reason: why);
          expect(
            r.nameAtOf[srsV2WriterName('devA')],
            newInfo.statSync().modified.millisecondsSinceEpoch,
            reason: why,
          );
          expect(r.names.toList(), <String>['NewName', 'B'], reason: why);
          expect(r.displayName, 'NewName', reason: why);
          // 旧那份的并入标记同样不采信（v4 那份没有并入标记）。
          expect(r.mergingInto, isEmpty, reason: why);
          expect(r.writers.toSet(), <String>{
            srsV2WriterName('devA'),
            srsV2WriterName('devB'),
          }, reason: why);
        }
      }
    });

    test('新代集合根 v4/ 不是写入者目录（G8-7 起云端会有 fushi-srs/<dir>/v4/）', () async {
      await srsPublishProfileInfo(
        store,
        profileUid: kOther,
        writerId: 'host#1',
        name: 'Main',
        hasNotes: true,
      );
      final String ns = await store.ensureNamespace(kSrsSync2Namespace);
      final String profile = await store.ensureFolder(ns, kOther);
      final String v4 = await store.ensureFolder(profile, kSrs4Root);
      await store.ensureFolder(await store.ensureFolder(v4, 'devices'), 'd1');
      final List<SrsRemoteProfile> list = await srsListRemoteProfiles(store);
      expect(list.single.writers, <String>[srsV2WriterName('host#1')]);
    });

    test('旧格式写入者目录的说明文件照样列得出（升级前写的）', () async {
      final String ns = await store.ensureNamespace(kSrsSync2Namespace);
      final String profile = await store.ensureFolder(ns, kOther);
      final String writer = await store.ensureFolder(profile, 'host#1');
      final File f = File('${root.path}/info.json')
        ..writeAsStringSync('{"v":1,"name":"Old","hasNotes":true}');
      await store.putAsset(writer, kSrsProfileInfoName, f);
      f.deleteSync();
      final List<SrsRemoteProfile> list = await srsListRemoteProfiles(store);
      expect(list.single.writers, <String>['host#1']);
      expect(list.single.names, <String>{'Old'});
      expect(list.single.hasNotes, isTrue);
      // 旧版本不报设备名与笔记数：未知，不瞎猜。
      expect(list.single.devices, isEmpty);
      expect(list.single.noteCount, isNull);
    });

    test('mergingInto 发布后按写入者列得出；指向自己 uid 的无效值与旧格式说明文件都当作没有', () async {
      await srsPublishProfileInfo(
        store,
        profileUid: kOther,
        writerId: 'host',
        name: 'Default',
        hasNotes: true,
        mergingInto: kMine,
      );
      await srsPublishProfileInfo(
        store,
        profileUid: kOther,
        writerId: 'tablet',
        name: 'Default',
        hasNotes: true,
        mergingInto: kOther,
      );
      await srsPublishProfileInfo(
        store,
        profileUid: kOther,
        writerId: 'pc',
        name: 'Default',
        hasNotes: true,
      );
      final SrsRemoteProfile p = (await srsListRemoteProfiles(store)).single;
      expect(p.mergingInto, <String, String>{srsV2WriterName('host'): kMine});
      expect(p.stayingWriters.toSet(), <String>{
        srsV2WriterName('tablet'),
        srsV2WriterName('pc'),
      });
      // 写回不带 mergingInto（并入做完 / 不再暂缓）：再列就没有了。
      await srsPublishProfileInfo(
        store,
        profileUid: kOther,
        writerId: 'host',
        name: 'Default',
        hasNotes: true,
      );
      expect((await srsListRemoteProfiles(store)).single.mergingInto, isEmpty);
    });

    test('多台设备的设备名按出现顺序去重，笔记数取最大的一份', () async {
      for (final (String w, String dev, int n) in <(String, String, int)>[
        ('host#1', 'Pixel 9', 3),
        ('pc#1', 'Windows PC', 7),
        ('pc#2', 'Windows PC', 5),
      ]) {
        await srsPublishProfileInfo(
          store,
          profileUid: kOther,
          writerId: w,
          name: 'Default',
          hasNotes: true,
          device: dev,
          noteCount: n,
        );
      }
      final SrsRemoteProfile p = (await srsListRemoteProfiles(store)).single;
      expect(p.devices.toSet(), <String>{'Pixel 9', 'Windows PC'});
      expect(p.devices.length, 2);
      expect(p.noteCount, 7);
    });

    test('清理只删本设备的旧格式写入者目录；目录空了整个删', () async {
      Future<void> legacyWriter(String w) async {
        final String ns = await store.ensureNamespace(kSrsSync2Namespace);
        final String profile = await store.ensureFolder(ns, kMine);
        await store.ensureFolder(profile, w);
      }

      for (final String w in <String>['phone#1', 'phone#2']) {
        await legacyWriter(w);
      }
      await srsRemoveOwnProfileFolder(
        store,
        profileUid: kMine,
        deviceId: kDevice,
      );
      expect(
        Directory('${root.path}/$kSrsSync2Namespace/$kMine').existsSync(),
        isFalse,
      );
      await legacyWriter('phone#3');
      await legacyWriter('tab#1');
      await srsRemoveOwnProfileFolder(
        store,
        profileUid: kMine,
        deviceId: kDevice,
      );
      final List<SrsRemoteProfile> left = await srsListRemoteProfiles(store);
      expect(left.single.writers, <String>['tab#1']);
    });

    // G9-5：新代集合根 `v4/` 不是写入者目录（名字碰巧像本设备的写入者也不算）；只删本机新代身份的设备目录，
    // 根与 profile 目录永远留着；不给本机新代身份时 `v4/` 一个字节不碰。
    test('清理认识新代根 v4/：只删本机新代设备目录', () async {
      final String ns = await store.ensureNamespace(kSrsSync2Namespace);
      final String profile = await store.ensureFolder(ns, kMine);
      final String v4 = await store.ensureFolder(profile, kSrs4Root);
      final String devices = await store.ensureFolder(v4, 'devices');
      await store.ensureFolder(devices, 'me4');
      await store.ensureFolder(devices, 'other4');
      await store.ensureFolder(profile, 'phone#1');
      final Directory root4 = Directory(
        '${root.path}/$kSrsSync2Namespace/$kMine/$kSrs4Root',
      );

      // 没有本机新代身份：v4 整个算别人的。设备 ID 故意取成 `v4` 的样子，也不许当写入者目录删。
      await srsRemoveOwnProfileFolder(
        store,
        profileUid: kMine,
        deviceId: kSrs4Root,
      );
      expect(Directory('${root4.path}/devices/me4').existsSync(), isTrue);
      expect(Directory('${root4.path}/devices/other4').existsSync(), isTrue);

      // 本机新代身份 me4：只删它；other4 还在，根与 profile 目录都留着。
      await srsRemoveOwnProfileFolder(
        store,
        profileUid: kMine,
        deviceId: kDevice,
        v4Device: 'me4',
      );
      expect(Directory('${root4.path}/devices/me4').existsSync(), isFalse);
      expect(Directory('${root4.path}/devices/other4').existsSync(), isTrue);
      expect(
        Directory(
          '${root.path}/$kSrsSync2Namespace/$kMine/phone#1',
        ).existsSync(),
        isFalse,
      );

      // 只剩本机自己的新代设备目录：也只删它，根（含 meta.json）与 profile 目录留着——别的设备可能已按 meta.json
      // 换绑到这个集合、只是还没发布自己的设备目录（复核 nit）。
      await store.deleteAsset(
        (await store.listChildren(devices)).single.id,
        isFolder: true,
      );
      await store.ensureFolder(devices, 'me4');
      File('${root4.path}/meta.json').writeAsStringSync('{}');
      await srsRemoveOwnProfileFolder(
        store,
        profileUid: kMine,
        deviceId: kDevice,
        v4Device: 'me4',
      );
      expect(Directory('${root4.path}/devices/me4').existsSync(), isFalse);
      expect(File('${root4.path}/meta.json').existsSync(), isTrue);
      expect(
        Directory('${root.path}/$kSrsSync2Namespace/$kMine').existsSync(),
        isTrue,
      );
    });

    // 改绑而旧集合里还有别的设备（`joined` + `rebound`，v4Device 不给）：本机新代设备目录留着（别的设备还要从那里收
    // 本机之前的段），但本机的说明文件要删——它在 `v4/devices/<本机>/` 里，留着别的设备就一直把旧目录当候选。
    test('清理不删新代设备目录时也删掉本机的说明文件', () async {
      await srsPublishProfileInfo(
        store,
        profileUid: kMine,
        writerId: 'me4',
        name: 'Main',
        hasNotes: true,
      );
      final String ns = await store.ensureNamespace(kSrsSync2Namespace);
      final String profile = await store.ensureFolder(ns, kMine);
      final String v4 = await store.ensureFolder(profile, kSrs4Root);
      final String devices = await store.ensureFolder(v4, 'devices');
      final String me = await store.ensureFolder(devices, 'me4');
      final File seg = File('${root.path}/seg.bin')..writeAsStringSync('x');
      await store.putAsset(me, 'head-000000000001-00000000.json', seg);
      seg.deleteSync();
      expect((await srsListRemoteProfiles(store)).single.writers, <String>[
        srsV2WriterName('me4'),
      ]);
      await srsRemoveOwnProfileFolder(
        store,
        profileUid: kMine,
        deviceId: kDevice,
        v2Device: 'me4',
      );
      final String meDir =
          '${root.path}/$kSrsSync2Namespace/$kMine/$kSrs4Root/devices/me4';
      expect(Directory(meDir).existsSync(), isTrue);
      expect(
        File('$meDir/head-000000000001-00000000.json').existsSync(),
        isTrue,
      );
      expect(File('$meDir/$kSrsProfileInfoName').existsSync(), isFalse);
      expect((await srsListRemoteProfiles(store)).single.writers, isEmpty);
    });
  });

  // BUG-5526：平板（新代设备 tab）自己的集合目录里留着一台协议 1 时代旧设备 old 的 `v2/devices/old/`（说明文件报
  // 「有笔记」）。新代立根后旧根 `v2/` / `v3/` 都立了围栏，old 不会再写这个集合；以前它照样算成员，关联永远判成「已关联」，
  // 平板再也不采用电脑那份有一万多条笔记的集合，同步每轮照常报成功、两边数据永远对不上。
  group('已退役旧根里的写入者（真目录）', () {
    const String kTabCollection = '84749d00-0000-5000-8000-000000000001';
    const String kPcCollection = 'fa45abce-0000-5000-8000-000000000002';
    late Directory root;
    late LocalDirectoryAssetStore store;
    setUp(() {
      root = Directory.systemTemp.createTempSync('fushi_srs_link_retired_');
      store = LocalDirectoryAssetStore(root);
    });
    tearDown(() => root.deleteSync(recursive: true));

    String dirOf(String uid, String rel) =>
        '${root.path}/$kSrsSync2Namespace/$uid/$rel';
    void put(String path, String text) {
      File(path)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(text);
    }

    /// 平板的目录 [kMine]：`v4/` 根（[withV4Meta] 时有带集合标识的 meta）+ 平板自己的说明文件；旧根 `v2/` 里 old 的
    /// 说明文件与段；旧根 `v3/` 里一台老一些的新代设备 g4 的说明文件，它在 `v4/devices/` 下只有 head。
    void layTablet({required bool withV4Meta}) {
      if (withV4Meta) {
        put(
          dirOf(kMine, '$kSrs4Root/meta.json'),
          '{"collection":"$kTabCollection","v":4}',
        );
      }
      put(
        dirOf(kMine, '$kSrs4Root/devices/tab/$kSrsProfileInfoName'),
        '{"v":1,"name":"Default","hasNotes":false,"device":"Pad","notes":0}',
      );
      put(
        dirOf(kMine, '$kSrs4Root/devices/g4/head-000000000001-00000000.json'),
        '{}',
      );
      put(
        dirOf(kMine, '$kSrsSync2Folder/devices/g4/$kSrsProfileInfoName'),
        '{"v":1,"name":"Default","hasNotes":false,"device":"Old pad"}',
      );
      put(
        dirOf(kMine, '$kSrsSync2V1Folder/devices/old/$kSrsProfileInfoName'),
        '{"v":1,"name":"Stale","hasNotes":true,"device":"Gone","notes":38}',
      );
      put(dirOf(kMine, '$kSrsSync2V1Folder/devices/old/seg-1-38.bin'), 'x');
      put(
        dirOf(kOther, '$kSrs4Root/meta.json'),
        '{"collection":"$kPcCollection","v":4}',
      );
      put(
        dirOf(kOther, '$kSrs4Root/devices/pc/$kSrsProfileInfoName'),
        '{"v":1,"name":"Default","hasNotes":true,"device":"PC","notes":15377}',
      );
    }

    SrsProfileLinkDecision decideTablet(List<SrsRemoteProfile> remote) =>
        srsDecideProfileLink(
          localUid: kMine,
          localName: 'Default',
          deviceId: 'tablet-install',
          v2Device: 'tab',
          localHasNotes: false,
          localProfileCount: 1,
          remote: remote,
          ownCollection: kTabCollection,
        );

    test('立了新代根的目录：只在旧根里的写入者已退役，不算成员、不采信它的说明文件', () async {
      layTablet(withV4Meta: true);
      final SrsRemoteProfile tab = (await srsListRemoteProfiles(
        store,
      )).firstWhere((SrsRemoteProfile r) => r.uid == kMine);
      expect(tab.writers.toSet(), <String>{
        srsV2WriterName('tab'),
        srsV2WriterName('g4'),
        srsV2WriterName('old'),
      }, reason: '写入者清单照旧列全（孤儿清理按它判「只有本设备写过」）');
      expect(tab.retiredWriters, <String>{srsV2WriterName('old')});
      expect(tab.stayingWriters.toSet(), <String>{
        srsV2WriterName('tab'),
        srsV2WriterName('g4'),
      }, reason: 'g4 的说明文件还在旧根，但它在 v4/devices 下有设备目录：仍在新代根上同步');
      expect(tab.hasNotes, isFalse);
      expect(tab.noteCount, 0);
      expect(tab.names, <String>{'Default'});
      expect(tab.nameOf.containsKey(srsV2WriterName('old')), isFalse);
      expect(tab.devices.toSet(), <String>{'Pad', 'Old pad'});
    });

    test('平板只剩自己与退役写入者：不再判「已关联」，采用电脑那份有数据的集合', () async {
      layTablet(withV4Meta: true);
      // 平板目录里只剩平板自己与退役的 old（g4 是另一台仍在同步的设备：有它就确实已关联）。
      Directory(
        dirOf(kMine, '$kSrs4Root/devices/g4'),
      ).deleteSync(recursive: true);
      Directory(dirOf(kMine, kSrsSync2Folder)).deleteSync(recursive: true);
      final SrsProfileLinkDecision d = decideTablet(
        await srsListRemoteProfiles(store),
      );
      expect(d, isA<SrsProfileLinkAdopt>());
      expect((d as SrsProfileLinkAdopt).uid, kOther);
    });

    test('还没立新代根的目录（只有旧根、读不到 v4 meta）：旧根里的写入者照旧是成员', () async {
      layTablet(withV4Meta: false);
      final SrsRemoteProfile tab = (await srsListRemoteProfiles(
        store,
      )).firstWhere((SrsRemoteProfile r) => r.uid == kMine);
      expect(tab.retiredWriters, isEmpty);
      expect(tab.stayingWriters, contains(srsV2WriterName('old')));
      expect(tab.hasNotes, isTrue);
      expect(tab.noteCount, 38);
    });

    test('纯函数：本机目录里别的写入者全已退役时不算已关联', () {
      const SrsRemoteProfile pc = SrsRemoteProfile(
        uid: kOther,
        writers: <String>['v2:pc'],
        names: <String>{'Default'},
        hasNotes: true,
        collection: kPcCollection,
      );
      expect(
        decideTablet(const <SrsRemoteProfile>[
          SrsRemoteProfile(
            uid: kMine,
            writers: <String>['v2:old', 'v2:tab'],
            retiredWriters: <String>{'v2:old'},
            collection: kTabCollection,
          ),
          pc,
        ]),
        isA<SrsProfileLinkAdopt>(),
      );
      // 对照：同一个写入者没退役（还在新代根上同步）就是已关联。
      final SrsProfileLinkDecision linked = decideTablet(
        const <SrsRemoteProfile>[
          SrsRemoteProfile(
            uid: kMine,
            writers: <String>['v2:old', 'v2:tab'],
            collection: kTabCollection,
          ),
          pc,
        ],
      );
      expect(linked, isA<SrsProfileLinkKeep>());
      expect((linked as SrsProfileLinkKeep).linked, isTrue);
    });
  });
}

/// 把 [listChildren] 按名字正序或逆序返回的本地目录后端：模拟不同机器上的目录列举顺序（`listSync` 不排序）。
class _OrderedDirectoryStore extends LocalDirectoryAssetStore {
  _OrderedDirectoryStore(super.root, {required this.reversed});

  final bool reversed;

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async {
    final List<AssetEntry> out = await super.listChildren(namespaceId)
      ..sort((AssetEntry a, AssetEntry b) => a.name.compareTo(b.name));
    return reversed ? out.reversed.toList() : out;
  }
}
