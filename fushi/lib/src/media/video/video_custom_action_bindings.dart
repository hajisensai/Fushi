import 'package:fushi/src/shortcuts/shortcut_action.dart';

/// 视频播放器「快捷键 1..N」自定义动作按钮的绑定表。
///
/// 动机（用户请求）：视频页有近 40 个可执行动作，但控制条只给其中 ~25 个配了具名
/// 按钮，其余只能靠键盘/手柄触发——**手机上没有键盘，那些动作等于不存在**。与其为
/// 每个动作再造一个具名 [VideoControlItem]（枚举无限膨胀，且每加一个动作都要跟着加
/// 按钮），不如给控制条几个**空槽位**，由用户各绑一个动作。
///
/// 数据结构就是一个定长 [slotCount] 的有序表：下标 = 槽位序号（「快捷键1」= 下标 0），
/// 值 = 绑定的动作，`null` = 该槽位未绑定。刻意**不用** `slot1/slot2/slot3` 三个独立
/// 字段或 Map<int, ShortcutAction>：定长列表天然表达「序号连续、可为空、数量固定」，
/// 让越界和缺号这两类特殊情况在构造时就消失。
///
/// 与快捷键注册表（[FushiShortcutRegistry]）的关系：**只共用动作枚举，不共用绑定**。
/// 注册表管的是「哪个键 / 哪个手柄按钮触发这个动作」，本表管的是「哪个屏幕按钮触发
/// 这个动作」，两者正交——用户既可以把「下一句字幕」绑到键盘 N，也可以同时把它放进
/// 快捷键1 按钮，互不影响、互不覆盖。
class VideoCustomActionBindings {
  const VideoCustomActionBindings._(this._actions);

  /// 全空绑定（默认值）：4 个槽位都未绑定，播放器上一个自定义按钮都不显示。
  static const VideoCustomActionBindings empty = VideoCustomActionBindings._(
    <ShortcutAction?>[null, null, null, null],
  );

  /// 槽位数量。与 [VideoControlItem] 里的 `customAction1..4` 一一对应——改这个常量
  /// 必须同步加/删对应的枚举项，守卫测试 `video_custom_action_bindings_test` 会核对
  /// 两侧数量一致（否则会出现「有槽位没按钮」或「有按钮没槽位」的半接线）。
  static const int slotCount = 4;

  /// 定长 [slotCount] 的绑定表，下标 = 槽位序号 - 1。
  final List<ShortcutAction?> _actions;

  /// 槽位 [slotIndex]（0-based）绑定的动作；未绑定或越界返回 null。
  ///
  /// 越界返回 null 而不是抛异常：调用方是渲染路径，持久化里混进脏数据时应当安静地
  /// 不显示按钮，而不是让整个播放器崩掉。
  ShortcutAction? actionAt(int slotIndex) {
    if (slotIndex < 0 || slotIndex >= slotCount) return null;
    return _actions[slotIndex];
  }

  /// 是否一个槽位都没绑定（播放器据此完全跳过自定义按钮渲染）。
  bool get isEmpty => _actions.every((ShortcutAction? a) => a == null);

  /// 返回把槽位 [slotIndex] 改绑成 [action]（null = 解绑）后的新表。不可变对象，
  /// 原表不变——与 [VideoControlLayout] 的写法一致，调用方拿到新值后自行落盘。
  VideoCustomActionBindings withAction(int slotIndex, ShortcutAction? action) {
    if (slotIndex < 0 || slotIndex >= slotCount) return this;
    final List<ShortcutAction?> next = List<ShortcutAction?>.of(_actions);
    next[slotIndex] = action;
    return VideoCustomActionBindings._(
        List<ShortcutAction?>.unmodifiable(next));
  }

  /// 序列化：逗号分隔的动作 key，空槽位写空串（如 `video_next_subtitle,,,`）。
  /// 一个都没绑时返回空串，而不是 `",,,"`——让「全空」只有一种写法，与偏好的默认值
  /// （空串）重合，解绑回初始态后存储里不留一条看着像配置过的垃圾。
  ///
  /// 用 [ShortcutAction.key] 而不是枚举下标：枚举声明序会因为设置页分组排序而变动
  /// （[ShortcutAction] 头部明确写了「声明顺序 = 展示顺序」），存下标等于把持久化
  /// 绑死在展示顺序上，重排一次所有用户的绑定就全串位。
  String encode() => isEmpty
      ? ''
      : _actions.map((ShortcutAction? a) => a?.key ?? '').join(',');

  /// 反序列化。空串 / 格式不符 / 未知 key（动作被删或改名）一律降级成未绑定槽位，
  /// 绝不抛异常——这条路径在 app 启动读偏好时跑，抛了就是白屏。
  ///
  /// 长度不匹配时按位截断 / 补空：老配置槽位少于 [slotCount] 时后面补 null，多于时
  /// 丢弃超出部分，保证任何历史 payload 都能解出一张合法的定长表。
  factory VideoCustomActionBindings.decode(String raw) {
    if (raw.isEmpty) return empty;
    final List<String> parts = raw.split(',');
    final List<ShortcutAction?> actions = <ShortcutAction?>[
      for (int i = 0; i < slotCount; i++)
        i < parts.length ? _actionFrom(parts[i]) : null,
    ];
    return VideoCustomActionBindings._(
      List<ShortcutAction?>.unmodifiable(actions),
    );
  }

  /// 单个槽位的 key → 动作。空串 = 未绑定；未知 key = 未绑定（不是错误：动作可能在
  /// 新版里被删掉，老配置照样要能读）。
  static ShortcutAction? _actionFrom(String key) {
    final String trimmed = key.trim();
    if (trimmed.isEmpty) return null;
    return ShortcutAction.fromKey(trimmed);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! VideoCustomActionBindings) return false;
    for (int i = 0; i < slotCount; i++) {
      if (_actions[i] != other._actions[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_actions);

  @override
  String toString() => 'VideoCustomActionBindings(${encode()})';
}
