/// Sign-in to a tracking plugin's site: the plugin declares `form` steps,
/// the host renders them (message, fields, buttons, an "Open site" link).
/// Entered text goes to the plugin only; it is never logged or shown again.
library;

import 'dart:async';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/tracking/plugin/plugin_tracking_provider.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_labels.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_manager.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_models.dart';
import 'package:fushi/src/media/tracking/tracking_token_paste_button.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens an external link for the "Open site" button.
typedef TrackingPluginUrlOpener = Future<void> Function(Uri url);

Future<void> _openExternally(Uri url) async {
  await launchUrl(url, mode: LaunchMode.externalApplication);
}

/// Runs the sign-in of [provider]. Returns this device's account when the
/// plugin reported `done`, null when the user closed the dialog.
Future<TrackingPluginAccount?> showTrackingPluginLoginDialog(
  BuildContext context, {
  required PluginTrackingProvider provider,
  required TrackingPluginManager manager,
  TrackingPluginUrlOpener? openUrl,
}) => showAppDialog<TrackingPluginAccount>(
  context: context,
  builder: (BuildContext context) => TrackingPluginLoginDialog(
    provider: provider,
    manager: manager,
    openUrl: openUrl ?? _openExternally,
  ),
);

class TrackingPluginLoginDialog extends StatefulWidget {
  const TrackingPluginLoginDialog({
    required this.provider,
    required this.manager,
    this.openUrl = _openExternally,
    super.key,
  });

  final PluginTrackingProvider provider;
  final TrackingPluginManager manager;
  final TrackingPluginUrlOpener openUrl;

  @override
  State<TrackingPluginLoginDialog> createState() =>
      _TrackingPluginLoginDialogState();
}

class _TrackingPluginLoginDialogState extends State<TrackingPluginLoginDialog> {
  List<TrackingPluginLoginMethod>? _methods;
  TrackingPluginLoginMethod? _method;
  TrackingPluginLoginChallenge? _challenge;

  /// A call failed (translated on display).
  Object? _error;
  bool _busy = false;

  /// Field id -> controller of the current challenge. Replaced with every new
  /// challenge; the old ones are cleared at once (no typed secret is kept)
  /// and moved to [_retired].
  Map<String, TextEditingController> _fields =
      <String, TextEditingController>{};

  /// Controllers of earlier steps. The outgoing step stays on screen during
  /// the switch animation and still uses them, so they are disposed with the
  /// dialog.
  final List<TextEditingController> _retired = <TextEditingController>[];

  /// Bumped on every new method start and on dispose: a late answer of an
  /// older call is dropped.
  int _generation = 0;

  PluginTrackingProvider get _provider => widget.provider;

  @override
  void initState() {
    super.initState();
    unawaited(_loadMethods());
  }

  @override
  void dispose() {
    _generation++;
    _dropFields();
    for (final TextEditingController controller in _retired) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Clears the current fields and retires their controllers.
  void _dropFields() {
    for (final TextEditingController controller in _fields.values) {
      controller.clear();
      _retired.add(controller);
    }
    _fields = <String, TextEditingController>{};
  }

  Future<void> _loadMethods() async {
    final int gen = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final List<TrackingPluginLoginMethod> methods = await _provider
          .loginMethods();
      if (gen != _generation || !mounted) return;
      setState(() => _methods = methods);
      if (methods.length == 1) await _begin(methods.single);
    } on Object catch (error) {
      if (gen == _generation && mounted) setState(() => _error = error);
    } finally {
      if (gen == _generation && mounted) setState(() => _busy = false);
    }
  }

  /// Back to the method list (only offered with several methods).
  void _chooseAgain() {
    _generation++;
    _dropFields();
    setState(() {
      _method = null;
      _challenge = null;
      _error = null;
      _busy = false;
    });
  }

  Future<void> _begin(TrackingPluginLoginMethod method) async {
    final int gen = ++_generation;
    _dropFields();
    setState(() {
      _method = method;
      _challenge = null;
      _error = null;
      _busy = true;
    });
    try {
      final TrackingPluginLoginChallenge challenge = await _provider.beginLogin(
        method.id,
      );
      if (gen != _generation || !mounted) return;
      _apply(challenge);
    } on Object catch (error) {
      if (gen == _generation && mounted) setState(() => _error = error);
    } finally {
      if (gen == _generation && mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit(String action) async {
    final TrackingPluginLoginMethod method = _method!;
    final TrackingPluginLoginChallenge? current = _challenge;
    final int gen = _generation;
    final Map<String, String> inputs = <String, String>{
      for (final TrackingPluginLoginField field
          in current?.fields ?? const <TrackingPluginLoginField>[])
        field.id: _fields[field.id]?.text ?? '',
    };
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final TrackingPluginLoginChallenge next = await _provider.submitLogin(
        method.id,
        session: current?.session,
        action: action,
        inputs: inputs,
      );
      if (gen != _generation || !mounted) return;
      _apply(next);
    } on Object catch (error) {
      if (gen == _generation && mounted) setState(() => _error = error);
    } finally {
      if (gen == _generation && mounted) setState(() => _busy = false);
    }
  }

  void _apply(TrackingPluginLoginChallenge challenge) {
    if (challenge.state == TrackingPluginLoginState.done) {
      // The provider read and stored the account before returning `done`.
      final TrackingPluginAccount stored = widget.manager.accountOf(
        _provider.pluginId,
      );
      Navigator.of(context).pop(
        stored.loggedIn
            ? stored
            : challenge.account ?? const TrackingPluginAccount(loggedIn: true),
      );
      return;
    }
    _dropFields();
    _fields = <String, TextEditingController>{
      for (final TrackingPluginLoginField field in challenge.fields)
        field.id: TextEditingController(text: field.value),
    };
    setState(() => _challenge = challenge);
  }

  @override
  Widget build(BuildContext context) {
    final List<TrackingPluginLoginMethod>? methods = _methods;
    return FushiAlertDialog(
      icon: const FushiIcon(FushiIcons.login),
      title: Text(
        t.media_tracking_plugins_login_title(name: _provider.displayName),
      ),
      content: SizedBox(
        width: 480,
        child: AnimatedSwitcher(
          duration: fushiMotionDuration(context, FushiMotion.medium),
          child: KeyedSubtree(
            key: ValueKey<Object?>(
              '${_method?.id}|${identityHashCode(_challenge)}|'
              '${methods?.length}|${_error != null}',
            ),
            child: FushiEntranceScope(child: _body(context, methods)),
          ),
        ),
      ),
      actions: <Widget>[
        if (_method != null && (methods?.length ?? 0) > 1)
          FushiTextButton(
            key: const ValueKey<String>('tracking-plugin-login-methods'),
            onPressed: _busy ? null : _chooseAgain,
            child: Text(t.media_tracking_plugins_login_method_change),
          ),
        FushiTextButton(
          key: const ValueKey<String>('tracking-plugin-login-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.media_tracking_close),
        ),
      ],
    );
  }

  Widget _body(BuildContext context, List<TrackingPluginLoginMethod>? methods) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiTypography type = context.fushiType;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TrackingPluginLoginMethod? method = _method;
    final TrackingPluginLoginChallenge? challenge = _challenge;
    final List<Widget> children = <Widget>[];

    if (methods != null && methods.isEmpty) {
      children.add(
        Text(
          t.media_tracking_plugins_login_methods_empty,
          style: type.bodyMedium,
        ),
      );
    } else if (methods != null && method == null && methods.length > 1) {
      for (final TrackingPluginLoginMethod m in methods) {
        children.add(_MethodChoice(method: m, onPressed: () => _begin(m)));
      }
    }
    if (method?.description != null) {
      children.add(Text(method!.description!, style: type.bodyMedium));
    }
    if (challenge != null &&
        challenge.state == TrackingPluginLoginState.failed) {
      children.add(
        Text(
          challenge.message ?? t.media_tracking_plugins_login_failed_label,
          key: const ValueKey<String>('tracking-plugin-login-failed'),
          style: type.bodyMedium.copyWith(color: cs.error),
        ),
      );
    } else if (challenge != null) {
      children.addAll(_form(context, challenge));
    }
    if (_error != null) {
      children.add(
        Text(
          trackingPluginErrorText(_error!),
          key: const ValueKey<String>('tracking-plugin-login-error'),
          style: type.bodyMedium.copyWith(color: cs.error),
        ),
      );
    }
    final bool canRetry =
        challenge?.state == TrackingPluginLoginState.failed || _error != null;
    if (canRetry && !_busy) {
      children.add(
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FushiPressScale(
            child: FushiOutlinedButton.icon(
              key: const ValueKey<String>('tracking-plugin-login-retry'),
              onPressed: () =>
                  unawaited(method == null ? _loadMethods() : _begin(method)),
              icon: const FushiIcon(FushiIcons.refresh),
              label: Text(t.media_tracking_plugins_login_retry_action),
            ),
          ),
        ),
      );
    }
    if (_busy) children.add(const FushiLinearProgressIndicator());
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: tokens.spacing.gap,
      children: <Widget>[
        for (int i = 0; i < children.length; i++)
          FushiStaggeredEntrance(index: i, child: children[i]),
      ],
    );
  }

  List<Widget> _form(
    BuildContext context,
    TrackingPluginLoginChallenge challenge,
  ) {
    return <Widget>[
      if (challenge.message != null)
        Text(
          challenge.message!,
          key: const ValueKey<String>('tracking-plugin-login-message'),
          style: context.fushiType.bodyMedium,
        ),
      for (final TrackingPluginLoginField field in challenge.fields)
        _fieldWithPaste(field, _fields[field.id]),
      ..._formActions(context, challenge),
    ];
  }

  /// A sign-in field with a trailing paste button (tokens are copied from
  /// the site). Kept outside the field so the secret's eye button stays.
  Widget _fieldWithPaste(
    TrackingPluginLoginField field,
    TextEditingController? controller,
  ) {
    final Widget input = FushiTextField(
      key: ValueKey<String>('tracking-plugin-login-field-${field.id}'),
      controller: controller,
      labelText: field.label,
      hintText: field.placeholder,
      // A secret stays one obscured line (Flutter cannot obscure several
      // lines); the built-in eye button shows / hides it.
      obscureText: field.secret,
      minLines: field.multiline && !field.secret ? 3 : 1,
      maxLines: field.multiline && !field.secret ? 6 : 1,
      keyboardType: field.multiline && !field.secret
          ? TextInputType.multiline
          : TextInputType.text,
      enabled: !_busy,
      // The paste button below replaces the field; the generic assist
      // (insert at cursor / on-screen keyboard) would be a second one.
      showInputAssist: false,
      // A dialog is drawn on the filled field's own colour: outline it so
      // the field is visible (T1 F19).
      variant: FushiTextFieldVariant.outlined,
    );
    if (controller == null) return input;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(child: input),
        TrackingTokenPasteButton(
          key: ValueKey<String>('tracking-plugin-login-paste-${field.id}'),
          controller: controller,
          enabled: !_busy,
        ),
      ],
    );
  }

  List<Widget> _formActions(
    BuildContext context,
    TrackingPluginLoginChallenge challenge,
  ) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return <Widget>[
      Wrap(
        spacing: tokens.spacing.gap,
        runSpacing: tokens.spacing.gap,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          if (challenge.appUrl != null)
            FushiPressScale(
              child: FushiTextButton.icon(
                key: const ValueKey<String>('tracking-plugin-login-open-site'),
                onPressed: _busy
                    ? null
                    : () => unawaited(
                        widget.openUrl(Uri.parse(challenge.appUrl!)),
                      ),
                icon: const FushiIcon(FushiIcons.openInNew),
                label: Text(t.media_tracking_plugins_login_open_site),
              ),
            ),
          for (final TrackingPluginLoginAction action in challenge.actions)
            FushiPressScale(
              child: action.primary
                  ? FushiFilledButton(
                      key: ValueKey<String>(
                        'tracking-plugin-login-action-${action.id}',
                      ),
                      onPressed: _busy
                          ? null
                          : () => unawaited(_submit(action.id)),
                      child: Text(action.label),
                    )
                  : FushiOutlinedButton(
                      key: ValueKey<String>(
                        'tracking-plugin-login-action-${action.id}',
                      ),
                      onPressed: _busy
                          ? null
                          : () => unawaited(_submit(action.id)),
                      child: Text(action.label),
                    ),
            ),
        ],
      ),
    ];
  }
}

/// One sign-in method to pick when the plugin offers several.
class _MethodChoice extends StatelessWidget {
  const _MethodChoice({required this.method, required this.onPressed});

  final TrackingPluginLoginMethod method;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: tokens.spacing.gap * 0.5,
      children: <Widget>[
        FushiPressScale(
          child: FushiFilledButton.tonal(
            key: ValueKey<String>('tracking-plugin-login-method-${method.id}'),
            onPressed: onPressed,
            child: Text(method.label),
          ),
        ),
        if (method.description != null)
          Text(method.description!, style: context.fushiType.bodySmall),
      ],
    );
  }
}
