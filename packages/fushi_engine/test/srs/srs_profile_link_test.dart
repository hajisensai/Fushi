// 复习同步的 profile 关联（铁律 E）：profileUid 每台设备本机随机生成，同步目录按 uid 分区，
// 不关联时两台设备各写各的目录、复习数据从不互通。
import 'dart:io';

import 'package:fushi_engine/srs/srs_asset_store_directory.dart';
import 'package:fushi_engine/srs/srs_profile_link.dart';
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
}) => srsDecideProfileLink(
  localUid: kMine,
  localName: localName,
  deviceId: kDevice,
  localHasNotes: localHasNotes,
  localProfileCount: localProfileCount,
  remote: remote,
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
      expect(d, isA<SrsProfileLinkConflict>());
      expect((d as SrsProfileLinkConflict).remoteName, 'Default');
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

    test('发布后列得出名字与有无笔记；写入者目录照常是写入者', () async {
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
      expect(list.single.writers, <String>['host#1']);
      expect(list.single.names, <String>{'Main'});
      expect(list.single.hasNotes, isTrue);
      final SrsAssetStoreDirectory dir = SrsAssetStoreDirectory(
        store: store,
        profileUid: kOther,
      );
      expect(await dir.listWriters(), <String>['host#1']);
    });

    test('清理只删本设备的写入者目录；目录空了整个删', () async {
      for (final String w in <String>['phone#1', 'phone#2']) {
        await srsPublishProfileInfo(
          store,
          profileUid: kMine,
          writerId: w,
          name: 'Default',
          hasNotes: false,
        );
      }
      await srsRemoveOwnProfileFolder(
        store,
        profileUid: kMine,
        deviceId: kDevice,
      );
      expect(
        Directory('${root.path}/$kSrsSyncNamespace/$kMine').existsSync(),
        isFalse,
      );
      await srsPublishProfileInfo(
        store,
        profileUid: kMine,
        writerId: 'phone#3',
        name: 'Default',
        hasNotes: false,
      );
      await srsPublishProfileInfo(
        store,
        profileUid: kMine,
        writerId: 'tab#1',
        name: 'Default',
        hasNotes: false,
      );
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
