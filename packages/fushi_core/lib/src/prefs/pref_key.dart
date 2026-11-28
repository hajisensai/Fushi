/// 偏好键登记表的类型（架构重构 F1，见
/// `docs/specs/2026-11-28-architecture-redesign.md`）。
///
/// `preferences` 是一张 `(key, value)` 万能表。一个键的属性（随不随 Profile、能不能
/// 跨设备同步、进备份哪一类、是不是凭据、是不是设备本地）以前分散在七八份手写名单里，
/// 新键默认落进「随 Profile 走、可出境」，漏登一处就是静默的串号 / 泄漏。这里把这些
/// 属性和键名放进**同一个声明**：[PrefKey]（一个固定键）或 [PrefKeyFamily]（前缀 +
/// 运行时段 + 后缀的动态键族）。各通道的判定都从 [PrefKeyRegistry] 派生，不再各写一份。
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

/// 键在备份里的归属。
enum PrefBackup {
  /// 归「设置」类别：不勾设置导出时剔除、导入时从备份取。
  settings,

  /// 归「进度」类别（有声书播放位置）。
  progress,

  /// 内容或内容注册表（收藏句、本地音频库、字体目录、书名改名）：不归设置类别，
  /// 跟各自的资产通道走。
  content,

  /// 任何类别组合下都不出境，导入时保留本机值。
  never,
}

/// 一个键在各条出境 / 切换通道上的策略。字段彼此正交，[PrefPolicy.merge] 按「更严」合并。
final class PrefPolicy {
  /// 逐字段声明。不变式（构造期断言）：设备本地或凭据的键不随 Profile、不同步、不进备份；
  /// 安装级的键一定设备本地。
  const PrefPolicy({
    required this.profileScoped,
    required this.syncable,
    required this.backup,
    this.deviceLocal = false,
    this.credential = false,
    this.installScoped = false,
  }) : assert(
         !(deviceLocal || credential) ||
             (!profileScoped && !syncable && backup == PrefBackup.never),
         'device-local / credential keys never leave this device',
       ),
       assert(
         !installScoped || deviceLocal,
         'install-scoped implies device-local',
       );

  /// 进 Profile 快照（切 Profile 时随之换值 / 被剪枝）。
  final bool profileScoped;

  /// 能作为设置跨设备同步（设置同步、合并导入「包含设置」）。名字形状的兜底排除
  /// 另由通道自己叠加（见 app 侧 `PortableSettingsPolicy`）。
  final bool syncable;

  /// 备份归属。
  final PrefBackup backup;

  /// 值是这台设备的事实（地址、路径、身份、本机许可……），绝不离开本设备；ctl 读值打码。
  final bool deviceLocal;

  /// 值里有凭据（密码、令牌、API key、私钥）。与 [deviceLocal] 正交：凭据未必在设备本地
  /// 清单里，但同样不出境、ctl 打码。
  final bool credential;

  /// 设备本地里更严的一类：描述**本次安装**的一次性判定，导入设置的覆盖恢复把它清掉、
  /// 下次启动重判。
  final bool installScoped;

  /// 进不进备份（任一类别）。
  bool get backupIncluded => backup != PrefBackup.never;

  /// 不得离开本设备、ctl 读值必须打码的那一类。
  bool get redacted => deviceLocal || credential;

  /// 普通设置：随 Profile、可同步、进备份设置类。未登记的键也按它处理。
  static const PrefPolicy profile = PrefPolicy(
    profileScoped: true,
    syncable: true,
    backup: PrefBackup.settings,
  );

  /// 不随 Profile、不同步，但随备份设置类恢复：本安装 / 本设备的设置或状态（首启标志、
  /// 界面缩放、更新通道……）与按条目的状态（有声书倍速、合集排序……）。
  static const PrefPolicy unscoped = PrefPolicy(
    profileScoped: false,
    syncable: false,
    backup: PrefBackup.settings,
  );

  /// 随 Profile、不同步、不归备份设置类的内容（内容注册表：收藏句、字体目录……）。
  static const PrefPolicy profileContent = PrefPolicy(
    profileScoped: true,
    syncable: false,
    backup: PrefBackup.content,
  );

  /// 按条目的内容 / 状态，不随 Profile、不同步、不归备份设置类（书名改名）。
  static const PrefPolicy content = PrefPolicy(
    profileScoped: false,
    syncable: false,
    backup: PrefBackup.content,
  );

  /// 进度：不随 Profile、不同步、归备份进度类。
  static const PrefPolicy progress = PrefPolicy(
    profileScoped: false,
    syncable: false,
    backup: PrefBackup.progress,
  );

  /// 不随 Profile、不同步、不进备份，但不是机密（ctl 照常读值）：功能模块开关这类。
  static const PrefPolicy deviceVisible = PrefPolicy(
    profileScoped: false,
    syncable: false,
    backup: PrefBackup.never,
  );

  /// 设备本地。
  static const PrefPolicy local = PrefPolicy(
    profileScoped: false,
    syncable: false,
    backup: PrefBackup.never,
    deviceLocal: true,
  );

  /// 设备本地的凭据。
  static const PrefPolicy localCredential = PrefPolicy(
    profileScoped: false,
    syncable: false,
    backup: PrefBackup.never,
    deviceLocal: true,
    credential: true,
  );

  /// 凭据（不在设备本地清单里）。
  static const PrefPolicy credentialOnly = PrefPolicy(
    profileScoped: false,
    syncable: false,
    backup: PrefBackup.never,
    credential: true,
  );

  /// 安装级（设备本地 + 导入时清掉）。
  static const PrefPolicy installScopedLocal = PrefPolicy(
    profileScoped: false,
    syncable: false,
    backup: PrefBackup.never,
    deviceLocal: true,
    installScoped: true,
  );

  /// 两份策略按「更严」合并：任一侧不随 Profile / 不同步就不，任一侧设备本地 / 凭据 /
  /// 安装级就是；备份取更不出境的一侧（never > progress > content > settings）。
  ///
  /// 一个键同时落在几个声明里（固定键 + 前缀族、嵌套的前缀族）时按这条合并，所以更具体
  /// 的声明**放不宽**更宽的族已经收紧的通道——防漏优先于防误伤。
  PrefPolicy merge(PrefPolicy other) => PrefPolicy(
    profileScoped: profileScoped && other.profileScoped,
    syncable: syncable && other.syncable,
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
      other.backup == backup &&
      other.deviceLocal == deviceLocal &&
      other.credential == credential &&
      other.installScoped == installScoped;

  @override
  int get hashCode => Object.hash(
    profileScoped,
    syncable,
    backup,
    deviceLocal,
    credential,
    installScoped,
  );

  @override
  String toString() =>
      'PrefPolicy(profileScoped: $profileScoped, syncable: $syncable, '
      'backup: ${backup.name}, deviceLocal: $deviceLocal, '
      'credential: $credential, installScoped: $installScoped)';
}

/// 值在 `preferences.value` 里的编码。
abstract interface class PrefValueCodec<T> {
  /// 解码一条存量值。
  T decode(String raw, T defaultValue);

  /// 编码要写入的值。
  String encode(T value);
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
  String encode(String? value) => value ?? '';
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

  /// 编码要写入的值。
  String encode(T value) => codec.encode(value);

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

/// 登记表：全部 [PrefKeyDef]，加一层「名字像凭据」的形状兜底。
///
/// - [lookup] 反查一个字符串键属于哪条登记（固定键优先，键族取最具体的一条）；
/// - [policyOf] 给出这个键在各通道上的**生效策略**：命中的全部登记按 [PrefPolicy.merge]
///   合并，再叠上形状兜底——未登记、或运行时段里带着凭据形状的键照样被拦下
///   （外部导入、扩展、旧版本都会写进未登记的键，生产态绝不因此报错）。
final class PrefKeyRegistry {
  /// 构造期校验：固定键名不重复、键族模式不重复、名字像凭据的固定键必须声明成凭据
  /// （[credentialShapes]）。违反即抛 [StateError]——登记表在启动期构造，测试第一时间就红。
  PrefKeyRegistry(
    Iterable<PrefKeyDef> defs, {
    this.credentialShapes = defaultCredentialShapes,
    this.fallbackPolicy = PrefPolicy.profile,
  }) {
    for (final PrefKeyDef def in defs) {
      switch (def) {
        case PrefKey<Object?>():
          if (def.name.isEmpty) {
            throw StateError('PrefKeyRegistry: empty key name');
          }
          final PrefKey<Object?>? clash = _keys[def.name];
          if (clash != null) {
            throw StateError('PrefKeyRegistry: duplicate key "${def.name}"');
          }
          if (!def.policy.credential && looksLikeCredential(def.name)) {
            throw StateError(
              'PrefKeyRegistry: "${def.name}" looks like a credential but is '
              'not declared credential',
            );
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
    _families.sort(
      (PrefKeyFamily<Object?> a, PrefKeyFamily<Object?> b) =>
          b.specificity.compareTo(a.specificity),
    );
  }

  /// 名字形状兜底：键（小写）含这些子串即视为凭据，**不限前缀**。
  static const List<String> defaultCredentialShapes = <String>[
    'password',
    'token',
    'secret',
    'private_key',
    'credential',
    'api_key',
  ];

  /// 本登记表用的凭据形状。
  final List<String> credentialShapes;

  /// 未登记键的策略。
  final PrefPolicy fallbackPolicy;

  final Map<String, PrefKey<Object?>> _keys = <String, PrefKey<Object?>>{};
  final List<PrefKeyFamily<Object?>> _families = <PrefKeyFamily<Object?>>[];
  final Set<String> _familyPatterns = <String>{};

  /// 全部固定键。
  Iterable<PrefKey<Object?>> get keys => _keys.values;

  /// 全部键族（按具体程度降序）。
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

  /// [key] 的名字是否像凭据（形状兜底）。
  bool looksLikeCredential(String key) {
    final String lower = key.toLowerCase();
    for (final String shape in credentialShapes) {
      if (lower.contains(shape)) return true;
    }
    return false;
  }

  /// [key] 的生效策略：命中的全部登记（固定键 + 每个匹配的键族）按 [PrefPolicy.merge]
  /// 合并，名字像凭据再并上 [PrefPolicy.credentialOnly]；一条都没命中用 [fallbackPolicy]。
  PrefPolicy policyOf(String key) {
    PrefPolicy? merged = _keys[key]?.policy;
    for (final PrefKeyFamily<Object?> family in _families) {
      if (!family.matches(key)) continue;
      merged = merged == null ? family.policy : merged.merge(family.policy);
    }
    final PrefPolicy base = merged ?? fallbackPolicy;
    return looksLikeCredential(key)
        ? base.merge(PrefPolicy.credentialOnly)
        : base;
  }

  /// 声明的策略满足 [test] 的固定键名（派生名单用，按登记顺序）。
  List<String> keyNamesWhere(bool Function(PrefPolicy policy) test) => <String>[
    for (final PrefKey<Object?> key in _keys.values)
      if (test(key.policy)) key.name,
  ];
}
