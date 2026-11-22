/// 「通用 › 作品隐私」：作品隐私分级（公开 / 私密 / 上锁）与 NSFW 的全局开关集中在
/// 这一个分区（拍板台 qiqSbvdxrk）。作品自己的分级与 NSFW 标记在作品菜单 › 隐私 里改
/// （`media_privacy_dialog.dart`），这里只放跨作品的开关：
/// - 显示已上锁的作品（本次会话，不持久化；打开要过口令 / 系统验证）；
/// - 解锁口令（设置 / 修改）；
/// - 模糊 NSFW 封面、制卡图片也模糊（原「外观 › NSFW 内容」两项，id 与偏好键不变）。
library;

import 'dart:async';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/privacy/media_lock_auth.dart';
import 'package:fushi/src/media/privacy/media_lock_dialogs.dart';
import 'package:fushi/src/media/privacy/media_visibility.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

SettingsSection buildMediaPrivacySection() => SettingsSection(
  id: 'general.section.media_privacy',
  presentation: SettingsSectionPresentation.alwaysExpanded,
  title: t.settings_media_privacy_section,
  footer: t.settings_media_privacy_footer,
  // 解锁状态是内存里的会话状态，不走偏好：本分组自己订阅，解锁 / 重新隐藏后
  // 开关立即跟上（另一处解锁也一样）。
  liveListenable: (SettingsContext _) => MediaLockSession.instance.unlocked,
  items: <SettingsItem>[
    SettingsSwitchItem(
      id: 'general.media_lock_show',
      title: t.settings_media_lock_show,
      subtitle: t.settings_media_lock_show_hint,
      icon: FushiIcons.lockOpen,
      // AI 助手拨不动：打开它等于替用户解锁。
      userOnly: true,
      value: (SettingsContext _) => MediaLockSession.instance.isUnlocked,
      onChanged: (SettingsContext settingsContext, bool value) async {
        if (!value) {
          MediaLockSession.instance.relock();
        } else {
          await unlockMediaLockSession(settingsContext.context);
        }
        settingsContext.refresh();
      },
      defaultValue: false,
    ),
    SettingsActionItem(
      id: 'general.media_lock_passcode',
      title: t.settings_media_lock_passcode,
      subtitle: t.settings_media_lock_passcode_hint,
      icon: FushiIcons.lock,
      cli: const SettingsCliAction.unsupported(
        'The unlock passcode can only be set in the app (it must be verified '
        'and typed by the user).',
      ),
      onTap: (SettingsContext settingsContext) async {
        final bool hasPasscode = await MediaLockAuth.instance.passcode.isSet();
        if (!settingsContext.context.mounted) return;
        // 改口令先验证机主（旧口令或系统验证），免得借手机的人顺手改掉。
        if (hasPasscode &&
            !await verifyMediaLockOwner(
              settingsContext.context,
              title: t.settings_media_lock_passcode,
            )) {
          return;
        }
        if (!settingsContext.context.mounted) return;
        unawaited(showMediaLockPasscodeSetupDialog(settingsContext.context));
      },
    ),
    SettingsSwitchItem(
      id: 'appearance.nsfw_blur_covers',
      title: t.settings_nsfw_blur_covers,
      subtitle: t.settings_nsfw_blur_covers_hint,
      icon: FushiIcons.visibilityOff,
      value: (SettingsContext settingsContext) =>
          settingsContext.appModel.prefsRepo.blurNsfwCovers,
      onChanged: (SettingsContext settingsContext, bool value) async {
        await settingsContext.appModel.prefsRepo.setBlurNsfwCovers(value);
        settingsContext.refresh();
      },
      defaultValue: true,
    ),
    SettingsSwitchItem(
      id: 'appearance.nsfw_blur_card_images',
      title: t.settings_nsfw_blur_card_images,
      subtitle: t.settings_nsfw_blur_card_images_hint,
      icon: FushiIcons.ankiCard,
      value: (SettingsContext settingsContext) =>
          settingsContext.appModel.prefsRepo.blurNsfwCardImages,
      onChanged: (SettingsContext settingsContext, bool value) async {
        await settingsContext.appModel.prefsRepo.setBlurNsfwCardImages(value);
        settingsContext.refresh();
      },
      defaultValue: false,
    ),
  ],
);
