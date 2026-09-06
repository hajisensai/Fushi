// Unity（Mono 运行时）adapter。补的是一个**实测存在的覆盖缺口**：老 Unity（5.x 一代）
// 把引擎静态链进 exe，没有 `UnityPlayer.dll`，而仓库里 `UnityIl2CppAdapter::probe()` 与
// injector 的 `LooksLikeUnityRuntime()` 都以它为必要条件——于是这一族游戏两边都不认领。
// 真机实测（カスタムメイド3D2 CHU-B LIP）：`[adapters]` 读数里**没有** unity_il2cpp 行，
// 而 PCM 一直在流（voice_clips 981）。
//
// 首版只做两件事，且全部 implemented_unverified：
//   * 身份：unity_mono_profile.h 的「Managed\Assembly-CSharp.dll + Mono\mono.dll，且同级
//     无 GameAssembly.dll」结构判据（最后一条是与 unity_il2cpp 的显式互斥门）；
//   * 文本 + 音频：都不自带 hook。文本走 LunaHook（真机实测 luna_active=1、text_events=7，
//     标题画面），音频走 GenericWindowsAudioAdapter 的源 PCM（voice_clips 981，非静音）。
//
// **刻意不改 injector 的自动 PC hooks**：照 Unreal 那次的同一套对照实测，本样本开与不开
// `--luna-pchooks` 的 text_events **都是 7**（同一段标题画面）。Unreal 那次是 11→29 才据此
// 改的；这里没有收益，就不改——不拿"顺手加上"当理由扩大 hook 面。
//
// 逐句语音资源层（Unity AudioClip / .assets）明确**未做**：本样本 `unity_events=0`，既有的
// Unity 资源提取器对它没有产出；要取原始逐句字节得在真机上定位它自己的读取路径，静态阶段
// 不猜 hook 面。
#include "unity_mono_profile.h"

class UnityMonoAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "unity_mono"; }
  bool probe() const override {
    return fushi_voice_hook::MatchesUnityMonoProfile(nullptr);
  }
  // 没有引擎专属 hook 可装：installed_ 只表示「身份成立、共享文本/PCM 路径对此进程生效」。
  bool install() override {
    installed_ = probe();
    return installed_;
  }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kText |
           fushi_voice_hook::AdapterCapability::kPcmAudio;
  }
  void onModuleLoaded(const wchar_t* module_name) override {
    // 身份来自磁盘布局，启动时一次判定即可；模块通知只作重试接缝。
    if (!installed_ && module_name == nullptr) install();
  }
  void shutdown() override { installed_ = false; }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u : g_header->hook_diagnostics};
  }

 private:
  bool installed_ = false;
};
