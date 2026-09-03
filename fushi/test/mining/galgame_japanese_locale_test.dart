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

      test('判为需要 + 32 位 + 非日文系统 ⇒ 转区（BUG-1038 的日文原版样本走这格）',
          () {
        expect(
          resolveJapaneseLocale(
            mode: GalJapaneseLocaleMode.auto,
            launchMode: true,
            is32Bit: true,
            systemAnsiCodePage: 936,
            need: GalJapaneseLocaleNeed.needed,
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
            need: GalJapaneseLocaleNeed.needed,
          ),
          isTrue,
        );
      });

      // BUG-2047：语义门在工程门之前。以前「32 位 + 非日文系统」就转，把工程限制当成
      // 了「日文原版」的代理，中文系统上每一个 32 位游戏都被转区。
      test('证据不足（unknown，也是缺省）⇒ 不转区：自动判断不等于全转', () {
        expect(
          resolveJapaneseLocale(
            mode: GalJapaneseLocaleMode.auto,
            launchMode: true,
            is32Bit: true,
            systemAnsiCodePage: 936,
          ),
          isFalse,
          reason: '缺省形参必须是 unknown ⇒ 不转，老调用点不会静默变成「全转区」',
        );
        expect(
          resolveJapaneseLocale(
            mode: GalJapaneseLocaleMode.auto,
            launchMode: true,
            is32Bit: true,
            systemAnsiCodePage: 936,
            need: GalJapaneseLocaleNeed.unknown,
          ),
          isFalse,
        );
      });

      test('判为不需要（汉化 / 多语言 / Unicode 引擎）⇒ 不转区', () {
        expect(
          resolveJapaneseLocale(
            mode: GalJapaneseLocaleMode.auto,
            launchMode: true,
            is32Bit: true,
            systemAnsiCodePage: 936,
            need: GalJapaneseLocaleNeed.notNeeded,
          ),
          isFalse,
        );
      });

      test('判为需要也过不了工程门：64 位 / ACP=932 仍不转', () {
        expect(
          resolveJapaneseLocale(
            mode: GalJapaneseLocaleMode.auto,
            launchMode: true,
            is32Bit: false,
            systemAnsiCodePage: 936,
            need: GalJapaneseLocaleNeed.needed,
          ),
          isFalse,
        );
        expect(
          resolveJapaneseLocale(
            mode: GalJapaneseLocaleMode.auto,
            launchMode: true,
            is32Bit: true,
            systemAnsiCodePage: 932,
            need: GalJapaneseLocaleNeed.needed,
          ),
          isFalse,
        );
      });
    });

    test('on / off 不看 need：用户档位是绝对的', () {
      for (final GalJapaneseLocaleNeed need in GalJapaneseLocaleNeed.values) {
        expect(
          resolveJapaneseLocale(
            mode: GalJapaneseLocaleMode.on,
            launchMode: true,
            is32Bit: true,
            systemAnsiCodePage: 936,
            need: need,
          ),
          isTrue,
          reason: 'on + $need',
        );
        expect(
          resolveJapaneseLocale(
            mode: GalJapaneseLocaleMode.off,
            launchMode: true,
            is32Bit: true,
            systemAnsiCodePage: 936,
            need: need,
          ),
          isFalse,
          reason: 'off + $need',
        );
      }
    });
  });

  group('resolveJapaneseLocaleSkipReason：没转区的原因与 auto 分支逐条对应', () {
    test('语义门：不需要 / 证据不足', () {
      expect(
        resolveJapaneseLocaleSkipReason(
          need: GalJapaneseLocaleNeed.notNeeded,
          is32Bit: true,
          systemAnsiCodePage: 936,
        ),
        GalJapaneseLocaleSkipReason.notNeeded,
      );
      expect(
        resolveJapaneseLocaleSkipReason(
          need: GalJapaneseLocaleNeed.unknown,
          is32Bit: true,
          systemAnsiCodePage: 936,
        ),
        GalJapaneseLocaleSkipReason.unknown,
      );
    });

    test('工程门：判为需要但系统已是 932 / 目标 64 位（改档位也没用，得直说）', () {
      expect(
        resolveJapaneseLocaleSkipReason(
          need: GalJapaneseLocaleNeed.needed,
          is32Bit: true,
          systemAnsiCodePage: 932,
        ),
        GalJapaneseLocaleSkipReason.systemAlreadyJapanese,
      );
      expect(
        resolveJapaneseLocaleSkipReason(
          need: GalJapaneseLocaleNeed.needed,
          is32Bit: false,
          systemAnsiCodePage: 936,
        ),
        GalJapaneseLocaleSkipReason.targetNot32Bit,
      );
    });

    test('判为需要且过了工程门 ⇒ null（其实转了），与 resolveJapaneseLocale 互为补集', () {
      for (final GalJapaneseLocaleNeed need in GalJapaneseLocaleNeed.values) {
        for (final bool is32Bit in <bool>[true, false]) {
          for (final int? acp in <int?>[932, 936, null]) {
            final bool applied = resolveJapaneseLocale(
              mode: GalJapaneseLocaleMode.auto,
              launchMode: true,
              is32Bit: is32Bit,
              systemAnsiCodePage: acp,
              need: need,
            );
            final GalJapaneseLocaleSkipReason? reason =
                resolveJapaneseLocaleSkipReason(
              need: need,
              is32Bit: is32Bit,
              systemAnsiCodePage: acp,
            );
            expect(reason == null, applied, reason: '$need $is32Bit $acp');
          }
        }
      }
    });

    test('reason key 是稳定字面量', () {
      expect(
        GalJapaneseLocaleSkipReason.values
            .map(galJapaneseLocaleSkipReasonToKey)
            .toList(),
        <String>['not_needed', 'unknown', 'acp_932', 'not_32bit'],
      );
    });
  });

  group('need / evidence key 编码', () {
    test('是稳定字面量，不是 enum.name/index', () {
      expect(galJapaneseLocaleNeedToKey(GalJapaneseLocaleNeed.needed), 'needed');
      expect(
        galJapaneseLocaleNeedToKey(GalJapaneseLocaleNeed.notNeeded),
        'not_needed',
      );
      expect(
        galJapaneseLocaleNeedToKey(GalJapaneseLocaleNeed.unknown),
        'unknown',
      );
      expect(
        galJapaneseLocaleEvidenceToKey(
          GalJapaneseLocaleEvidence.dirFileNameChinesePatch,
        ),
        'dir_file_name_chinese_patch',
      );
      // 11 条证据 key 互不相同，且都是 snake_case（i18n 键尾巴直接用它）。
      final Set<String> keys = GalJapaneseLocaleEvidence.values
          .map(galJapaneseLocaleEvidenceToKey)
          .toSet();
      expect(keys, hasLength(GalJapaneseLocaleEvidence.values.length));
      for (final String key in keys) {
        expect(key, matches(RegExp(r'^[a-z0-9]+(_[a-z0-9]+)*$')));
      }
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
