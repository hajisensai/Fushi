#pragma once

#include <cstdint>

namespace fushi_voice_hook {

// 「模块表稳定了吗」——把「扫过一次」和「不会再变了」分开的那个判据。
//
// 为什么需要它：查词准入的收敛规则原本写作「已经扫过一次模块表 && 没人认领 →
// 报 EngineUnsupported」。但「扫过一次」在注入完成后的**第 1 拍**就成立，而参与
// 认领的引擎 probe 全是迟到信号：
//   - KiriKiri  → GetModuleHandleW("wuvorbis.dll")：语音解码器 DLL，第一句有声
//                 台词播出来之前根本没加载；
//   - Ren'Py    → 已加载的 avformat；
//   - Unity     → UnityPlayer.dll && GameAssembly.dll。
// 于是注入完成第 1 拍就发布「本引擎没做游戏内查词」，而 KiriKiri 恰恰是唯一一个
// 查词早就做好并已发布的引擎——要等到第一句语音才自愈。用户此刻打开设置页看到的
// 是一句自信的假话。
//
// 没有任何 API 能回答「这个进程以后还会不会 LoadLibrary」，所以判据只能是「模块表
// 已经安静了足够久」。**它读的是观测结果**（连续多少次全量枚举没长出新模块），
// 时间只当「至少给过多少次观测机会」的下界——一个还在每 200ms 长新模块的进程，
// 等到天亮也不会被判成稳定，而 `sleep(5s)` 会。这不是拿延时猜。
//
// 结论仍然可撤回：registry 每轮 Poll 重新汇总发布，晚到的引擎认领会把
// EngineUnsupported 立刻改回去。这里唯一要保证的是——在模块还可能没加载完的窗口
// 里，绝不先把「不支持」说出口。
class ModuleTableSettle {
 public:
  // 一次**成功完成**的全量模块枚举。
  //
  // 快照失败（CreateToolhelp32Snapshot 的 ERROR_BAD_LENGTH 在启动期很常见）
  // **不能**调：那是「没观测到」，不是「观测到没变」。混同会让快照连续失败的进程
  // 假装自己稳定了——正是原实现那个 bug 的镜像。
  void OnScanCompleted(bool discovered_new_module, uint64_t now_ms) {
    if (!scanned_) {
      scanned_ = true;
      first_scan_ms_ = now_ms;
    }
    quiet_scans_ = discovered_new_module ? 0 : quiet_scans_ + 1;
  }

  bool settled(uint64_t now_ms) const {
    return scanned_ && quiet_scans_ >= kQuietScans &&
           now_ms - first_scan_ms_ >= kFloorMs;
  }

  uint32_t quiet_scans() const { return quiet_scans_; }
  bool scanned() const { return scanned_; }

 private:
  // DispatchNewModules 的扫描节拍固定 200ms，所以 15 次 ≈ 3 秒完全无新模块。
  // 取值理由：注入器对多数引擎走 CREATE_SUSPENDED 早注入，第 1 拍 Poll 发生在
  // 游戏还没执行自己一条启动指令之前；3 秒静默排掉引擎 init 中的正常间歇。
  static constexpr uint32_t kQuietScans = 15;
  // 距首次扫描的硬下界。片头 logo / OP 动画期间模块表可以整整安静几秒，只看
  // 「连续 N 次安静」会在那段伪静默里过早收敛。
  //
  // 上界为什么不更长：同文件里已有的耐心预算是 kRetryLimit=150 × 200ms = 30 秒。
  // 把收敛也拖到 30 秒，真正不支持的游戏会在设置页上「正在判定」半分钟，那比误报
  // 还难受。5s + 3s quiet 落在两者之间。
  static constexpr uint64_t kFloorMs = 5000;

  bool scanned_ = false;
  uint64_t first_scan_ms_ = 0;
  uint32_t quiet_scans_ = 0;
};

}  // namespace fushi_voice_hook
