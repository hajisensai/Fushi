/// 加密归档（zip / 7z / rar）导入时的口令来源：系统安全存储里按归档指纹记住的口令 +
/// 口令对话框。启动时装到 [ArchivePasswords.provider]，导入链路唯一的解包点
/// `ArchiveUnpacker` 经它取口令——书 / 漫画 / 有声书 / 游戏 / 发现页下载 / 片源库扫描
/// 都走这一处，不在各入口各写一遍。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi_engine/utils/archive/archive_passwords.dart';

/// 记住的口令存放处（测试注入内存实现）。
abstract interface class ArchivePasswordVault {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);

  /// 删掉所有以 [prefix] 开头的键，返回删了几个。安全存储读不了（Linux 没有
  /// keyring 等）时抛出，由调用方告诉用户，不当作「没有可删的」。
  Future<int> deleteWithPrefix(String prefix);
}

/// [FlutterSecureStorage] 实现：iOS / macOS Keychain、Android Keystore、Windows DPAPI、
/// Linux libsecret。选项与音乐插件保险库一致（只留本机、出错不清空）。
final class SecureArchivePasswordVault implements ArchivePasswordVault {
  const SecureArchivePasswordVault();

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
    mOptions: MacOsOptions(
      usesDataProtectionKeychain: false,
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  /// flutter_secure_storage 没有按前缀删的接口：列出本 app 的全部键再逐个删。
  @override
  Future<int> deleteWithPrefix(String prefix) async {
    final Map<String, String> all = await _storage.readAll();
    int deleted = 0;
    for (final String key in all.keys) {
      if (!key.startsWith(prefix)) continue;
      await _storage.delete(key: key);
      deleted++;
    }
    return deleted;
  }
}

/// 设置 › 通用 › 作品隐私「清除已记住的压缩包密码」：删掉导入加密包时勾「记住
/// 密码」存下的全部口令，返回删了几个。安全存储读不了时抛出（见
/// [ArchivePasswordVault.deleteWithPrefix]）。
Future<int> forgetAllArchivePasswords({
  ArchivePasswordVault vault = const SecureArchivePasswordVault(),
}) => vault.deleteWithPrefix(AppArchivePasswordProvider.storageKeyPrefix);

/// 弹口令对话框（测试注入）。
typedef ArchivePasswordAsker =
    Future<ArchivePasswordAnswer?> Function(ArchivePasswordRequest request);

/// app 的口令来源。
final class AppArchivePasswordProvider implements ArchivePasswordProvider {
  AppArchivePasswordProvider({
    required ArchivePasswordAsker ask,
    ArchivePasswordVault vault = const SecureArchivePasswordVault(),
  }) : _ask = ask,
       _vault = vault;

  /// 用 [navigatorKey] 当前的上下文弹 [showArchivePasswordDialog]；没有可用上下文
  /// （app 还没起来 / 已在后台退出）按取消处理。
  factory AppArchivePasswordProvider.forNavigator(
    GlobalKey<NavigatorState> navigatorKey, {
    ArchivePasswordVault vault = const SecureArchivePasswordVault(),
  }) => AppArchivePasswordProvider(
    vault: vault,
    ask: (ArchivePasswordRequest request) async {
      final BuildContext? context = navigatorKey.currentContext;
      if (context == null || !context.mounted) return null;
      return showArchivePasswordDialog(context: context, request: request);
    },
  );

  final ArchivePasswordAsker _ask;
  final ArchivePasswordVault _vault;

  /// 同一时刻只开一个口令对话框：批量导入里几个加密包会并发来问。
  Future<void> _promptChain = Future<void>.value();

  /// 记住的口令在安全存储里的键前缀：清除全部时按它挑键，别的功能的键不受影响。
  static const String storageKeyPrefix = 'archive_password_v1_';

  /// 安全存储里的键（指纹是 64 位十六进制，不含特殊字符）。
  static String storageKey(String fingerprint) =>
      '$storageKeyPrefix$fingerprint';

  @override
  Future<String?> remembered(String fingerprint) async {
    try {
      return await _vault.read(storageKey(fingerprint));
    } catch (e) {
      // 安全存储读不了（Linux 没有 keyring 等）：当没记过，照常问用户。
      debugPrint('[archive-password] read failed: $e');
      return null;
    }
  }

  @override
  Future<void> remember(String fingerprint, String password) async {
    try {
      await _vault.write(storageKey(fingerprint), password);
    } catch (e) {
      // 记不住不影响这次导入：包已经解开了。
      debugPrint('[archive-password] write failed: $e');
    }
  }

  @override
  Future<void> forget(String fingerprint) async {
    try {
      await _vault.delete(storageKey(fingerprint));
    } catch (e) {
      debugPrint('[archive-password] delete failed: $e');
    }
  }

  @override
  Future<ArchivePasswordAnswer?> ask(ArchivePasswordRequest request) {
    final Completer<ArchivePasswordAnswer?> done =
        Completer<ArchivePasswordAnswer?>();
    _promptChain = _promptChain.then((_) async {
      try {
        done.complete(await _ask(request));
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }
}

/// 弹口令对话框：返回 null = 取消。
Future<ArchivePasswordAnswer?> showArchivePasswordDialog({
  required BuildContext context,
  required ArchivePasswordRequest request,
}) => showAppDialog<ArchivePasswordAnswer>(
  context: context,
  builder: (_) => ArchivePasswordDialog(request: request),
);

/// 口令对话框：文件名、上次不对 / 记住的已失效的提示、口令框（可显隐）、「记住口令」。
class ArchivePasswordDialog extends StatefulWidget {
  const ArchivePasswordDialog({super.key, required this.request});

  final ArchivePasswordRequest request;

  @override
  State<ArchivePasswordDialog> createState() => _ArchivePasswordDialogState();
}

class _ArchivePasswordDialogState extends State<ArchivePasswordDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _obscure = true;
  bool _remember = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  bool get _canSubmit => _controller.text.isNotEmpty;

  void _submit() {
    if (!_canSubmit) return;
    Navigator.of(
      context,
    ).pop(ArchivePasswordAnswer(_controller.text, remember: _remember));
  }

  String? get _notice {
    final ArchivePasswordRequest request = widget.request;
    if (request.previousWrong) return t.archive_password_wrong;
    if (request.rememberedRejected) return t.archive_password_saved_rejected;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final String? notice = _notice;
    final Duration motion = fushiMotionDuration(context, FushiMotion.short);
    return FushiAlertDialog(
      icon: const FushiDialogHeroIcon(icon: Icons.lock_outline),
      title: Text(t.archive_password_title),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            t.archive_password_message(
              name: p.basename(widget.request.archivePath),
            ),
          ),
          FushiAnimatedSize(
            duration: motion,
            curve: FushiMotion.standard,
            child: AnimatedSwitcher(
              duration: motion,
              child: notice == null
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      key: ValueKey<String>(notice),
                      padding: const EdgeInsets.only(top: 12),
                      child: FushiInlineNotice(
                        key: const ValueKey<String>('archive-password-notice'),
                        severity: FushiNoticeSeverity.error,
                        message: notice,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 16),
          _ShakeOnMount(
            enabled: widget.request.previousWrong,
            child: FushiTextFieldControl(
              key: const ValueKey<String>('archive-password-field'),
              controller: _controller,
              autofocus: true,
              obscureText: _obscure,
              keyboardType: TextInputType.visiblePassword,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: t.archive_password_label,
                border: const OutlineInputBorder(),
                suffixIcon: FushiIconButton(
                  key: const ValueKey<String>('archive-password-visibility'),
                  icon: _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  tooltip: _obscure
                      ? t.archive_password_show
                      : t.archive_password_hide,
                  padTouchTarget: true,
                  onTap: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          FushiCheckboxListTile(
            key: const ValueKey<String>('archive-password-remember'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _remember,
            title: Text(t.archive_password_remember),
            subtitle: Text(t.archive_password_remember_hint),
            onChanged: (bool? value) =>
                setState(() => _remember = value ?? false),
          ),
        ],
      ),
      actions: <Widget>[
        FushiDialogAction(
          key: const ValueKey<String>('archive-password-cancel'),
          label: t.dialog_cancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        FushiDialogAction(
          key: const ValueKey<String>('archive-password-unlock'),
          label: t.archive_password_unlock,
          kind: FushiDialogActionKind.primary,
          onPressed: _canSubmit ? _submit : null,
        ),
      ],
    );
  }
}

/// 口令错了重开对话框时，口令框左右抖一下（时长走 [fushiMotionDuration]，减弱动态效果时
/// 归零即不抖）。
class _ShakeOnMount extends StatelessWidget {
  const _ShakeOnMount({required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Duration duration = fushiMotionDuration(context, FushiMotion.medium);
    if (!enabled || duration == Duration.zero) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: duration,
      curve: FushiMotion.enter,
      builder: (BuildContext context, double progress, Widget? child) {
        // 三个来回、振幅随进度衰减。
        final double dx =
            (1 - progress) * 8 * math.sin(progress * 3 * 2 * math.pi);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: child,
    );
  }
}
