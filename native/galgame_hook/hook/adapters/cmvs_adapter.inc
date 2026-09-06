// CMVS（Purple Software）adapter。首版只做三件事，且全部 implemented_unverified：
//   * 身份：cmvs_profile.h 的 cfg 节名 + CPZ 归档魔数结构判据（真实样本 クロノクロック 体験版v2）；
//   * 文本：不自带 hook，交给 LunaHook 的 CMVS 引擎（vendored LunaHook32/64 均含 EmbedCMVS）；
//   * 音频：不自带 hook，走 GenericWindowsAudioAdapter 的 DirectSound/XAudio2 源 PCM
//     （样本 exe 导入 DSOUND.dll + WINMM.dll）。
// 逐句资源层（voice.cpz / voice2.cpz，CPZ6 加密归档）明确**未做**：那需要在引擎解密读取
// 之后的位置取字节，位置只能在真机上定，静态阶段不猜 hook 面。
#include "cmvs_profile.h"

class CmvsAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "cmvs"; }
  bool probe() const override { return fushi_voice_hook::MatchesCmvsProfile(nullptr); }
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
