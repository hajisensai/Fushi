import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/collections/collection_continue.dart';

CollectionMemberProgress _m({
  int? pos,
  bool done = false,
  int? at,
  int? duration,
}) => CollectionMemberProgress(
  positionMs: pos,
  completed: done,
  lastPlayedAt: at,
  durationMs: duration,
);

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

  // ── BUG-1542：锚点是「最近播放的那一集」，不是「位置最靠后的有痕迹成员」 ──
  group('BUG-1542 最近播放时刻锚点', () {
    test('用户回头看靠前的一集 → 选那一集，不被靠后的陈旧痕迹钉死', () {
      // 用户实报形状：234 集合集，靠后某集有陈旧痕迹，用户刚退出的是第 0 集
      // （PV）。旧口径取「位置最靠后的有痕迹成员」→ 选到末尾那集（截图里的
      // 「继续看 第233集」）；正确答案是刚退出的那一集。
      expect(
        continueMemberIndex(<CollectionMemberProgress>[
          _m(pos: 24000, at: 2000), // 刚退出：时刻最新
          _m(),
          _m(pos: 500, at: 1000), // 很久以前看过一点
          _m(done: true, at: 900),
        ]),
        0,
      );
    });

    test('最近播放的那集已完成 → 推进下一集（正常收尾仍然前进）', () {
      expect(
        continueMemberIndex(<CollectionMemberProgress>[
          _m(pos: 300, at: 1000),
          _m(done: true, at: 5000), // 最近一次就是把它看完
          _m(),
        ]),
        2,
      );
    });

    test('最近播放的是已完成的最后一集 → 停在它（没有下一集）', () {
      expect(
        continueMemberIndex(<CollectionMemberProgress>[
          _m(done: true, at: 1000),
          _m(done: true, at: 5000),
        ]),
        1,
      );
    });

    test('先看完靠后一集、再回头看靠前一集到一半 → 选靠前那一集', () {
      expect(
        continueMemberIndex(<CollectionMemberProgress>[
          _m(),
          _m(pos: 60000, at: 9000), // 后看的：未完成
          _m(),
          _m(done: true, at: 8000), // 先看完的
        ]),
        1,
      );
    });

    test('时刻并列 → 取位置靠后者（贴连播方向）', () {
      expect(
        continueMemberIndex(<CollectionMemberProgress>[
          _m(pos: 100, at: 7000),
          _m(pos: 100, at: 7000),
          _m(),
        ]),
        1,
      );
    });

    test('只有部分成员有时刻 → 有时刻的一侧胜出（不被无时刻的靠后痕迹压过）', () {
      expect(
        continueMemberIndex(<CollectionMemberProgress>[
          _m(pos: 24000, at: 2000),
          _m(pos: 300), // 旧行：回填不到时刻
        ]),
        0,
      );
    });

    test('时刻是痕迹：位置被拖回 0 且未完成，仍算播过', () {
      expect(
        continueMemberIndex(<CollectionMemberProgress>[
          _m(),
          _m(pos: 0, at: 3000),
          _m(),
        ]),
        1,
      );
    });

    test('全员无时刻（v85 前旧库）→ 逐字节退回位置口径', () {
      // 与上面 6 条旧断言同源：不喂时刻时行为必须一模一样，否则老库升级即回归。
      expect(
        continueMemberIndex(<CollectionMemberProgress>[
          _m(pos: 500),
          _m(pos: 120),
          _m(),
        ]),
        1,
      );
      expect(
        continueMemberIndex(<CollectionMemberProgress>[
          _m(done: true),
          _m(done: true),
          _m(),
        ]),
        2,
      );
    });
  });

  group('BUG-3491 重看已打勾的集', () {
    const int ep = 24 * 60 * 1000;

    test('重看第 2 集到一半退出 → 继续停在第 2 集，不跳第 3 集', () {
      expect(
        continueMemberIndex(<CollectionMemberProgress>[
          _m(pos: ep, done: true, at: 100, duration: ep),
          _m(pos: 9 * 60 * 1000, done: true, at: 300, duration: ep),
          _m(pos: ep - 1000, done: true, at: 200, duration: ep),
        ]),
        1,
      );
    });

    test('已打勾且断点在片尾区（看完了）→ 照旧推进到下一集', () {
      expect(
        continueMemberIndex(<CollectionMemberProgress>[
          _m(pos: (ep * 0.95).round(), done: true, at: 300, duration: ep),
          _m(),
        ]),
        1,
      );
    });

    test('只剩 3 秒内也算片尾区（与打开时「从头放」同一判据）', () {
      const int movie = 10 * 1000;
      expect(
        continueMemberIndex(<CollectionMemberProgress>[
          _m(pos: movie - 2000, done: true, at: 300, duration: movie),
          _m(),
        ]),
        1,
      );
    });

    test('不知道片长（旧库）→ 沿用旧口径推进到下一集', () {
      expect(
        continueMemberIndex(<CollectionMemberProgress>[
          _m(pos: 9 * 60 * 1000, done: true, at: 300),
          _m(),
        ]),
        1,
      );
    });

    test('没打勾但进度到片尾区（所有者拍板：播放不再自动打勾）→ 推进到下一集', () {
      expect(
        continueMemberIndex(<CollectionMemberProgress>[
          _m(pos: ep - 60 * 1000, at: 300, duration: ep),
          _m(),
        ]),
        1,
      );
    });

    test('没打勾、不知道片长 → 不推断，停在它', () {
      expect(
        continueMemberIndex(<CollectionMemberProgress>[
          _m(pos: ep - 60 * 1000, at: 300),
          _m(),
        ]),
        0,
      );
    });

    test('reachedEnd / countsAsWatched 真值表', () {
      expect(_m(pos: ep - 60 * 1000, duration: ep).reachedEnd, isTrue);
      expect(_m(pos: ep - 60 * 1000, duration: ep).countsAsWatched, isTrue);
      expect(_m(pos: ep - 60 * 1000, duration: ep).completed, isFalse);
      expect(_m(pos: ep - 60 * 1000).reachedEnd, isFalse);
      expect(_m(pos: 1000, duration: ep).countsAsWatched, isFalse);
      expect(
        _m(pos: 1000, done: true, duration: ep).countsAsWatched,
        isTrue,
        reason: '手动标记看完的集重看到一半仍计入已看',
      );
      expect(_m(done: true).countsAsWatched, isTrue);
    });

    test('isRewatching / isFinished 真值表', () {
      expect(_m(pos: 1000, done: true, duration: ep).isRewatching, isTrue);
      expect(_m(pos: 1000, done: true, duration: ep).isFinished, isFalse);
      expect(_m(pos: 0, done: true, duration: ep).isFinished, isTrue);
      expect(_m(pos: ep, done: true, duration: ep).isFinished, isTrue);
      expect(_m(pos: 1000, done: true).isFinished, isTrue);
      expect(_m(pos: 1000, duration: ep).isRewatching, isFalse);
      expect(_m(pos: 1000, duration: ep).isFinished, isFalse);
      expect(_m(pos: ep - 1000, duration: ep).isFinished, isTrue);
    });
  });
}
