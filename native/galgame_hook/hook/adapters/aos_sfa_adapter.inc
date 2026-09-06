// AOS / SFA（Princess Sugar・Atelier Kaguya 系）adapter。首版只做两件事，全部
// implemented_unverified：
//   * 身份：aos_sfa_profile.h 的「*.aos 头部写着自身文件名」结构判据
//     （真实样本 姫様ＬＯＶＥライフ！2015-08，5 个归档全部满足）；
//   * 音频：不自带 hook，走 GenericWindowsAudioAdapter 的源 PCM。真机实测在挂载原盘后
//     voice_clips 持续增长、44100/2/16、peak 14570（非静音）。
//
// **刻意不声称 kText**：同一局里 `luna_active=0`、`text_events=0`，LunaHook 没有产出。
// 这个引擎在 vendored LunaHook 里有没有对应 hook，本轮没有能作证的手段（DLL 里查不到
// 引擎名字符串），所以文本能力留空、等真机观测到再加——不拿「大概有」当能力声明。
//
// 逐句语音资源层（cv.aos，675 MB）明确**未做**：AOS 归档的索引与编码要在真机上看引擎
// 怎么读才能定，静态阶段不猜 hook 面。
#include "aos_sfa_profile.h"

class AosSfaAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "aos_sfa"; }
  bool probe() const override { return fushi_voice_hook::MatchesAosSfaProfile(nullptr); }
  // 没有引擎专属 hook 可装：installed_ 只表示「身份成立、共享 PCM 路径对此进程生效」。
  bool install() override {
    installed_ = probe();
    return installed_;
  }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kPcmAudio;
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
