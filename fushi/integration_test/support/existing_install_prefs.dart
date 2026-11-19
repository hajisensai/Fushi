import 'package:fushi/src/utils/adaptive/shell_style.dart'
    show ShellLayoutInstallDefault;
import 'package:fushi_core/fushi_core.dart' show PrefCodec;

/// 集成测试夹具写进 `preferences` 表的原始行（`key` → 编码值）：一份「装过新版、
/// 走完新手引导、首页首帧的一次性提示都已处理」的安装。
///
/// 首页首帧会串行弹几个只对「升级上来的存量安装」弹一次的模态框；`first_time_setup
/// = false` 恰好就是存量安装信号，夹具若漏记其中任何一个的已处理标记，那个框的
/// ModalScope 就会占住焦点——Tab 只在框内几个控件之间循环，主导航一步也到不了
/// （appSmoke「Second nav tab must be reachable by focus」红的根因，见
/// `test/integration_helpers/existing_install_prefs_test.dart`）。新增这类首帧
/// 一次性弹框时，在这里补上对应的已处理标记，并在上面那个测试里钉住判定。
Map<String, String> existingInstallSeedPrefs() => <String, String>{
  'first_time_setup': PrefCodec.encode(false),
  'onboarding_completed': PrefCodec.encode(true),
  // 「库页默认改为封面网格」一次性提示（library_layout_default_notice.dart）。
  'library_layout_default_notice_handled': PrefCodec.encode(true),
  // 「选一种库页布局」选择框（shell_layout_choice_dialog.dart）：出厂判定落成
  // 「新安装」——与真实新装用户第二次启动时的状态一致（布局已在新手引导里选，
  // 不弹框）。缺了它，启动时 `first_time_setup` 已在，会被判成「升级上来、待选」。
  ShellLayoutInstallDefault.prefKey: PrefCodec.encode(
    ShellLayoutInstallDefault.fresh.prefValue,
  ),
};
