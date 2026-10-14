import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/collections/collection_member_view.dart';

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
