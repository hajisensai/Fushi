/// 偏好键登记表的类型（架构重构 F1，见
/// `docs/specs/2026-11-28-architecture-redesign.md`）。
///
/// `preferences` 是一张 `(key, value)` 万能表。一个键的属性（随不随 Profile、能不能
/// 跨设备同步、进备份哪一类、是不是凭据、是不是设备本地）以前分散在七八份手写名单里，
/// 新键默认落进「随 Profile 走、可出境」，漏登一处就是静默的串号 / 泄漏。这里把这些
/// 属性和键名放进**同一个声明**：[PrefKey]（一个固定键）或 [PrefKeyFamily]（前缀 +
/// 运行时段 + 后缀的动态键族）。各通道的判定与派生名单都出自 [PrefKeyRegistry] 的同一份
/// 生效策略（[PrefKeyRegistry.has] / [PrefKeyRegistry.select]），不再各写一份。
///
/// 本文件纯 Dart：app 与无头服务端共用。
library;

import 'package:fushi_core/src/database/pref_codec.dart';

/// 键的类别：用户选的设置，还是 app 自己写的状态（进度、标记、缓存、基线、迁移结论）。
///
/// 必填、没有默认值——「忘了归类」写不出来。
enum PrefKind {
  /// 用户的设置。
  setting,

  /// app 写的状态。
  state,
}

/// 键在备份里归哪一类（勾选导出类别时跟着谁走）。进不进备份是另一个正交字段
/// [PrefPolicy.backedUp]。
///
/// **声明顺序就是 [PrefPolicy.merge] 的严格顺序**（越靠后越严，`settings < content <
/// progress`），改顺序等于改合并结果。进度排在内容之后是因为进度类按键族整族处理
/// （不勾进度导出 = 整族剔除）：一个键同时落在进度族和内容族里时必须仍算进度，
/// [PrefTrait.progressBackup] 与 [PrefTrait.outsideSettingsBackup] 才都满足
/// 「合并后成立 ⇔ 命中的某条声明成立」，派生出的名单 / SQL 才和逐键判定一致。
enum PrefBackup {
  /// 归「设置」类别：不勾设置导出时剔除、导入时从备份取。
  settings,

  /// 内容或内容注册表（收藏句、本地音频库、字体目录、书名改名）：不归设置类别，
  /// 跟各自的资产通道走。
  content,

  /// 归「进度」类别（有声书播放位置）。
  progress,
}

/// 一个键在各条出境 / 切换通道上的策略。字段彼此正交，[PrefPolicy.merge] 按「更严」合并。
final class PrefPolicy {
  /// 逐字段声明。不变式（构造期断言）：设备本地或凭据的键不随 Profile、不同步、不进备份；
  /// 安装级的键一定设备本地。
  const PrefPolicy({
    required this.profileScoped,
    required this.syncable,
    required this.backedUp,
    this.backup = PrefBackup.settings,
    this.deviceLocal = false,
    this.credential = false,
    this.installScoped = false,
  }) : assert(
         !(deviceLocal || credential) ||
             (!profileScoped && !syncable && !backedUp),
         'device-local / credential keys never leave this device',
       ),
       assert(
         !installScoped || deviceLocal,
         'install-scoped implies device-local',
       );

  /// 进 Profile 快照（切 Profile 时随之换值 / 被剪枝）。
  final bool profileScoped;

  /// 能作为设置跨设备同步（设置同步、合并导入「包含设置」）。设置同步通道只读这一个
  /// 字段（app 侧 `PortableSettingsPolicy`）；名字形状的兜底排除是登记表的
  /// [PrefShapeRule]，同样并进这个字段。
  final bool syncable;

  /// 进不进备份。false = 任何类别组合下都不出境，导入时保留本机值。
  final bool backedUp;

  /// 进备份时归哪一类。与 [backedUp] 正交：不进备份的键这个字段没有通道读。
  final PrefBackup backup;

  /// 值是这台设备的事实（地址、路径、身份、本机许可……），绝不离开本设备；ctl 读值打码。
  final bool deviceLocal;

  /// 值里有凭据（密码、令牌、API key、私钥）。与 [deviceLocal] 正交：凭据未必在设备本地
  /// 清单里，但同样不出境、ctl 打码。
  final bool credential;

  /// 设备本地里更严的一类：描述**本次安装**的一次性判定，导入设置的覆盖恢复把它清掉、
  /// 下次启动重判。
  final bool installScoped;

  /// 不得离开本设备、ctl 读值必须打码的那一类。
  bool get redacted => deviceLocal || credential;

  /// 普通设置：随 Profile、可同步、进备份设置类。未登记的键也按它处理。
  static const PrefPolicy profile = PrefPolicy(
    profileScoped: true,
    syncable: true,
    backedUp: true,
  );

  /// 不随 Profile、不同步，但随备份设置类恢复：本安装 / 本设备的设置或状态（首启标志、
  /// 界面缩放、更新通道……）与按条目的状态（有声书倍速、合集排序……）。
  static const PrefPolicy unscoped = PrefPolicy(
    profileScoped: false,
    syncable: false,
    backedUp: true,
  );

  /// 随 Profile、不同步、不归备份设置类的内容（内容注册表：收藏句、字体目录……）。
  static const PrefPolicy profileContent = PrefPolicy(
    profileScoped: true,
    syncable: false,
    backedUp: true,
    backup: PrefBackup.content,
  );

  /// 按条目的内容 / 状态，不随 Profile、不同步、不归备份设置类（书名改名）。
  static const PrefPolicy content = PrefPolicy(
    profileScoped: false,
    syncable: false,
    backedUp: true,
    backup: PrefBackup.content,
  );

  /// 进度：不随 Profile、不同步、归备份进度类。
  static const PrefPolicy progress = PrefPolicy(
    profileScoped: false,
    syncable: false,
    backedUp: true,
    backup: PrefBackup.progress,
  );

  /// 不随 Profile、不同步、不进备份，但不是机密（ctl 照常读值）：功能模块开关这类。
  static const PrefPolicy deviceVisible = PrefPolicy(
    profileScoped: false,
    syncable: false,
    backedUp: false,
  );

  /// 设备本地。
  static const PrefPolicy local = PrefPolicy(
    profileScoped: false,
    syncable: false,
    backedUp: false,
    deviceLocal: true,
  );

  /// 设备本地的凭据。
  static const PrefPolicy localCredential = PrefPolicy(
    profileScoped: false,
    syncable: false,
    backedUp: false,
    deviceLocal: true,
    credential: true,
  );

  /// 凭据（不在设备本地清单里）。
  static const PrefPolicy credentialOnly = PrefPolicy(
    profileScoped: false,
    syncable: false,
    backedUp: false,
    credential: true,
  );

  /// 安装级（设备本地 + 导入时清掉）。
  static const PrefPolicy installScopedLocal = PrefPolicy(
    profileScoped: false,
    syncable: false,
    backedUp: false,
    deviceLocal: true,
    installScoped: true,
  );

  /// 只收紧「跨设备同步」这一条通道、其余字段都是合并的单位元：给形状兜底
  /// （[PrefShapeRule]）用，不是给键声明用的预设。
  static const PrefPolicy unsyncableOnly = PrefPolicy(
    profileScoped: true,
    syncable: false,
    backedUp: true,
  );

  /// 两份策略按「更严」合并：任一侧不随 Profile / 不同步 / 不进备份就不，任一侧设备本地 /
  /// 凭据 / 安装级就是；备份类别取 [PrefBackup] 声明顺序里更靠后的一侧。
  ///
  /// 一个键同时落在几个声明里（固定键 + 前缀族、嵌套的前缀族、形状兜底）时按这条合并，
  /// 所以更具体的声明**放不宽**更宽的族已经收紧的通道——防漏优先于防误伤。每个
  /// [PrefTrait] 对这条合并都是单调的（合并后成立 ⇔ 至少一侧成立）。
  PrefPolicy merge(PrefPolicy other) => PrefPolicy(
    profileScoped: profileScoped && other.profileScoped,
    syncable: syncable && other.syncable,
    backedUp: backedUp && other.backedUp,
    backup: backup.index >= other.backup.index ? backup : other.backup,
    deviceLocal: deviceLocal || other.deviceLocal,
    credential: credential || other.credential,
    installScoped: installScoped || other.installScoped,
  );

  @override
  bool operator ==(Object other) =>
      other is PrefPolicy &&
      other.profileScoped == profileScoped &&
      other.syncable == syncable &&
      other.backedUp == backedUp &&
      other.backup == backup &&
      other.deviceLocal == deviceLocal &&
      other.credential == credential &&
      other.installScoped == installScoped;

  @override
  int get hashCode => Object.hash(
    profileScoped,
    syncable,
    backedUp,
    backup,
    deviceLocal,
    credential,
    installScoped,
  );

  @override
  String toString() =>
      'PrefPolicy(profileScoped: $profileScoped, syncable: $syncable, '
      'backedUp: $backedUp, backup: ${backup.name}, '
      'deviceLocal: $deviceLocal, credential: $credential, '
      'installScoped: $installScoped)';
}

/// 各通道向登记表问的「这个键是不是 X」。
///
/// 只收**对 [PrefPolicy.merge] 单调**的性质：合并后成立 ⇔ 参与合并的某一份成立。这样
/// [PrefKeyRegistry.select] 枚举出来的名单（固定键 + 键族 + 形状兜底）与
/// [PrefKeyRegistry.has] 的逐键判定是同一个集合的两种写法，不会各算各的。「备份类别
/// 恰好等于内容」这种非单调的问法在这里写不出来。
enum PrefTrait {
  /// 不进 Profile 快照。
  outsideProfile,

  /// 不作为设置跨设备同步。
  unsyncable,

  /// 任何类别组合下都不进备份、导入时保留本机值。
  notBackedUp,

  /// 备份里不归「设置」类别（内容或进度）。
  outsideSettingsBackup,

  /// 备份里归「进度」类别。
  progressBackup,

  /// 设备本地。
  deviceLocal,

  /// 凭据。
  credential,

  /// 安装级。
  installScoped,

  /// 设备本地或凭据（出境打码）。
  redacted;

  /// [policy] 是否有这条性质。
  bool of(PrefPolicy policy) => switch (this) {
    PrefTrait.outsideProfile => !policy.profileScoped,
    PrefTrait.unsyncable => !policy.syncable,
    PrefTrait.notBackedUp => !policy.backedUp,
    PrefTrait.outsideSettingsBackup => policy.backup != PrefBackup.settings,
    PrefTrait.progressBackup => policy.backup == PrefBackup.progress,
    PrefTrait.deviceLocal => policy.deviceLocal,
    PrefTrait.credential => policy.credential,
    PrefTrait.installScoped => policy.installScoped,
    PrefTrait.redacted => policy.redacted,
  };
}

/// 值在 `preferences.value` 里的编码。
abstract interface class PrefValueCodec<T> {
  /// 解码一条存量值。
  T decode(String raw, T defaultValue);

  /// 编码要写入的值。返回 null = 这个值的持久化形态是**没有这一行**（写入方删行）。
  ///
  /// 契约：`decode(encode(v))` 读回 `v`；缺行由 [PrefKey.decode] 给默认值，所以默认值
  /// 为 null 的键写 null 必须落成缺行，而不是一行空串。
  String? encode(T value);
}

/// [PrefCodec] 的类型标签编码（`b:` / `i:` / `d:` / `s:` / `j:` / `z:`）——
/// `PreferencesRepository.setPref` 与服务端 `ServerPrefs` 写的形态。
final class PrefTaggedCodec<T> implements PrefValueCodec<T> {
  /// 标签编码。
  const PrefTaggedCodec();

  @override
  T decode(String raw, T defaultValue) =>
      PrefCodec.decode<T>(raw, defaultValue);

  @override
  String encode(T value) => PrefCodec.encode(value);
}

/// 不带标签的裸字符串（同步配置、令牌、设备 id 这类直接写原文的键）。
final class PrefRawStringCodec implements PrefValueCodec<String?> {
  /// 裸字符串编码。
  const PrefRawStringCodec();

  @override
  String? decode(String raw, String? defaultValue) => raw;

  @override
  String? encode(String? value) => value;
}

/// 值类型还没声明的键：按 [PrefCodec.decodeUntyped] 的启发式读（与今天
/// `PreferencesRepository.getPref` 的 dynamic 路径同一口径）。类型化读写迁过来时
/// 换成具体的 `PrefKey<T>`；app 侧有「只减不增」的棘轮盯着这类声明的数量。
final class PrefUntypedCodec implements PrefValueCodec<Object?> {
  /// 未声明类型。
  const PrefUntypedCodec();

  @override
  Object? decode(String raw, Object? defaultValue) =>
      PrefCodec.decodeUntyped(raw) ?? defaultValue;

  @override
  String encode(Object? value) => PrefCodec.encode(value);
}

/// 一条登记：一个固定键 [PrefKey] 或一个动态键族 [PrefKeyFamily]。
sealed class PrefKeyDef {
  const PrefKeyDef({required this.policy, required this.kind});

  /// 各通道策略。
  final PrefPolicy policy;

  /// 设置还是状态。
  final PrefKind kind;

  /// [key] 是否属于这条登记。
  bool matches(String key);

  /// 匹配的具体程度：固定键最高，键族按模式长度。[PrefKeyRegistry.lookup] 取最具体的一条。
  int get specificity;

  /// 值类型是否还没声明（[PrefUntypedCodec]）。
  bool get isUntyped;
}

/// 一个固定的偏好键。
final class PrefKey<T> extends PrefKeyDef {
  /// [name] 是持久化键名（存量键名冻结，不改）。
  const PrefKey(
    this.name, {
    required this.defaultValue,
    required super.policy,
    required super.kind,
    PrefValueCodec<T>? codec,
  }) : _codec = codec;

  /// 值类型还没声明的键（见 [PrefUntypedCodec]）。
  static PrefKey<Object?> untyped(
    String name, {
    required PrefPolicy policy,
    required PrefKind kind,
  }) => PrefKey<Object?>(
    name,
    defaultValue: null,
    policy: policy,
    kind: kind,
    codec: const PrefUntypedCodec(),
  );

  /// 裸字符串存放的键（缺行 = null）。
  static PrefKey<String?> raw(
    String name, {
    required PrefPolicy policy,
    required PrefKind kind,
  }) => PrefKey<String?>(
    name,
    defaultValue: null,
    policy: policy,
    kind: kind,
    codec: const PrefRawStringCodec(),
  );

  /// 持久化键名。
  final String name;

  /// 缺行时的值。
  final T defaultValue;

  final PrefValueCodec<T>? _codec;

  /// 编解码；缺省是 [PrefTaggedCodec]。
  PrefValueCodec<T> get codec => _codec ?? PrefTaggedCodec<T>();

  /// 解码一条存量值；null（缺行）给 [defaultValue]。
  T decode(String? raw) =>
      raw == null ? defaultValue : codec.decode(raw, defaultValue);

  /// 编码要写入的值；null = 删掉这一行（见 [PrefValueCodec.encode]）。
  String? encode(T value) => codec.encode(value);

  @override
  bool matches(String key) => key == name;

  @override
  int get specificity => 1 << 30;

  @override
  bool get isUntyped => _codec is PrefUntypedCodec;

  @override
  String toString() => 'PrefKey<$T>($name)';
}

/// 一族动态键：`<prefix><运行时段><suffix>`，或者键里含 [marker] 的一族。
///
/// [prefix] / [suffix] / [marker] 至少给一个；给了几个就要几个同时成立。
final class PrefKeyFamily<T> extends PrefKeyDef {
  /// 动态键族。
  const PrefKeyFamily({
    this.prefix = '',
    this.suffix = '',
    this.marker = '',
    required this.defaultValue,
    required super.policy,
    required super.kind,
    PrefValueCodec<T>? codec,
  }) : _codec = codec,
       assert(
         prefix != '' || suffix != '' || marker != '',
         'a family needs a prefix, a suffix or a marker',
       );

  /// 值类型还没声明的键族。
  static PrefKeyFamily<Object?> untyped({
    String prefix = '',
    String suffix = '',
    String marker = '',
    required PrefPolicy policy,
    required PrefKind kind,
  }) => PrefKeyFamily<Object?>(
    prefix: prefix,
    suffix: suffix,
    marker: marker,
    defaultValue: null,
    policy: policy,
    kind: kind,
    codec: const PrefUntypedCodec(),
  );

  /// 键名前缀。
  final String prefix;

  /// 键名后缀。
  final String suffix;

  /// 键名里必须出现的片段（位置不定的一族，如书名改名 `src:<id>:override_title://…`）。
  final String marker;

  /// 缺行时的值。
  final T defaultValue;

  final PrefValueCodec<T>? _codec;

  /// 编解码；缺省是 [PrefTaggedCodec]。
  PrefValueCodec<T> get codec => _codec ?? PrefTaggedCodec<T>();

  /// 族里 [segment] 对应的完整键（只对前缀 / 后缀族有意义）。
  String keyFor(String segment) {
    assert(marker.isEmpty, 'marker families have no canonical key shape');
    return '$prefix$segment$suffix';
  }

  /// 解码一条存量值；null（缺行）给 [defaultValue]。
  T decode(String? raw) =>
      raw == null ? defaultValue : codec.decode(raw, defaultValue);

  @override
  bool matches(String key) =>
      key.startsWith(prefix) &&
      key.endsWith(suffix) &&
      (marker.isEmpty || key.contains(marker));

  /// 本族是否**整个包住** [inner]：[inner] 匹配的每个键本族都匹配（按模式静态判定，
  /// 只在能证明时返回 true）。登记表据此校验内层族的声明不比外层宽。
  bool encloses(PrefKeyFamily<Object?> inner) =>
      inner.prefix.startsWith(prefix) &&
      inner.suffix.endsWith(suffix) &&
      (marker.isEmpty ||
          inner.prefix.contains(marker) ||
          inner.suffix.contains(marker) ||
          inner.marker.contains(marker));

  @override
  int get specificity => prefix.length + suffix.length + marker.length;

  @override
  bool get isUntyped => _codec is PrefUntypedCodec;

  /// 人读的模式（诊断 / 测试用）。
  String get pattern =>
      marker.isEmpty ? '$prefix*$suffix' : '$prefix*$marker*$suffix';

  @override
  String toString() => 'PrefKeyFamily<$T>($pattern)';
}

/// 名字形状兜底：不看登记、只看键名长什么样的一条策略。命中的键把 [policy] 并进生效策略
/// （[PrefPolicy.merge]，只会更严）。
///
/// 存在的理由：外部导入、扩展、旧版本都会写进没登记的键，运行时段（书名、源 id）里也可能
/// 带着凭据形状——这些键不能因为没登记就出境。
abstract base class PrefShapeRule {
  /// [name] 给诊断与报错用。
  const PrefShapeRule({required this.name, required this.policy});

  /// 规则名。
  final String name;

  /// 命中的键并进来的策略。
  final PrefPolicy policy;

  /// [key] 命中本规则的原因（人读，诊断用）；没命中返回 null。
  String? reasonFor(String key);

  /// [key] 是否命中。
  bool matches(String key) => reasonFor(key) != null;
}

/// 键名（小写）含 [substrings] 任一子串即命中，**不限前缀**。
final class PrefSubstringShapeRule extends PrefShapeRule {
  /// 子串形状规则。
  const PrefSubstringShapeRule({
    required super.name,
    required super.policy,
    required this.substrings,
  });

  /// 小写子串。
  final List<String> substrings;

  @override
  String? reasonFor(String key) {
    final String lower = key.toLowerCase();
    for (final String shape in substrings) {
      if (lower.contains(shape)) return '$name "$shape"';
    }
    return null;
  }
}

/// 一条通道上的全部键：[PrefKeyRegistry.select] 的结果。
///
/// [contains] 是逐键判定；[keys] / [families] / [shapes] 是同一个集合的枚举形态（给要拼
/// SQL、要列清单的通道）。两者由 [PrefTrait] 的单调性保证一致：
/// `contains(k)` ⇔ `k ∈ keys` 或某个 [families] 匹配 `k` 或某条 [shapes] 命中 `k`
/// （[coversUnregistered] 为 true 时再加上「没有任何登记匹配 `k`」）。
final class PrefKeySelection {
  PrefKeySelection._(
    this._registry,
    this.trait, {
    required this.keys,
    required this.families,
    required this.shapes,
    required this.coversUnregistered,
  });

  final PrefKeyRegistry _registry;

  /// 选的是哪条性质。
  final PrefTrait trait;

  /// 有这条性质的固定键名（登记顺序）。
  final List<String> keys;

  /// 有这条性质的键族（按具体程度降序）。
  final List<PrefKeyFamily<Object?>> families;

  /// 有这条性质的形状兜底。
  final List<PrefShapeRule> shapes;

  /// 未登记键的兜底策略本身就有这条性质（那样的集合没法枚举完）。
  final bool coversUnregistered;

  /// 只由固定键与键族就能枚举完（没有形状兜底、不含未登记键）。要把集合翻译成 SQL 的
  /// 通道先确认这一点。
  bool get isEnumerable => shapes.isEmpty && !coversUnregistered;

  /// [key] 是否在这条通道里（按生效策略判定）。
  bool contains(String key) => _registry.has(key, trait);
}

/// 登记表：全部 [PrefKeyDef]，加名字形状兜底（[PrefShapeRule]）。
///
/// 一个键的**生效策略**只有一个算法（[policyOf]）：命中的固定键声明 + 每个匹配的键族 +
/// 每条命中的形状兜底，按 [PrefPolicy.merge] 合并；一条登记都没命中时以 [fallbackPolicy]
/// 起算。各通道只通过两个入口问它，两者同源：
/// - [has]：逐键判定；
/// - [select]：同一条性质的枚举形态（固定键 + 键族 + 形状兜底）。
final class PrefKeyRegistry {
  /// 构造期校验，违反即抛 [StateError]——登记表在启动期构造，测试第一时间就红：
  /// - 固定键名不重复、不为空，键族模式不重复；
  /// - **声明不得比生效策略宽**：固定键声明的策略必须等于它的生效策略（并上所有包住它的
  ///   键族与命中的形状兜底之后不变）；被另一个键族整个包住的键族同理。声明写的是什么，
  ///   各通道判出来的就是什么——名字像凭据却没声明成凭据、落在设备本地族里却声明成普通
  ///   设置，都在这里拦下。
  PrefKeyRegistry(
    Iterable<PrefKeyDef> defs, {
    this.shapeRules = const <PrefShapeRule>[credentialShapeRule],
    this.fallbackPolicy = PrefPolicy.profile,
  }) {
    for (final PrefKeyDef def in defs) {
      switch (def) {
        case PrefKey<Object?>():
          if (def.name.isEmpty) {
            throw StateError('PrefKeyRegistry: empty key name');
          }
          if (_keys.containsKey(def.name)) {
            throw StateError('PrefKeyRegistry: duplicate key "${def.name}"');
          }
          _keys[def.name] = def;
        case PrefKeyFamily<Object?>():
          final String pattern = def.pattern;
          if (_familyPatterns.contains(pattern)) {
            throw StateError('PrefKeyRegistry: duplicate family "$pattern"');
          }
          _familyPatterns.add(pattern);
          _families.add(def);
      }
    }
    // 具体程度降序；同具体度按模式字典序，[lookup] 的结果不依赖排序实现是否稳定。
    _families.sort((PrefKeyFamily<Object?> a, PrefKeyFamily<Object?> b) {
      final int bySpecificity = b.specificity.compareTo(a.specificity);
      return bySpecificity != 0
          ? bySpecificity
          : a.pattern.compareTo(b.pattern);
    });
    for (final PrefKey<Object?> key in _keys.values) {
      final PrefPolicy effective = policyOf(key.name);
      if (effective != key.policy) {
        throw StateError(
          'PrefKeyRegistry: "${key.name}" is declared wider than its '
          'effective policy.\n  declared:  ${key.policy}\n'
          '  effective: $effective\n'
          '  tightened by: ${_contributorsOf(key.name).join(', ')}',
        );
      }
    }
    for (final PrefKeyFamily<Object?> family in _families) {
      for (final PrefKeyFamily<Object?> outer in _families) {
        if (identical(outer, family) || !outer.encloses(family)) continue;
        final PrefPolicy effective = family.policy.merge(outer.policy);
        if (effective != family.policy) {
          throw StateError(
            'PrefKeyRegistry: family "${family.pattern}" is declared wider '
            'than the enclosing family "${outer.pattern}".\n'
            '  declared:  ${family.policy}\n  effective: $effective',
          );
        }
      }
    }
  }

  /// 凭据形状：键（小写）含这些子串即视为凭据，**不限前缀**。
  static const List<String> defaultCredentialShapes = <String>[
    'password',
    'token',
    'secret',
    'private_key',
    'credential',
    'api_key',
  ];

  /// 默认的形状兜底：名字像凭据的键按 [PrefPolicy.credentialOnly] 拦下。
  static const PrefShapeRule credentialShapeRule = PrefSubstringShapeRule(
    name: 'credential shape',
    policy: PrefPolicy.credentialOnly,
    substrings: defaultCredentialShapes,
  );

  /// 本登记表的形状兜底。
  final List<PrefShapeRule> shapeRules;

  /// 未登记键的起算策略。
  final PrefPolicy fallbackPolicy;

  final Map<String, PrefKey<Object?>> _keys = <String, PrefKey<Object?>>{};
  final List<PrefKeyFamily<Object?>> _families = <PrefKeyFamily<Object?>>[];
  final Set<String> _familyPatterns = <String>{};

  /// 全部固定键。
  Iterable<PrefKey<Object?>> get keys => _keys.values;

  /// 全部键族（按具体程度降序，同具体度按模式字典序）。
  List<PrefKeyFamily<Object?>> get families =>
      List<PrefKeyFamily<Object?>>.unmodifiable(_families);

  /// [key] 的登记：固定键优先，否则最具体的键族；未登记返回 null。
  PrefKeyDef? lookup(String key) {
    final PrefKey<Object?>? exact = _keys[key];
    if (exact != null) return exact;
    for (final PrefKeyFamily<Object?> family in _families) {
      if (family.matches(key)) return family;
    }
    return null;
  }

  /// 固定键 [name] 的登记（不查键族）。
  PrefKey<Object?>? keyNamed(String name) => _keys[name];

  /// [key] 的生效策略——各通道判定与派生名单共用的唯一算法（见类文档）。
  PrefPolicy policyOf(String key) {
    PrefPolicy? merged = _keys[key]?.policy;
    for (final PrefKeyFamily<Object?> family in _families) {
      if (!family.matches(key)) continue;
      merged = merged == null ? family.policy : merged.merge(family.policy);
    }
    PrefPolicy policy = merged ?? fallbackPolicy;
    for (final PrefShapeRule rule in shapeRules) {
      if (rule.matches(key)) policy = policy.merge(rule.policy);
    }
    return policy;
  }

  /// [key] 在生效策略下是否有 [trait]。
  bool has(String key, PrefTrait trait) => trait.of(policyOf(key));

  /// 有 [trait] 的全部键的枚举形态；与 [has] 同源（见 [PrefKeySelection]）。
  ///
  /// 固定键的声明已在构造期校验为等于生效策略，所以这里按声明取就是按生效策略取。
  PrefKeySelection select(PrefTrait trait) => PrefKeySelection._(
    this,
    trait,
    keys: List<String>.unmodifiable(<String>[
      for (final PrefKey<Object?> key in _keys.values)
        if (trait.of(key.policy)) key.name,
    ]),
    families:
        List<PrefKeyFamily<Object?>>.unmodifiable(<PrefKeyFamily<Object?>>[
          for (final PrefKeyFamily<Object?> family in _families)
            if (trait.of(family.policy)) family,
        ]),
    shapes: List<PrefShapeRule>.unmodifiable(<PrefShapeRule>[
      for (final PrefShapeRule rule in shapeRules)
        if (trait.of(rule.policy)) rule,
    ]),
    coversUnregistered: trait.of(fallbackPolicy),
  );

  /// 给 [key] 的生效策略出过力的声明（报错用）。
  List<String> _contributorsOf(String key) => <String>[
    for (final PrefKeyFamily<Object?> family in _families)
      if (family.matches(key)) 'family "${family.pattern}"',
    for (final PrefShapeRule rule in shapeRules)
      if (rule.reasonFor(key) case final String reason) reason,
  ];
}
