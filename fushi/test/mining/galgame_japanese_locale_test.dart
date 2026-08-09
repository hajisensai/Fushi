import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_japanese_locale.dart';

/// BUG-1477 守卫：转区必须**有开关**，且 `auto` 的判据不能再把「32 位」当成
/// 「日文原版」的代理。
///
/// 现场：用户下的汉化版 galgame，Hibiki 转区启动后报错闪退，直接双击才能玩。
/// 老判据是 `launchMode && automaticJapaneseLocale && exeIs32Bit(exe)`，而
/// `automaticJapaneseLocale` 默认 true 且**整条 UI→source 通路上根本没有这个形参**——
/// 不是「忘了传」，是没有这个自由度。汉化版恰好落在最坏格：32 位（老引擎）+
/// 字符串已转成 GBK/UTF-8，套 CP932 让游戏解出非法序列、字表索引越界直接崩。
void main() {
  group('resolveJapaneseLocale', () {
    test('attach 模式（非 launch）永远不转区——进程早就建好了', () {
      for (final GalJapaneseLocaleMode mode in GalJapaneseLocaleMode.values) {
        expect(
          resolveJapaneseLocale(
            mode: mode,
            launchMode: false,
            is32Bit: true,
          ),
          isFalse,
          reason: '$mode 下 attach 也必须短路——这是用户当前唯一的临时绕法',
        );
      }
    });

    test('off：即便 32 位、即便系统不是日文区，也绝不转区（汉化版选这档）', () {
      expect(
        resolveJapaneseLocale(
          mode: GalJapaneseLocaleMode.off,
          launchMode: true,
          is32Bit: true,
          systemAnsiCodePage: 936,
        ),
        isFalse,
      );
    });

    test('on：launch 模式下一律转区，不看位数', () {
      expect(
        resolveJapaneseLocale(
          mode: GalJapaneseLocaleMode.on,
          launchMode: true,
          is32Bit: false,
          systemAnsiCodePage: 936,
        ),
        isTrue,
        reason: '「不看位数」是有意的：将来 Locale Emulator 有 x64 版时自然生效',
      );
    });

    group('auto', () {
      test('系统 ACP 已是 932 ⇒ 不转区（本就日文区，转了纯属多一层失败面）', () {
        expect(
          resolveJapaneseLocale(
            mode: GalJapaneseLocaleMode.auto,
            launchMode: true,
            is32Bit: true,
            systemAnsiCodePage: 932,
          ),
          isFalse,
        );
      });

      test('64 位 ⇒ 不转区（Locale Emulator 只有 x86 版，这是工程限制）', () {
        expect(
          resolveJapaneseLocale(
            mode: GalJapaneseLocaleMode.auto,
            launchMode: true,
            is32Bit: false,
            systemAnsiCodePage: 936,
          ),
          isFalse,
        );
      });

      test('32 位 + 非日文系统 ⇒ 转区（保住 BUG-1038 的既有行为）', () {
        expect(
          resolveJapaneseLocale(
            mode: GalJapaneseLocaleMode.auto,
            launchMode: true,
            is32Bit: true,
            systemAnsiCodePage: 936,
          ),
          isTrue,
        );
      });

      test('拿不到 ACP（null）时不因此改变结论', () {
        expect(
          resolveJapaneseLocale(
            mode: GalJapaneseLocaleMode.auto,
            launchMode: true,
            is32Bit: true,
          ),
          isTrue,
        );
      });
    });
  });

  group('档位 key 编解码', () {
    test('三档往返稳定', () {
      for (final GalJapaneseLocaleMode mode in GalJapaneseLocaleMode.values) {
        expect(
          galJapaneseLocaleModeFromKey(galJapaneseLocaleModeToKey(mode)),
          mode,
        );
      }
    });

    test('key 是稳定字面量，不是 enum.name/index', () {
      // 钉死落库值：改枚举名或调顺序都不得改变已入库数据的含义。
      expect(galJapaneseLocaleModeToKey(GalJapaneseLocaleMode.auto), 'auto');
      expect(galJapaneseLocaleModeToKey(GalJapaneseLocaleMode.on), 'on');
      expect(galJapaneseLocaleModeToKey(GalJapaneseLocaleMode.off), 'off');
    });

    test('空串/null/脏值一律回落 auto，不是 off', () {
      // 老行（v75 迁移回填的空串）必须映射成「和以前一样自动」。回落到 off
      // 等于把一个用户一直在用的功能（BUG-1038）静默关掉 = 破坏用户空间。
      expect(galJapaneseLocaleModeFromKey(''), GalJapaneseLocaleMode.auto);
      expect(galJapaneseLocaleModeFromKey(null), GalJapaneseLocaleMode.auto);
      expect(
        galJapaneseLocaleModeFromKey('未来新档位'),
        GalJapaneseLocaleMode.auto,
      );
      expect(kGalDefaultJapaneseLocaleMode, GalJapaneseLocaleMode.auto);
    });
  });
}
