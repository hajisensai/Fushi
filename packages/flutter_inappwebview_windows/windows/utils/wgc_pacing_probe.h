#ifndef FLUTTER_INAPPWEBVIEW_PLUGIN_WGC_PACING_PROBE_H_
#define FLUTTER_INAPPWEBVIEW_PLUGIN_WGC_PACING_PROBE_H_

#include <windows.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <string>
#include <vector>

#include "wgc_log.h"

namespace flutter_inappwebview_plugin
{
  // WebView 纹理桥的帧节奏诊断（BUG-4114）。环境变量 FUSHI_WGC_PACING_PROBE=1 时
  // 才采样；关闭时每个埋点只是一次读静态 bool（零分配、零锁）。每个桥每秒向
  // wgc_capture.log 写一行 evt=pacing：
  //   wake   取帧线程被唤醒的间隔（旧实现是 UI 线程定时器 tick）
  //   multi  一次唤醒排空出 >1 帧的次数（取帧晚了，帧在帧池里排队 / 被挤掉）
  //   cap    相邻 WGC 帧 SystemRelativeTime 的差（DWM 实际交帧节奏）
  //   ras    栅格线程取走新帧（纹理回调）的间隔
  // p50/p95/max 毫秒，gt20 = 超过 20ms（60Hz 下至少掉一帧）的次数。
  class WgcPacingProbe {
  public:
    static bool Enabled()
    {
      static const bool enabled = []() {
        char value[8] = {};
        const DWORD len =
          GetEnvironmentVariableA("FUSHI_WGC_PACING_PROBE", value, sizeof(value));
        return len > 0 && len < sizeof(value) && value[0] == '1';
        }();
      return enabled;
    }

    explicit WgcPacingProbe(const void* owner) : owner_(owner) {}

    void OnWake()
    {
      if (!Enabled()) return;
      const std::lock_guard<std::mutex> lock(mutex_);
      const double now = NowMs();
      if (last_wake_ms_ > 0.0) wake_.push_back(now - last_wake_ms_);
      last_wake_ms_ = now;
      MaybeFlushLocked(now);
    }

    void OnDrained(int frames)
    {
      if (!Enabled() || frames <= 0) return;
      const std::lock_guard<std::mutex> lock(mutex_);
      frames_ += frames;
      if (frames > 1) ++multi_;
    }

    // [system_relative_100ns]：IDirect3D11CaptureFrame::SystemRelativeTime（QPC 域，
    // 100ns 单位）。
    void OnFrame(int64_t system_relative_100ns)
    {
      if (!Enabled()) return;
      const std::lock_guard<std::mutex> lock(mutex_);
      if (last_cap_100ns_ > 0 && system_relative_100ns > last_cap_100ns_) {
        cap_.push_back(
          static_cast<double>(system_relative_100ns - last_cap_100ns_) / 10000.0);
      }
      last_cap_100ns_ = system_relative_100ns;
    }

    void OnRaster()
    {
      if (!Enabled()) return;
      const std::lock_guard<std::mutex> lock(mutex_);
      const double now = NowMs();
      if (last_ras_ms_ > 0.0) ras_.push_back(now - last_ras_ms_);
      last_ras_ms_ = now;
      MaybeFlushLocked(now);
    }

  private:
    static double NowMs()
    {
      LARGE_INTEGER freq, counter;
      QueryPerformanceFrequency(&freq);
      QueryPerformanceCounter(&counter);
      return static_cast<double>(counter.QuadPart) * 1000.0 /
        static_cast<double>(freq.QuadPart);
    }

    static std::string Stats(const char* label, std::vector<double>& v)
    {
      char buffer[160];
      if (v.empty()) {
        std::snprintf(buffer, sizeof(buffer), "%s_n=0", label);
        return buffer;
      }
      std::sort(v.begin(), v.end());
      const auto pct = [&v](double p) {
        const size_t i = static_cast<size_t>(p * static_cast<double>(v.size() - 1));
        return v[i];
        };
      int gt20 = 0;
      for (double d : v) {
        if (d > 20.0) ++gt20;
      }
      std::snprintf(buffer, sizeof(buffer),
        "%s_n=%zu %s_p50=%.2f %s_p95=%.2f %s_max=%.2f %s_gt20=%d", label,
        v.size(), label, pct(0.5), label, pct(0.95), label, v.back(), label,
        gt20);
      return buffer;
    }

    void MaybeFlushLocked(double now)
    {
      if (window_start_ms_ <= 0.0) {
        window_start_ms_ = now;
        return;
      }
      if (now - window_start_ms_ < 1000.0) return;
      if (frames_ > 0 || !ras_.empty()) {
        char head[64];
        std::snprintf(head, sizeof(head), "frames=%d multi=%d", frames_, multi_);
        WgcLog::Write("pacing", owner_,
          std::string(head) + " " + Stats("wake", wake_) + " " +
          Stats("cap", cap_) + " " + Stats("ras", ras_));
      }
      wake_.clear();
      cap_.clear();
      ras_.clear();
      frames_ = 0;
      multi_ = 0;
      window_start_ms_ = now;
    }

    const void* owner_;
    std::mutex mutex_;
    std::vector<double> wake_;
    std::vector<double> cap_;
    std::vector<double> ras_;
    int frames_ = 0;
    int multi_ = 0;
    double last_wake_ms_ = 0.0;
    double last_ras_ms_ = 0.0;
    int64_t last_cap_100ns_ = 0;
    double window_start_ms_ = 0.0;
  };
}

#endif  // FLUTTER_INAPPWEBVIEW_PLUGIN_WGC_PACING_PROBE_H_
