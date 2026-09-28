import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_isbn_backfill.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:fushi_engine/leaderboard/leaderboard_identity.dart';
import 'package:fushi_engine/leaderboard/leaderboard_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_sync.dart';
import 'package:fushi_engine/leaderboard/local_shelf.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import 'package:fushi/src/leaderboard/leaderboard_store.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/utils/misc/card_screenshot_downsampler.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 排行榜服务的默认地址（store 的 `serverUrl` 可覆盖）。
const String kLeaderboardDefaultBaseUrl = 'https://rank.fushi.moe';

/// 后台同步的最小间隔。
const Duration kLeaderboardBackgroundSyncInterval = Duration(minutes: 30);

/// 头像边长（正方形 JPEG）。
const int kLeaderboardAvatarSize = 128;

enum LeaderboardStatus {
  /// 本 Profile 没有排行榜账户（默认；此时零网络请求）。
  disabled,

  /// 本机有账户（钥匙在本机文件里）。
  active,
}

/// 一个 Profile 的排行榜账户与书架同步（设计 docs/specs/2026-09-28-leaderboard-accounts.md）。
///
/// 所有依赖都经构造注入（数据库 / 数据目录 / Profile / 出站 HTTP / 时钟 / 图片处理），
/// 生产装配见 [leaderboardServiceProvider]。未开启（[LeaderboardStatus.disabled]）时
/// 除了用户显式发起的「请求验证码 / 注册 / 登录 / 导入恢复码」之外不发任何网络请求。
class LeaderboardService extends ChangeNotifier {
  LeaderboardService({
    required FushiDatabase Function() database,
    required Future<Directory> Function() supportRoot,
    required Future<int> Function() profileId,
    required Future<http.Client> Function() httpClientFactory,
    Uri? defaultBaseUrl,
    int Function()? clockMs,
    Future<Uint8List?> Function(LocalShelfEntry entry)? coverThumb,
    Future<Uint8List> Function(String path)? avatarEncoder,
    Future<LocalShelf> Function(FushiDatabase db, int profileId)? shelfBuilder,
    Future<int> Function(FushiDatabase db)? isbnBackfill,
  }) : _database = database,
       _supportRoot = supportRoot,
       _profileId = profileId,
       _httpClientFactory = httpClientFactory,
       _defaultBaseUrl =
           defaultBaseUrl ?? Uri.parse(kLeaderboardDefaultBaseUrl),
       _clockMs = clockMs ?? _systemClockMs,
       _coverThumb = coverThumb ?? leaderboardCoverThumb,
       _avatarEncoder = avatarEncoder ?? encodeLeaderboardAvatar,
       _shelfBuilder = shelfBuilder ?? _defaultShelfBuilder,
       _isbnBackfill = isbnBackfill ?? backfillEpubIsbns;

  final FushiDatabase Function() _database;
  final Future<Directory> Function() _supportRoot;
  final Future<int> Function() _profileId;
  final Future<http.Client> Function() _httpClientFactory;
  final Uri _defaultBaseUrl;
  final int Function() _clockMs;
  final Future<Uint8List?> Function(LocalShelfEntry entry) _coverThumb;
  final Future<Uint8List> Function(String path) _avatarEncoder;
  final Future<LocalShelf> Function(FushiDatabase db, int profileId)
  _shelfBuilder;
  final Future<int> Function(FushiDatabase db) _isbnBackfill;

  static int _systemClockMs() => DateTime.now().millisecondsSinceEpoch;

  static Future<LocalShelf> _defaultShelfBuilder(
    FushiDatabase db,
    int profileId,
  ) => buildLocalShelf(db, profileId: profileId);

  Future<void>? _loading;
  Future<void>? _syncing;
  int? _resolvedProfileId;
  bool _uploadAccepted = false;
  LeaderboardStore? _store;
  LeaderboardLocalAccount? _account;
  LeaderboardClient? _client;
  LeaderboardSelf? _self;
  bool _disposed = false;

  LeaderboardStatus get status =>
      _account == null ? LeaderboardStatus.disabled : LeaderboardStatus.active;

  /// 最近一次从服务端拿到的自己（开启后未联网过时为 null，调 [refreshSelf]）。
  LeaderboardSelf? get self => _self;

  /// 已开启时的签名客户端（UI 读榜 / 好友等直接用）；未开启为 null。
  LeaderboardClient? get client => _client;

  /// 本机账户（上传开关 / 上次同步时刻等）；未开启为 null。
  LeaderboardLocalAccount? get account => _account;

  /// 读取本 Profile 的账户文件（幂等；其余方法会先等它）。失败（如数据目录还没就绪）
  /// 不缓存，下次调用重试。
  Future<void> load() =>
      _loading ??= _load().catchError((Object e, StackTrace st) {
        _loading = null;
        Error.throwWithStackTrace(e, st);
      });

  Future<void> _load() async {
    final int profileId = await _profileId();
    final LeaderboardStore store = LeaderboardStore(
      supportRoot: await _supportRoot(),
      profileId: profileId,
    );
    _resolvedProfileId = profileId;
    _store = store;
    final LeaderboardLocalAccount? account = await store.read();
    if (account == null) return;
    try {
      _activate(
        account,
        LeaderboardIdentity.fromRecoveryCode(account.recoveryCode),
      );
    } on FormatException catch (_, st) {
      ErrorLogService.instance.log(
        'LeaderboardService.load',
        'stored recovery code is invalid; treated as not enabled',
        st,
      );
    }
    _notify();
  }

  // ---- 开启 / 登录 ----

  /// 请求邮箱验证码。[forLogin] = 换设备登录（否则注册）；[lang] = `zh` | `en` | `ja`。
  /// 邮箱形状不对抛 [ArgumentError]（UI 可先用 [isPlausibleLeaderboardEmail] 提示）。
  Future<void> requestEmailCode(
    String email, {
    required bool forLogin,
    String? lang,
  }) async {
    await load();
    await _anonymousClient().requestEmailCode(
      email: email,
      purpose: forLogin ? 'login' : 'register',
      lang: lang,
    );
  }

  /// 首次开启：生成本机钥匙 → 邮箱验证码注册 → 存盘（同意时刻 = 现在）。
  Future<void> enable({
    required String nickname,
    required String email,
    required String code,
  }) async {
    await load();
    final LeaderboardIdentity identity = LeaderboardIdentity.generate();
    final LeaderboardSelf self = await _clientFor(
      identity,
    ).register(nickname: nickname, email: email, code: code);
    await _adopt(identity, self);
  }

  /// 换设备：生成本机新钥匙 → 邮箱验证码登录（服务端把这把钥匙绑到已有账户）→ 存盘。
  /// 同步状态清空，下次同步 reset 全量对账。
  Future<void> loginWithEmail({
    required String email,
    required String code,
  }) async {
    await load();
    final LeaderboardIdentity identity = LeaderboardIdentity.generate();
    final LeaderboardSelf self = await _clientFor(
      identity,
    ).login(email: email, code: code);
    await _adopt(identity, self);
  }

  /// 备用的换设备方式：导入恢复码。先经 `me()` 确认账户在服务端存在再存盘；同步状态
  /// 清空以触发对账。恢复码格式错抛 [FormatException]。
  Future<void> importRecoveryCode(String code) async {
    await load();
    final LeaderboardIdentity identity = LeaderboardIdentity.fromRecoveryCode(
      code,
    );
    final LeaderboardSelf self = await _clientFor(identity).me();
    await _adopt(identity, self);
  }

  /// 导出本机恢复码（含私钥）。未开启抛 [StateError]。
  String exportRecoveryCode() => _requireAccount().recoveryCode;

  Future<void> _adopt(
    LeaderboardIdentity identity,
    LeaderboardSelf self,
  ) async {
    final LeaderboardLocalAccount account = LeaderboardLocalAccount(
      recoveryCode: identity.toRecoveryCode(),
      accountId: self.account.id,
      consentAt: _clockMs(),
      serverUrl: _account?.serverUrl,
    );
    await _requireStore().write(account);
    _activate(account, identity);
    _self = self;
    _uploadAccepted = false;
    _notify();
  }

  // ---- 资料 ----

  Future<LeaderboardSelf> refreshSelf() async {
    await load();
    final LeaderboardSelf self = await _requireClient().me();
    _self = self;
    _notify();
    return self;
  }

  /// [visibility] = `public` | `friends`；null 字段不改。
  Future<void> updateProfile({String? nickname, String? visibility}) async {
    await load();
    _self = await _requireClient().updateProfile(
      nickname: nickname,
      visibility: visibility,
    );
    _notify();
  }

  /// 把本地图片裁成 128px 正方形 JPEG（后台 isolate）后上传为头像。
  Future<void> setAvatarFromFile(String path) async {
    await load();
    final LeaderboardClient client = _requireClient();
    await client.setAvatar(await _avatarEncoder(path));
    _self = await client.me();
    _notify();
  }

  Future<void> setUploadEnabled(bool enabled) async {
    await load();
    await _save(_requireAccount().copyWith(uploadEnabled: enabled));
  }

  // ---- 同步 ----

  /// 立即同步本机书架（上传关闭时什么都不做）。同一时刻只跑一次，并发调用共享结果。
  /// 失败时已推进的同步状态照样落盘，再把错误抛给调用方。上传设备是另一台时记下
  /// [LeaderboardLocalAccount.uploadBlockedByOtherDevice] 并抛
  /// [LeaderboardUploadOwnedElsewhere]（UI 据此提示「由本设备接管」）。
  Future<void> syncNow() async {
    await load();
    final Future<void>? inFlight = _syncing;
    if (inFlight != null) return inFlight;
    return _runExclusive(() => _sync(claim: false));
  }

  /// 由本设备接管本账户的书架上传：清空本机同步状态 → reset + claim 全量同步。
  /// 接管即表示要从本机上传，上传开关一并打开。
  Future<void> claimUploadDevice() async {
    await load();
    await _save(
      _requireAccount().copyWith(
        uploadEnabled: true,
        syncState: LeaderboardSyncState.empty,
      ),
    );
    return _runExclusive(() => _sync(claim: true));
  }

  /// 本机是否为本账户的上传设备：同步被拒记过为 false；本进程里上传成功过为 true；
  /// 否则取最近一次 `me()` 的 `uploadDevice`；未知（没联网过 / 旧服务端）为 null。
  bool? get isUploadDevice {
    if (_account == null) return null;
    if (_account!.uploadBlockedByOtherDevice) return false;
    if (_uploadAccepted) return true;
    return _self?.uploadDevice;
  }

  Future<void> _runExclusive(Future<void> Function() job) async {
    // 已有同步在跑：等它结束再跑自己的（claim 不能搭普通同步的便车）。
    while (_syncing != null) {
      try {
        await _syncing;
      } on Object {
        // 前一次同步的失败已由它自己的调用方处理；这里只是排队。
      }
    }
    final Future<void> run = job();
    _syncing = run;
    try {
      await run;
    } finally {
      if (identical(_syncing, run)) _syncing = null;
    }
  }

  Future<void> _sync({required bool claim}) async {
    final LeaderboardLocalAccount account = _requireAccount();
    if (!account.uploadEnabled) return;
    final LeaderboardClient client = _requireClient();
    final LocalShelf shelf = await _shelfBuilder(
      _database(),
      _resolvedProfileId ?? await _profileId(),
    );
    try {
      final LeaderboardSyncState next = await syncShelf(
        client,
        shelf,
        account.syncState,
        claim: claim,
        coverThumb: _coverThumb,
      );
      await _save(
        _requireAccount().copyWith(
          syncState: next,
          lastSyncAt: _clockMs(),
          uploadBlockedByOtherDevice: false,
        ),
      );
      _uploadAccepted = true;
      _notify();
    } on LeaderboardUploadOwnedElsewhere {
      _uploadAccepted = false;
      await _save(_requireAccount().copyWith(uploadBlockedByOtherDevice: true));
      rethrow;
    } on LeaderboardSyncException catch (e) {
      await _save(_requireAccount().copyWith(syncState: e.partialState));
      Error.throwWithStackTrace(e.error, e.stackTrace);
    }
  }

  /// 启动 / 空闲时的后台同步：已开启、上传开着、本机没被另一台上传设备挡住、距上次成功
  /// 同步 ≥ 30 分钟才跑；首次先回填存量 EPUB 的 ISBN（只读 OPF）。上传设备是另一台时
  /// 静默停止（状态记在账户文件里供 UI 显示），不抛。未开启时零网络。
  Future<void> maybeSyncInBackground() async {
    await load();
    final LeaderboardLocalAccount? account = _account;
    if (account == null ||
        !account.uploadEnabled ||
        account.uploadBlockedByOtherDevice) {
      return;
    }
    final int? last = account.lastSyncAt;
    if (last != null &&
        _clockMs() - last < kLeaderboardBackgroundSyncInterval.inMilliseconds) {
      return;
    }
    if (account.isbnBackfilledAt == null) {
      await _isbnBackfill(_database());
      await _save(_requireAccount().copyWith(isbnBackfilledAt: _clockMs()));
    }
    try {
      await syncNow();
    } on LeaderboardUploadOwnedElsewhere {
      // 已记进账户状态；后台路径不打扰用户。
    }
  }

  // ---- 退出 / 删除 ----

  /// 删除服务端账户（全部数据）；成功后删本机文件。
  Future<void> deleteAccount() async {
    await load();
    await _requireClient().deleteAccount();
    await signOutLocally();
  }

  /// 只删本机账户文件（服务端账户保留，可用邮箱或恢复码重新登录）。
  Future<void> signOutLocally() async {
    await load();
    await _requireStore().delete();
    _account = null;
    _client = null;
    _self = null;
    _notify();
  }

  // ---- 内部 ----

  void _activate(LeaderboardLocalAccount account, LeaderboardIdentity id) {
    _account = account;
    _client = _clientFor(id);
  }

  Uri get _baseUrl {
    final String? override = _account?.serverUrl;
    return override == null ? _defaultBaseUrl : Uri.parse(override);
  }

  LeaderboardClient _clientFor(LeaderboardIdentity identity) =>
      LeaderboardClient(
        baseUrl: _baseUrl,
        httpClientFactory: _httpClientFactory,
        identity: identity,
        clockMs: _clockMs,
      );

  LeaderboardClient _anonymousClient() => LeaderboardClient(
    baseUrl: _baseUrl,
    httpClientFactory: _httpClientFactory,
    clockMs: _clockMs,
  );

  Future<void> _save(LeaderboardLocalAccount account) async {
    // 退出 / 删除账户与同步并发时：同步收尾不得把已删的账户文件写回来。
    if (_account == null) return;
    await _requireStore().write(account);
    if (_account == null) {
      await _requireStore().delete();
      return;
    }
    _account = account;
    _notify();
  }

  LeaderboardStore _requireStore() {
    final LeaderboardStore? s = _store;
    if (s == null) throw StateError('leaderboard store not loaded');
    return s;
  }

  LeaderboardLocalAccount _requireAccount() {
    final LeaderboardLocalAccount? a = _account;
    if (a == null) throw StateError('leaderboard is not enabled');
    return a;
  }

  LeaderboardClient _requireClient() {
    final LeaderboardClient? c = _client;
    if (c == null) throw StateError('leaderboard is not enabled');
    return c;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// 本地封面 → ≤300px JPEG 缩略图（后台 isolate）。没有本地封面 / 文件不在 / 解不开
/// 返回 null（跳过补传）。
Future<Uint8List?> leaderboardCoverThumb(LocalShelfEntry entry) async {
  final String? path = entry.localCoverPath;
  if (path == null) return null;
  final File file = File(path);
  if (!await file.exists()) return null;
  final Uint8List thumb = await downsampleCardScreenshotAsync(
    await file.readAsBytes(),
    maxLongEdge: 300,
    quality: 80,
    encoding: CardScreenshotEncoding.jpeg,
  );
  // 解不开时降采样原样返回入参：那不是我们能保证格式的 JPEG，不传。
  return cardScreenshotEncodingOf(thumb) == CardScreenshotEncoding.jpeg
      ? thumb
      : null;
}

/// 读图 → 居中裁成 [kLeaderboardAvatarSize] 正方形 → JPEG（质量 85），解码 / 编码在
/// 后台 isolate。不是可解码图片抛 [FormatException]。
Future<Uint8List> encodeLeaderboardAvatar(String path) async {
  final Uint8List bytes = await File(path).readAsBytes();
  return Isolate.run<Uint8List>(() => encodeLeaderboardAvatarBytes(bytes));
}

/// [encodeLeaderboardAvatar] 的同步内核（纯函数，可单测）。
Uint8List encodeLeaderboardAvatarBytes(Uint8List bytes) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } on Object {
    // 嗅探解码器时对损坏 / 过短字节会抛 RangeError 等（不是返回 null），统一归为
    // 「不是可解码图片」。
    decoded = null;
  }
  if (decoded == null) throw const FormatException('not a decodable image');
  final img.Image square = img.copyResizeCropSquare(
    decoded,
    size: kLeaderboardAvatarSize,
  );
  return img.encodeJpg(square, quality: 85);
}

/// 当前 Profile 的排行榜服务。Profile 切换时重建（旧实例随之 dispose），换到新
/// Profile 的账户文件。
final ChangeNotifierProvider<LeaderboardService> leaderboardServiceProvider =
    ChangeNotifierProvider<LeaderboardService>((ref) {
      final int activeProfileId = ref.watch(
        profileViewModelProvider.select(
          (ProfileUiState s) => s.activeProfileId,
        ),
      );
      final AppModel app = ref.read(appProvider);
      final LeaderboardService service = LeaderboardService(
        database: () => app.database,
        supportRoot: () async => app.databaseDirectory,
        profileId: () async => activeProfileId > 0
            ? activeProfileId
            : await app.database.resolveActiveProfileId(),
        // 出站必须经全应用代理装配。
        httpClientFactory: () async => createAppHttpIoClient(),
      );
      unawaited(
        service.load().catchError((Object e, StackTrace st) {
          ErrorLogService.instance.log('LeaderboardService.load', e, st);
        }),
      );
      return service;
    });
