import 'package:flutter_test/flutter_test.dart';

import '../../tool/i18n_sync.dart';

/// `fushi/tool/i18n_sync.dart` 的命令行契约测试。
///
/// 真 bug（2026-08-19）：`--remove a --remove b --remove c` 只删掉了 `a`，`b` / `c`
/// 被**静默丢弃**——没有报错、没有非零退出码，`Changed 17 files.` 照常打印，
/// 于是「删了 5 个 key」的调用实际只删了 1 个，剩下 4 个留在 17 份 json 里，
/// 直到有人再 grep 才发现。
///
/// 根因不是「一次只能传一个」这种使用限制，而是解析方式本身允许写错：
/// 旧实现 `args.indexOf('--remove')` 只认第一个 flag，再用
/// `args.sublist(idx + 1).where((a) => !a.startsWith('--'))` 把**后面所有**非 flag
/// token 收成一个列表，最后只取 `rest[0]`——多出来的 operand 没有任何归宿，只能被吞。
///
/// 修法是换数据结构：命令行 = 有序 op 列表，逐 token 消费，任何没被 flag 消费的
/// token 都是 usage error。下面的用例锁的就是这两条：**重复 flag 全部生效** +
/// **多余 / 缺失 / 错位的 operand 一律报错而非静默吞掉**。
void main() {
  Map<String, dynamic> table() => <String, dynamic>{
        'alpha': 'A',
        'beta': 'B',
        'gamma': 'C',
      };

  I18nApplyResult run(
    List<String> args,
    Map<String, dynamic> json, {
    bool isZhCn = false,
  }) {
    final I18nCommand command = parseI18nCommand(args);
    return applyI18nOps(
      json: json,
      ops: command.ops,
      isZhCn: isZhCn,
      label: 'strings_test.i18n.json',
    );
  }

  group('重复 flag 全部生效（本次真 bug 的回归）', () {
    test('多个 --remove 全部删除，不再只认第一个', () {
      final I18nCommand command = parseI18nCommand(<String>[
        '--remove',
        'alpha',
        '--remove',
        'beta',
        '--remove',
        'gamma',
      ]);
      expect(command.ops, hasLength(3),
          reason: '三个 --remove 必须解析成三个 op，多出来的不得被丢弃');

      final I18nApplyResult result = run(
        <String>['--remove', 'alpha', '--remove', 'beta', '--remove', 'gamma'],
        table(),
      );
      expect(result.json, isEmpty, reason: '三个 key 必须都被删掉');
      expect(result.hitsPerOp, <int>[1, 1, 1]);
    });

    test('多个 --add 全部写入，且 zh-CN 取中文值', () {
      final I18nApplyResult en = run(
        <String>[
          '--add',
          'one',
          'One',
          '一',
          '--add',
          'two',
          'Two',
          '二',
        ],
        <String, dynamic>{},
      );
      expect(en.json, <String, dynamic>{'one': 'One', 'two': 'Two'});

      final I18nApplyResult zh = run(
        <String>[
          '--add',
          'one',
          'One',
          '一',
          '--add',
          'two',
          'Two',
          '二',
        ],
        <String, dynamic>{},
        isZhCn: true,
      );
      expect(zh.json, <String, dynamic>{'one': '一', 'two': '二'});
    });

    test('不同 flag 混用按给出的顺序执行', () {
      final I18nApplyResult result = run(
        <String>[
          '--remove',
          'beta',
          '--rename',
          'alpha',
          'zeta',
          '--add',
          'delta',
          'D',
          'D中',
          '--sort',
        ],
        table(),
      );
      expect(result.json.keys.toList(), <String>['delta', 'gamma', 'zeta'],
          reason: '删/改名/新增都要落地，且末尾 --sort 对最终结果排序');
      expect(result.hitsPerOp, <int>[1, 1, 1, 1]);
    });

    test('顺序敏感：先改名到 b 再删 b，最终 b 不存在', () {
      final I18nApplyResult result = run(
        <String>['--rename', 'alpha', 'beta2', '--remove', 'beta2'],
        table(),
      );
      expect(result.json.containsKey('beta2'), isFalse);
      expect(result.json.containsKey('alpha'), isFalse);
    });
  });

  group('没有任何参数可以被静默忽略', () {
    test('未知参数报 usage error', () {
      expect(
        () => parseI18nCommand(<String>['--remove', 'alpha', 'stray']),
        throwsA(isA<I18nUsageError>()),
        reason: '多出来的裸 operand 旧实现会吞掉，现在必须报错',
      );
      expect(
        () => parseI18nCommand(<String>['--nope']),
        throwsA(isA<I18nUsageError>()),
      );
    });

    test('缺 operand 报 usage error', () {
      expect(() => parseI18nCommand(<String>['--remove']),
          throwsA(isA<I18nUsageError>()));
      expect(() => parseI18nCommand(<String>['--add', 'k', 'en']),
          throwsA(isA<I18nUsageError>()));
      expect(() => parseI18nCommand(<String>['--rename', 'old']),
          throwsA(isA<I18nUsageError>()));
    });

    test('operand 位置上出现 flag 报错，不会被当成 key 吃掉', () {
      expect(
        () => parseI18nCommand(<String>['--remove', '--dry-run']),
        throwsA(isA<I18nUsageError>()),
        reason: '把 --dry-run 当 key 删掉是最坏的静默失败',
      );
      expect(
        () => parseI18nCommand(<String>['--add', 'k', '--sort', 'zh']),
        throwsA(isA<I18nUsageError>()),
      );
    });

    test('--rename 到同名报错', () {
      expect(
        () => parseI18nCommand(<String>['--rename', 'alpha', 'alpha']),
        throwsA(isA<I18nUsageError>()),
      );
    });
  });

  group('单 op 行为与历史一致（向后兼容）', () {
    test('--dry-run 只是标志位，可出现在任意位置', () {
      expect(parseI18nCommand(<String>['--dry-run', '--remove', 'a']).dryRun,
          isTrue);
      expect(parseI18nCommand(<String>['--remove', 'a', '--dry-run']).dryRun,
          isTrue);
      expect(parseI18nCommand(<String>['--remove', 'a']).dryRun, isFalse);
    });

    test('无参数 = 无 op（走补全缺失 key 模式）', () {
      expect(parseI18nCommand(<String>[]).ops, isEmpty);
      expect(parseI18nCommand(<String>['--dry-run']).ops, isEmpty);
    });

    test('--add 已存在的 key 跳过，不覆盖既有翻译', () {
      final I18nApplyResult result =
          run(<String>['--add', 'alpha', 'NEW', 'NEW中'], table());
      expect(result.json['alpha'], 'A');
      expect(result.hitsPerOp, <int>[0]);
      expect(result.changed, isFalse);
    });

    test('--remove 不存在的 key 不改动该文件', () {
      final I18nApplyResult result = run(<String>['--remove', 'nope'], table());
      expect(result.json, table());
      expect(result.hitsPerOp, <int>[0]);
    });

    test('--rename 目标已存在 → 抛 I18nOpError（整轮中止，不写半份）', () {
      expect(
        () => run(<String>['--rename', 'alpha', 'beta'], table()),
        throwsA(isA<I18nOpError>()),
      );
    });

    test('--rename 保留原值与键序', () {
      final I18nApplyResult result =
          run(<String>['--rename', 'beta', 'beta_renamed'], table());
      expect(
          result.json.keys.toList(), <String>['alpha', 'beta_renamed', 'gamma'],
          reason: '改名必须就地换键，不得把键挪到末尾');
      expect(result.json['beta_renamed'], 'B');
    });

    test('--sort 幂等：已排序的表不算改动', () {
      final I18nApplyResult sorted =
          run(<String>['--sort'], <String, dynamic>{'a': '1', 'b': '2'});
      expect(sorted.changed, isFalse);

      final I18nApplyResult unsorted =
          run(<String>['--sort'], <String, dynamic>{'b': '2', 'a': '1'});
      expect(unsorted.json.keys.toList(), <String>['a', 'b']);
      expect(unsorted.changed, isTrue);
    });

    test('applyI18nOps 不修改传入的 map（预演阶段必须无副作用）', () {
      final Map<String, dynamic> original = table();
      run(<String>['--remove', 'alpha', '--add', 'new', 'N', 'N中'], original);
      expect(original, table(), reason: '入参被就地改掉会让「全读完再写」的原子性失效');
    });
  });
}
