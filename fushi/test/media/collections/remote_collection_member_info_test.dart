import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/collections/collection_member_view.dart';
import 'package:fushi/src/media/collections/remote_collection_member_info.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/shelf_sort.dart'
    show ShelfReadStatus;
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteAudiobookInfo, RemoteBookInfo;

/// 远端占位成员（对端有、本机没下载）的合集成员信息：
/// - 反馈 vHa0VKme1R：第 2 卷没下载时书架合集卡不算它的进度——host 清单自带的
///   进度必须进 [CollectionMemberInfo]；
/// - 反馈 ky0eLY4LHa：合集详情页三卷都是远端占位，拿不到标题只能按成员行
///   entryKey（对端 bookKey）排，卷序成了 2、1、3——标题必须取 host 的显示名。
void main() {
  test('host 在读的远端书：进度 / 最后阅读 / 阅读状态取 host 清单', () {
    const RemoteBookInfo book = RemoteBookInfo(
      title: 'raw',
      displayTitle: '世界で一番おっぱいが好き！ 2',
      hasContent: true,
      progressPercent: 40,
      progressUpdatedAtMs: 1700,
    );
    final CollectionMemberInfo info = remoteBookMemberInfo(book);
    expect(info.title, '世界で一番おっぱいが好き！ 2');
    expect(info.progress, closeTo(0.4, 1e-9));
    expect(info.lastReadAt, 1700);
    expect(info.completed, isFalse);
    expect(info.readStatus, ShelfReadStatus.reading);
    expect(remoteBookProgressFraction(book), closeTo(0.4, 1e-9));
  });

  test('host 读完（100%）算读完；没读过 / 旧 host 不带进度 → 未读、无进度真值', () {
    expect(
      remoteBookMemberInfo(
        const RemoteBookInfo(
          title: 'a',
          hasContent: true,
          progressPercent: 100,
          progressUpdatedAtMs: 5,
        ),
      ).readStatus,
      ShelfReadStatus.finished,
    );
    final CollectionMemberInfo unread = remoteBookMemberInfo(
      const RemoteBookInfo(title: 'b', hasContent: true),
    );
    expect(unread.progress, isNull);
    expect(unread.lastReadAt, isNull);
    expect(unread.readStatus, ShelfReadStatus.unread);
  });

  test('纯字幕远端有声书：标题取 host 书名，听过才带最后收听时刻', () {
    final CollectionMemberInfo heard = remoteAudiobookMemberInfo(
      const RemoteAudiobookInfo(
        bookKey: '',
        uid: 'u1',
        title: '有声书',
        positionMs: 3000,
        positionUpdatedAtMs: 99,
      ),
    );
    expect(heard.title, '有声书');
    expect(heard.progress, isNull);
    expect(heard.lastReadAt, 99);
    expect(
      remoteAudiobookMemberInfo(
        const RemoteAudiobookInfo(bookKey: '', uid: 'u2', title: 'x'),
      ).lastReadAt,
      isNull,
    );
  });

  test('详情页「按卷号」：三卷都是远端占位时按 host 显示名排卷号，不按 bookKey', () {
    // bookKey（成员行 entryKey）字典序与卷号无关：第 2 卷的键最小。
    const List<(String, String)> members = <(String, String)>[
      ('a-key', "BanG Dream! It's MyGO!!!!! 2"),
      ('b-key', "BanG Dream! It's MyGO!!!!! 1"),
      ('c-key', "BanG Dream! It's MyGO!!!!! 3"),
    ];
    final List<CollectionMemberEntry> entries = <CollectionMemberEntry>[
      for (int i = 0; i < members.length; i++)
        CollectionMemberEntry(
          row: MediaCollectionItemRow(
            collectionId: 1,
            mediaType: 'epub',
            entryKey: members[i].$1,
            sortIndex: i,
            pinnedByUser: false,
          ),
          // 页内现查的元数据（本地四表）没有远端占位，回落成 entryKey。
          title: members[i].$1,
          importedAt: 0,
          info: remoteBookMemberInfo(
            RemoteBookInfo(title: members[i].$2, hasContent: true),
          ),
        ),
    ];
    final List<CollectionMemberEntry> arranged = arrangeCollectionMembers(
      entries,
      sort: CollectionMemberSort.volume,
    );
    expect(
      <String>[for (final CollectionMemberEntry e in arranged) e.row.entryKey],
      <String>['b-key', 'a-key', 'c-key'],
    );
  });
}
