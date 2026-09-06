// Unreal Engine（IoStore 打包形态）adapter。首版只做三件事，且全部 implemented_unverified：
//   * 身份：unreal_iostore_profile.h 的「Binaries\Win64 目录形状 + Content\Paks\*.utoc
//     IoStore 魔数」结构判据（真实样本 昨日魔女今日的梦 1.0 汉化版，UE5）；
//   * 文本：不自带 hook，交给 LunaHook 的通用 PC hooks——UE 是 C++ 引擎，台词在进程内，
//     没有 Mono/TJS 那样的脚本宿主可挂；真机对照实测：不开 PC hooks 的一局 text_events=11，
//     开了的一局 29（同一份 helper、同一段标题画面），故 injector 对 Unreal 目标自动开启；
//   * 音频：不自带 hook，走 GenericWindowsAudioAdapter 的源 PCM。真机实测
//     xaudio_diagnostics = kXAudioDiagQueueReady|JobQueued|PcmPublished，voice_clips 持续增长。
//     **是哪条后端产出的没区分**：shipping exe 静态导入的是 DSOUND.dll，而 UE 树里同时带
//     Engine\Binaries\ThirdParty\Windows\XAudio2_9\x64\xaudio2_9redist.dll（运行期动态加载）。
//     本会话只证到「通用 Windows 音频路径发布了 PCM」，不声称是 XAudio2。
// 逐句资源层（SoundWave 资产在 *.ucas 里，经 IoStore 分块 + 压缩）明确**未做**：取原始逐句
// 字节要在引擎解包之后的位置下手，位置只能在真机上定，静态阶段不猜 hook 面。
#include "unreal_iostore_profile.h"

class UnrealIostoreAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "unreal_iostore"; }
  bool probe() const override {
    return fushi_voice_hook::MatchesUnrealIostoreProfile(nullptr);
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
