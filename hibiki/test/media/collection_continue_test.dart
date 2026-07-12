import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/collections/collection_continue.dart';

CollectionMemberProgress _m({int? pos, bool done = false}) =>
    CollectionMemberProgress(positionMs: pos, completed: done);

void main() {
  test('空列表 → 0', () {
    expect(continueMemberIndex(const <CollectionMemberProgress>[]), 0);
  });

  test('全无痕迹 → 从头 0', () {
    expect(
      continueMemberIndex(<CollectionMemberProgress>[_m(), _m(pos: 0), _m()]),
      0,
    );
  });

  test('中途有进度 → 停在最靠后的有痕迹成员', () {
    expect(
      continueMemberIndex(<CollectionMemberProgress>[
        _m(pos: 500),
        _m(pos: 120),
        _m(),
      ]),
      1,
    );
  });

  test('最靠后有痕迹成员已完成且后面还有 → 下一个', () {
    expect(
      continueMemberIndex(<CollectionMemberProgress>[
        _m(done: true),
        _m(done: true),
        _m(),
      ]),
      2,
    );
  });

  test('全部完成 → 停在最后一个（没有下一个）', () {
    expect(
      continueMemberIndex(<CollectionMemberProgress>[
        _m(done: true),
        _m(done: true),
        _m(done: true),
      ]),
      2,
    );
  });

  test('进度在前、后面有已完成成员 → 停在最靠后已完成（不回退到进度）', () {
    // 成员3完成 → 索引2是最靠后痕迹且完成 → 无下一个 → 停 2。
    expect(
      continueMemberIndex(<CollectionMemberProgress>[
        _m(pos: 300),
        _m(),
        _m(done: true),
      ]),
      2,
    );
  });
}
