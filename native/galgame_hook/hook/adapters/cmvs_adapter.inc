// CMVS（Purple Software）adapter。各能力仍为 implemented_unverified：
//   * 身份：cmvs_profile.h 的 cfg 节名 + CPZ 归档魔数结构判据（真实样本 クロノクロック 体験版v2）；
//   * 文本：不自带 hook，交给 LunaHook 的 CMVS 引擎（vendored LunaHook32/64 均含 EmbedCMVS）；
//   * 音频：x64 逐句资源层 cmvs_voice.inc——在引擎自己的组加载器返回处拷贝语音组
//     （voice*.cpz）解密后的整段 Ogg，站点由主映像异常目录 + 结构判据解析（不读哈希）；
//     x86 无展开表证明函数入口，资源层 fail closed。通用 DirectSound/XAudio2 源 PCM
//     （GenericWindowsAudioAdapter）保留为兜底。
//   * 查词：仅已测 ChronoClock x64 哈希启用帧/字格读取，匹配所选文本并验证投影。
#include "cmvs_profile.h"
#include "cmvs_lookup.inc"
#include "cmvs_voice.inc"

class CmvsAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "cmvs"; }
  bool probe() const override { return fushi_voice_hook::MatchesCmvsProfile(nullptr); }
  // 整体身份与查词的精确构建准入分开，其他 CMVS 版本保留共享文本/PCM 路径。
  bool install() override {
    installed_ = probe();
    if (installed_) {
      InstallCmvsLookup();
      // 语音层与查词互相独立：任一失败不影响另一条和共享文本/PCM 路径。
      TryHookCmvsVoice();
    }
    return installed_;
  }
  bool lookup_sensor_available() const {
    return g_cmvs_hook_installation.enabled() && g_cmvs_input_installation.enabled();
  }
  void ProcessPendingEvents() {
    ProcessCmvsVoiceTasks();
    ProcessCmvsLookupTick();
  }
  fushi_voice_hook::LookupAdmissionReport lookupAdmission() const override {
    fushi_voice_hook::LookupAdmissionReport report;
    report.state = (g_cmvs_hook_installation.enabled() && g_cmvs_input_installation.enabled())
        ? fushi_voice_hook::kLookupAdmissionSensorInstalled
        : g_cmvs_identity_matched ? fushi_voice_hook::kLookupAdmissionIdentityAccepted
                                 : fushi_voice_hook::kLookupAdmissionEngineUnsupported;
    return report;
  }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    const auto base = fushi_voice_hook::AdapterCapability::kText |
                      fushi_voice_hook::AdapterCapability::kPcmAudio;
    return CmvsVoiceArmed()
        ? base | fushi_voice_hook::AdapterCapability::kResourceAudio
        : base;
  }
  void onModuleLoaded(const wchar_t* module_name) override {
    // 身份来自磁盘布局，启动时一次判定即可；模块通知只作重试接缝。
    if (!installed_ && module_name == nullptr) install();
  }
  void shutdown() override {
    StopCmvsVoice();
    g_cmvs_hook_installation.Shutdown();
    g_cmvs_input_installation.Shutdown();
    RetireCmvsLookup();
    AcquireSRWLockExclusive(&g_cmvs_raw_lock);
    g_cmvs_raw_frame.valid = false;
    ReleaseSRWLockExclusive(&g_cmvs_raw_lock);
    installed_ = false;
  }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u : g_header->hook_diagnostics};
  }

 private:
  bool installed_ = false;
};
