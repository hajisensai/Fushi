/// 加密归档的口令来源：导入链路检测到加密包时经它取口令（记住的 / 弹窗问用户的）。
///
/// 引擎层只定接口：app 装一个「系统安全存储 + 口令对话框」实现到 [ArchivePasswords.provider]
/// （见 fushi 的 `archive_password_prompt.dart`），无头服务端不装，加密包导入按
/// [ArchiveUnpackFailure.passwordRequired] 失败。所有走归档解包的入口（发现页下载、漫画包、
/// 片源库扫描、控制通道导入）都经 `ArchiveUnpacker` 用同一个实现，不在各入口各写一遍。
library;

/// 一次口令请求。
final class ArchivePasswordRequest {
  const ArchivePasswordRequest({
    required this.archivePath,
    required this.fingerprint,
    this.attempt = 0,
    this.previousWrong = false,
    this.rememberedRejected = false,
  });

  /// 加密包的路径（对话框显示文件名）。
  final String archivePath;

  /// 归档指纹（`ffc_archive_probe` 的头尾 + 长度 SHA-256），记住口令的键。
  final String fingerprint;

  /// 这是同一个包第几次问（从 0 起）。
  final int attempt;

  /// 上一次给的口令不对。
  final bool previousWrong;

  /// 记住的口令已经不对了（已删掉），这次是重新问。
  final bool rememberedRejected;
}

/// 用户给的口令。
final class ArchivePasswordAnswer {
  const ArchivePasswordAnswer(this.password, {this.remember = false});

  final String password;

  /// 解开后记住（存系统安全存储，按归档指纹）。
  final bool remember;
}

/// 口令来源。
abstract interface class ArchivePasswordProvider {
  /// 按指纹取记住的口令；没有返回 null。
  Future<String?> remembered(String fingerprint);

  /// 记住口令（只在真解开之后调）。
  Future<void> remember(String fingerprint, String password);

  /// 忘掉记住的口令（记住的那个已经不对时调）。
  Future<void> forget(String fingerprint);

  /// 问用户要口令；null = 用户取消（或当前不能交互）。
  Future<ArchivePasswordAnswer?> ask(ArchivePasswordRequest request);
}

/// 进程级默认口令来源（app 启动时装；服务端 / 测试不装）。
abstract final class ArchivePasswords {
  static ArchivePasswordProvider? provider;
}

/// 只用记住的口令、从不弹窗的口令来源：后台批量扫描（片源库定时 / 手动重扫）用，避免扫到
/// 加密包时突然弹对话框、每次重扫都再弹。加密包在这种来源下按「要口令」失败，用户手动
/// 导入一次并勾「记住密码」后，之后的扫描就能用记住的口令解开。
final class StoredOnlyArchivePasswords implements ArchivePasswordProvider {
  const StoredOnlyArchivePasswords([this._inner]);

  /// 记住的口令从哪里读；缺省为进程级 [ArchivePasswords.provider]。
  final ArchivePasswordProvider? _inner;

  ArchivePasswordProvider? get _source => _inner ?? ArchivePasswords.provider;

  @override
  Future<String?> remembered(String fingerprint) async =>
      _source?.remembered(fingerprint);

  @override
  Future<void> remember(String fingerprint, String password) async {}

  @override
  Future<void> forget(String fingerprint) async => _source?.forget(fingerprint);

  @override
  Future<ArchivePasswordAnswer?> ask(ArchivePasswordRequest request) async =>
      null;
}

/// 加密包解不开的原因（`ArchiveUnpacker` 抛的 [ArchiveUnpackException] 里带）。
enum ArchiveUnpackFailure {
  /// 加密了、没有口令来源（无头服务端 / 不能交互）。
  passwordRequired,

  /// 用户在口令对话框里取消了。
  passwordCancelled,

  /// 条目路径不安全（zip-slip、符号链接等），整包拒绝。
  unsafeEntry,

  /// 解出的大小 / 文件数超过上限。
  tooLarge,

  /// 格式不支持（不认识的包等）。
  unsupported,

  /// 包坏了 / 解压失败。
  corrupt,

  /// RAR 需要 7-Zip 命令行而本机没有。
  toolMissing,

  /// 分卷包（`book.7z.001`…）拼不全：选的不是第一卷（`.001`），或其余各卷不在同一个
  /// 文件夹里。
  missingVolume,
}

/// 归档解包失败。
final class ArchiveUnpackException implements Exception {
  const ArchiveUnpackException(this.failure, this.archivePath, [this.detail]);

  final ArchiveUnpackFailure failure;
  final String archivePath;
  final String? detail;

  bool get isPasswordFailure =>
      failure == ArchiveUnpackFailure.passwordRequired ||
      failure == ArchiveUnpackFailure.passwordCancelled;

  @override
  String toString() =>
      'ArchiveUnpackException: ${failure.name} $archivePath'
      '${detail == null ? '' : ' ($detail)'}';
}
