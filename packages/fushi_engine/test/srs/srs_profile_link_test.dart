// 复习同步的 profile 关联（铁律 E）：profileUid 每台设备本机随机生成，同步目录按 uid 分区，
// 不关联时两台设备各写各的目录、复习数据从不互通。
import 'dart:io';

import 'package:fushi_engine/srs/srs_profile_link.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
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

    test('发布后列得出名字与有无笔记；说明文件落在同步 v2 的设备目录里', () async {
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
          '${root.path}/$kSrsSync2Namespace/$kOther/$kSrsSync2Folder/devices/'
          'host#1/$kSrsProfileInfoName',
        ).existsSync(),
        isTrue,
      );
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
  });
}
