import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/interconnect/interconnect_manga_source.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/sync/adopted_manga_tombstone_alias.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';

/// 电脑上「从所有设备删除」一部在线漫画，手机上经互联收下的那一份没被删：收下的行
/// 键是 `interconnect-…`，电脑墓碑键是 `mihon-…`，求交恒空、确认框都不弹。
void main() {
  const String peerKey = 'mihon-b97e8fd21348ddb21f658beedf9ca3e7';
  final String book = SyncTombstoneKind.book.dbValue;

  test('换算与「收下」时实际建行的 bookKey 逐字一致', () {
    const RemoteBookInfo remote = RemoteBookInfo(
      title: '志乃と恋',
      bookKey: peerKey,
      hasContent: false,
      format: 'manga',
      hasMangaChapters: true,
    );
    expect(
      InterconnectMangaCatalog.localBookKeyFor(peerKey),
      OnlineMangaLibraryService.bookKeyOf(
        InterconnectMangaCatalog.entryFor(remote),
      ),
    );
  });

  test('对端在线漫画墓碑命中本机收下的行 → 产出 deleteLocal 候选（本机键）', () {
    final String localKey = InterconnectMangaCatalog.localBookKeyFor(peerKey);
    final DeletionTombstoneEntries remote = <String, Map<String, int>>{
      book: <String, int>{peerKey: 2000},
    };
    final DeletionPresentEntries present = <String, Map<String, int?>>{
      book: <String, int?>{localKey: 1000, 'other-book': 500},
    };

    // 修复前的行为：求交为空。
    expect(
      computeDeletionPropagation(
        localTombstones: const <String, Map<String, int>>{},
        remoteTombstones: remote,
        localPresent: present,
        remotePresent: const <String, Map<String, int?>>{},
      ),
      isEmpty,
    );

    aliasAdoptedInterconnectMangaTombstones(remote, present);
    final List<DeletionPropagationCandidate> candidates =
        computeDeletionPropagation(
          localTombstones: const <String, Map<String, int>>{},
          remoteTombstones: remote,
          localPresent: present,
          remotePresent: const <String, Map<String, int?>>{},
        );
    expect(candidates, hasLength(1));
    expect(candidates.single.mediaType, book);
    expect(candidates.single.itemKey, localKey);
    expect(
      candidates.single.direction,
      DeletionPropagationDirection.deleteLocal,
    );
    // 基线守卫按 remoteTombstones[mediaType][itemKey] 取时刻，别名必须带上 deletedAt。
    expect(remote[book]![localKey], 2000);
  });

  test('收下之后又在本机重新加回（晚于墓碑）→ 不出候选（BUG-2044 仲裁照常）', () {
    final String localKey = InterconnectMangaCatalog.localBookKeyFor(peerKey);
    final DeletionTombstoneEntries remote = <String, Map<String, int>>{
      book: <String, int>{peerKey: 2000},
    };
    final DeletionPresentEntries present = <String, Map<String, int?>>{
      book: <String, int?>{localKey: 3000},
    };
    aliasAdoptedInterconnectMangaTombstones(remote, present);
    expect(
      computeDeletionPropagation(
        localTombstones: const <String, Map<String, int>>{},
        remoteTombstones: remote,
        localPresent: present,
        remotePresent: const <String, Map<String, int?>>{},
      ),
      isEmpty,
    );
  });

  test('本机自己也加过同一部（原键在库）→ 不追加别名，免得一条删除弹两次', () {
    final String localKey = InterconnectMangaCatalog.localBookKeyFor(peerKey);
    final DeletionTombstoneEntries remote = <String, Map<String, int>>{
      book: <String, int>{peerKey: 2000},
    };
    final DeletionPresentEntries present = <String, Map<String, int?>>{
      book: <String, int?>{peerKey: 1000, localKey: 1000},
    };
    aliasAdoptedInterconnectMangaTombstones(remote, present);
    expect(remote[book], <String, int>{peerKey: 2000});
  });

  test('本机没有收下的行 → 墓碑原样不动', () {
    final DeletionTombstoneEntries remote = <String, Map<String, int>>{
      book: <String, int>{peerKey: 2000},
    };
    aliasAdoptedInterconnectMangaTombstones(remote, <String, Map<String, int?>>{
      book: <String, int?>{'unrelated': 1},
    });
    expect(remote[book], <String, int>{peerKey: 2000});
  });
}
