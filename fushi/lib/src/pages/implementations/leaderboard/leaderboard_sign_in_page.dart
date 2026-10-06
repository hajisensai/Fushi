// 排行榜注册 / 换设备登录：邮箱 → 验证码（60 秒冷却）→（注册另要昵称）→ 提交。两种
// 模式都展示公开清单与同意勾选：注册必须同意；登录可不勾（本机上传默认关闭）。
// 服务端错误码就地翻成人话显示在表单里（不靠 toast：toast 转瞬即逝，验证码错了用户
// 需要一直看得到原因）。走错路径时就地切换模式并带上邮箱：登录发码后提示「邮箱可能
// 尚未注册 → 去注册」，注册遇 `email_taken` 给「改为登录」。

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';

import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_common.dart';
import 'package:fushi/utils.dart';

/// 验证码重发冷却（服务端另有按 IP / 邮箱的限流）。
const int kLeaderboardCodeCooldownSeconds = 60;

enum LeaderboardSignInMode { register, login }

/// 注册 / 登录页。成功后 `pop(true)`。
class LeaderboardSignInPage extends ConsumerStatefulWidget {
  const LeaderboardSignInPage({required this.mode, super.key});

  final LeaderboardSignInMode mode;

  @override
  ConsumerState<LeaderboardSignInPage> createState() =>
      _LeaderboardSignInPageState();
}

class _LeaderboardSignInPageState extends ConsumerState<LeaderboardSignInPage> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _code = TextEditingController();
  final TextEditingController _nickname = TextEditingController();
  Timer? _cooldownTimer;
  int _cooldown = 0;
  bool _codeSent = false;
  bool _consent = false;
  bool _sending = false;
  bool _submitting = false;
  String? _error;

  /// 最近一次失败的服务端错误码（决定是否给「改为登录」）。
  String? _errorCode;
  String? _info;
  late LeaderboardSignInMode _mode = widget.mode;

  bool get _register => _mode == LeaderboardSignInMode.register;

  /// 走错路径时切换模式：邮箱保留，验证码按用途不同作废（登录码不能拿去注册），冷却、
  /// 同意与提示一并重置。
  void _switchMode(LeaderboardSignInMode mode) {
    _cooldownTimer?.cancel();
    setState(() {
      _mode = mode;
      _cooldown = 0;
      _codeSent = false;
      _consent = false;
      _error = null;
      _errorCode = null;
      _info = null;
      _code.clear();
    });
  }

  void _showError(Object e) {
    setState(() {
      _error = leaderboardErrorText(e);
      _errorCode = e is LeaderboardApiException ? e.code : null;
    });
  }

  @override
  void initState() {
    super.initState();
    for (final TextEditingController c in <TextEditingController>[
      _email,
      _code,
      _nickname,
    ]) {
      c.addListener(_onChanged);
    }
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _email.dispose();
    _code.dispose();
    _nickname.dispose();
    super.dispose();
  }

  String _lang(BuildContext context) {
    final String code = Localizations.localeOf(context).languageCode;
    return code == 'zh' || code == 'ja' ? code : 'en';
  }

  void _startCooldown() {
    _cooldownTimer?.cancel();
    _cooldown = kLeaderboardCodeCooldownSeconds;
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _cooldown--);
      if (_cooldown <= 0) timer.cancel();
    });
  }

  Future<void> _sendCode() async {
    final String email = _email.text.trim();
    if (!isPlausibleLeaderboardEmail(email)) {
      setState(() => _error = t.leaderboard_error_bad_email);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
      _errorCode = null;
      _info = null;
    });
    try {
      await ref
          .read(leaderboardServiceProvider)
          .requestEmailCode(email, forLogin: !_register, lang: _lang(context));
      if (!mounted) return;
      setState(() {
        _codeSent = true;
        _info = t.leaderboard_signin_code_sent(email: email);
      });
      _startCooldown();
    } catch (e, st) {
      ErrorLogService.instance.log('Leaderboard.requestEmailCode', e, st);
      if (mounted) _showError(e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  bool get _canSubmit {
    if (_submitting || !_codeSent) return false;
    if (_code.text.trim().length != 6) return false;
    if (!_register) return true;
    final int nick = _nickname.text.trim().runes.length;
    return _consent && nick >= 1 && nick <= 24;
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _submitting = true;
      _error = null;
      _errorCode = null;
    });
    final LeaderboardService service = ref.read(leaderboardServiceProvider);
    try {
      if (_register) {
        await service.enable(
          nickname: _nickname.text.trim(),
          email: _email.text.trim(),
          code: _code.text.trim(),
        );
      } else {
        await service.loginWithEmail(
          email: _email.text.trim(),
          code: _code.text.trim(),
          consent: _consent,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e, st) {
      ErrorLogService.instance.log('Leaderboard.signIn', e, st);
      if (mounted) _showError(e);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String sendLabel = _cooldown > 0
        ? t.leaderboard_signin_resend_in(n: _cooldown)
        : (_codeSent
              ? t.leaderboard_signin_resend
              : t.leaderboard_signin_send_code);
    return FushiPageScaffold(
      title: _register
          ? t.leaderboard_signin_register_title
          : t.leaderboard_signin_login_title,
      body: Builder(
        builder: (BuildContext context) => ListView(
          // 正文铺到悬浮页头底下：顶部让出「状态栏 + 页头」（Builder 的
          // context 在页头脚手架之内才读得到这段 padding）。
          padding: withBottomSafeInset(
            context,
            EdgeInsets.fromLTRB(
              tokens.spacing.card,
              tokens.spacing.card + MediaQuery.paddingOf(context).top,
              tokens.spacing.card,
              tokens.spacing.card,
            ),
          ),
          children: <Widget>[
            Text(
              _register
                  ? t.leaderboard_signin_register_hint
                  : t.leaderboard_signin_login_hint,
              style: tokens.type.listSubtitle,
            ),
            SizedBox(height: tokens.spacing.card),
            FushiTextField(
              key: const ValueKey<String>('leaderboard-signin-email'),
              controller: _email,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              labelText: t.leaderboard_signin_email,
              textInputAction: TextInputAction.done,
              onSubmitted: (String _) => unawaited(_sendCode()),
            ),
            SizedBox(height: tokens.spacing.gap),
            Align(
              alignment: Alignment.centerLeft,
              child: FushiFilledButton.tonalIcon(
                key: const ValueKey<String>('leaderboard-signin-send'),
                onPressed: _sending || _cooldown > 0
                    ? null
                    : () => unawaited(_sendCode()),
                icon: const FushiIcon(FushiIcons.emailUnread),
                label: Text(sendLabel),
              ),
            ),
            if (_info != null) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              Text(_info!, style: tokens.type.metadata),
            ],
            if (!_register && _codeSent) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: tokens.spacing.gap,
                children: <Widget>[
                  Text(
                    t.leaderboard_signin_login_code_hint,
                    style: tokens.type.metadata,
                  ),
                  FushiTextButton(
                    key: const ValueKey<String>(
                      'leaderboard-signin-to-register',
                    ),
                    onPressed: () =>
                        _switchMode(LeaderboardSignInMode.register),
                    child: Text(t.leaderboard_signin_switch_register),
                  ),
                ],
              ),
            ],
            SizedBox(height: tokens.spacing.card),
            FushiTextField(
              key: const ValueKey<String>('leaderboard-signin-code'),
              controller: _code,
              readOnly: !_codeSent,
              keyboardType: TextInputType.number,
              labelText: t.leaderboard_signin_code,
            ),
            if (_register) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              FushiTextField(
                key: const ValueKey<String>('leaderboard-signin-nickname'),
                controller: _nickname,
                labelText: t.leaderboard_signin_nickname,
                hintText: t.leaderboard_signin_nickname_hint,
              ),
            ],
            SizedBox(height: tokens.spacing.card),
            const LeaderboardPublicDataList(),
            LeaderboardConsentTile(
              key: const ValueKey<String>('leaderboard-signin-consent'),
              value: _consent,
              label: _register
                  ? t.leaderboard_signin_consent
                  : t.leaderboard_signin_consent_login,
              onChanged: (bool v) => setState(() => _consent = v),
            ),
            if (_error != null) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              Text(
                _error!,
                key: const ValueKey<String>('leaderboard-signin-error'),
                style: tokens.type.listSubtitle.copyWith(color: colors.error),
              ),
              if (_register && _errorCode == 'email_taken')
                Align(
                  alignment: Alignment.centerLeft,
                  child: FushiTextButton(
                    key: const ValueKey<String>('leaderboard-signin-to-login'),
                    onPressed: () => _switchMode(LeaderboardSignInMode.login),
                    child: Text(t.leaderboard_signin_switch_login),
                  ),
                ),
            ],
            SizedBox(height: tokens.spacing.card),
            FushiFilledButton(
              key: const ValueKey<String>('leaderboard-signin-submit'),
              onPressed: _canSubmit ? () => unawaited(_submit()) : null,
              child: _submitting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: FushiCircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      _register
                          ? t.leaderboard_signin_register_action
                          : t.leaderboard_signin_login_action,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
