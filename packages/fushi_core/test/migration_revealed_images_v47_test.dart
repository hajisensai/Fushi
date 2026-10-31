import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart';

/// 图片防剧透遮罩揭开状态持久化（BUG-898）：revealed_images（v47 引入）守护。
///
/// fresh DB：onCreate 的 createAll 已含该表，markImageRevealed /
/// getRevealedImageKeys 往返正确，且按 bookKey 隔离。（v45 -> v47 的升级用例随
/// 最低 schema 门槛 v75 一起删除：低于门槛的库本版本直接拒绝打开。）

void main() {
  test('fresh DB round-trips revealed image keys, isolated per book', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    expect(db.schemaVersion, greaterThanOrEqualTo(47));

    await db.markImageRevealed('book-a', 'OEBPS/images/foo.jpg', 1000);
    await db.markImagesRevealed('book-a', <String>[
      'OEBPS/images/bar.png',
      'cover.svg',
    ], 2000);
    await db.markImageRevealed('book-b', 'OEBPS/images/foo.jpg', 3000);

    expect(await db.getRevealedImageKeys('book-a'), <String>{
      'OEBPS/images/foo.jpg',
      'OEBPS/images/bar.png',
      'cover.svg',
    });
    expect(await db.getRevealedImageKeys('book-b'), <String>{
      'OEBPS/images/foo.jpg',
    }, reason: '不同书的相同 imageKey 各自独立，互不影响');

    // 幂等：重复揭开同 key 刷新时间戳、不产生重复行。
    await db.markImageRevealed('book-a', 'cover.svg', 9999);
    expect((await db.getRevealedImageKeys('book-a')).length, 3);
  });
}
