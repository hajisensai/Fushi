import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/collections/collection_member_view.dart';
import 'package:fushi_core/fushi_core.dart';

/// 系列封面 / 「继续」目标共用的判据：看到第五本，封面与继续都指第五本。
void main() {
  int? pick(List<CollectionMemberInfo?> infos) =>
      pickContinueIndex<CollectionMemberInfo?>(
        infos,
        (CollectionMemberInfo? info) => info,
      );

  test('空列表 null', () {
    expect(pick(const <CollectionMemberInfo?>[]), isNull);
  });

  test('最近读过且未读完的那本优先', () {
    expect(
      pick(const <CollectionMemberInfo?>[
        CollectionMemberInfo(completed: true, lastReadAt: 900),
        CollectionMemberInfo(lastReadAt: 100),
        CollectionMemberInfo(),
        CollectionMemberInfo(),
        CollectionMemberInfo(lastReadAt: 500),
      ]),
      4,
    );
  });

  test('读完的成员不算继续目标，即使最近读过', () {
    expect(
      pick(const <CollectionMemberInfo?>[
        CollectionMemberInfo(lastReadAt: 100),
        CollectionMemberInfo(completed: true, lastReadAt: 999),
      ]),
      0,
    );
  });

  test('没有阅读时间时取第一本未读完的', () {
    expect(
      pick(const <CollectionMemberInfo?>[
        null,
        CollectionMemberInfo(completed: true),
        CollectionMemberInfo(),
      ]),
      2,
    );
  });

  test('没有在读的：取最后读的那本（即使已读完），不回落首本', () {
    expect(
      pick(const <CollectionMemberInfo?>[
        CollectionMemberInfo(completed: true, lastReadAt: 100),
        CollectionMemberInfo(completed: true, lastReadAt: 200),
        null,
        null,
      ]),
      1,
    );
  });

  test('最近读的那本已读完、后面有未读的已下载卷：接着读下一卷，不重开读完的', () {
    expect(
      pick(const <CollectionMemberInfo?>[
        CollectionMemberInfo(completed: true, lastReadAt: 100),
        CollectionMemberInfo(completed: true, lastReadAt: 200),
        null,
        CollectionMemberInfo(),
        CollectionMemberInfo(),
      ]),
      3,
    );
    // 「后面」按合集顺序看：读完的那本**之前**的未读卷不算接着读的目标。
    expect(
      pick(const <CollectionMemberInfo?>[
        CollectionMemberInfo(),
        CollectionMemberInfo(completed: true, lastReadAt: 200),
        null,
      ]),
      1,
    );
  });

  test('整体进度分母是全部成员：没信息 / 进度未知的在读按 0 计入', () {
    CollectionMemberEntry entry(String key, CollectionMemberInfo? info) =>
        CollectionMemberEntry(
          row: MediaCollectionItemRow(
            collectionId: 1,
            mediaType: 'epub',
            entryKey: key,
            sortIndex: 0,
          ),
          title: key,
          importedAt: 0,
          info: info,
        );
    final ({int finished, int counted, double? progress}) s =
        summarizeCollectionMembers(<CollectionMemberEntry>[
          entry('a', const CollectionMemberInfo(completed: true)),
          entry('b', const CollectionMemberInfo(completed: true)),
          entry('c', const CollectionMemberInfo(lastReadAt: 5)),
          entry('d', null),
        ]);
    expect(s.finished, 2);
    expect(s.progress, 0.5);
    expect(
      summarizeCollectionMembers(<CollectionMemberEntry>[
        entry('x', null),
      ]).progress,
      isNull,
    );
  });

  test('全读完 / 全无信息时回落首本', () {
    expect(
      pick(const <CollectionMemberInfo?>[
        CollectionMemberInfo(completed: true),
        CollectionMemberInfo(completed: true),
      ]),
      0,
    );
    expect(pick(const <CollectionMemberInfo?>[null, null]), 0);
  });

  test('pickContinueMember 与 pickContinueIndex 同口径', () {
    expect(pickContinueMember(const <CollectionMemberEntry>[]), isNull);
  });
}
