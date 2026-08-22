// SGRE（M2 wind3d11 运行时，STEINS;GATE RE:BOOT 等）的原始语音归档适配器。
//
// 本 adapter 不装任何 hook：语音的采集面是通用 XAudio2 中间件（windows_audio_adapter.inc）。
// 它拥有的是**引擎专属的那一份东西**——voice_body.bin 归档的身份判定、映射生命周期和
// 启用标志。把这三样从通用中间件里搬出来，正是「共享中间件不得仅凭 DLL/exe 名启用」这条
// 规则要求的形状：通用 worker 只问 SgreProfileActive()，profile 不匹配时它逐字节走通用
// xWMA 重建路径，任何其它引擎都不会被这份归档逻辑碰到。
#include "sgre_profile.h"

class SgreVoiceArchiveAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "sgre_voice_archive"; }
  bool probe() const override {
    return fushi_voice_hook::MatchesSgreProfile(nullptr);
  }
  bool install() override {
    if (!probe()) return false;
    // 先置标志再映射：OpenSgreVoiceArchive 自身要查 SgreProfileActive()。
    InterlockedExchange(&fushi_voice_hook::g_sgre_profile_active, 1);
    // 在工作线程一次性映射好（322 MiB 只读映射），别把首次 CreateFile/MapViewOfFile
    // 留给第一段语音去付。
    mapped_ = fushi_voice_hook::OpenSgreVoiceArchive();
    if (mapped_ && g_header != nullptr) {
      SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagSgreArchiveMapped);
    }
    installed_ = installed_ || mapped_;
    return mapped_;
  }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kResourceAudio;
  }
  void onModuleLoaded(const wchar_t*) override {
    // 判据是磁盘上的目录布局，与模块加载时序无关；startup 装一次即可。
    if (!mapped_) install();
  }
  void shutdown() override {
    InterlockedExchange(&fushi_voice_hook::g_sgre_profile_active, 0);
    installed_ = false;
    mapped_ = false;
  }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u : g_header->xaudio_diagnostics};
  }

 private:
  bool installed_ = false;
  bool mapped_ = false;
};
