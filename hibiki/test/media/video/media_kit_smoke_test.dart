import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

/// Phase 0 / Task 0 smoke coverage for the media_kit video backend.
///
/// 纯 `flutter test` 宿主不带 libmpv-2.dll（Windows）/ libmpv（其它平台）原生库，
/// 因此 `MediaKit.ensureInitialized()` 与 `Player()` 构造在测试宿主下必然抛
/// "Cannot find libmpv-2.dll"。这是已知平台限制，不是代码缺陷 —— 真实的
/// Player 构造/初始化已降级到设备 spike（见 docs/specs/media_kit-api-notes.md）。
///
/// 这里只做不依赖原生库的链接级冒烟：确认 media_kit 包已正确解析、`Player`
/// 与 `Media` 符号可引用、依赖链编译通过；真实初始化用 skip 标注留待设备验证。
void main() {
  test('media_kit symbols are linked (no native lib required)', () {
    // 引用类型常量而不触发原生初始化，证明依赖已正确加入构建图。
    expect(Player, isNotNull);
    expect(Media, isNotNull);
  });

  test(
    'media_kit Player can be constructed and disposed',
    () async {
      MediaKit.ensureInitialized();
      final Player player = Player();
      expect(player, isNotNull);
      await player.dispose();
    },
    // 测试宿主无 libmpv 原生库，构造必抛；真实验证走设备 spike。
    skip: 'Player 构造需真实设备/libmpv 原生库，已降级到设备 spike（见 '
        'docs/specs/media_kit-api-notes.md）',
  );
}
