#ifndef FLUTTER_INAPPWEBVIEW_PLUGIN_WGC_LOG_UTIL_H_
#define FLUTTER_INAPPWEBVIEW_PLUGIN_WGC_LOG_UTIL_H_

#include <windows.h>

#include <cstdint>
#include <string>

namespace flutter_inappwebview_plugin
{
  // BUG-209 / TODO-398：WGC（Windows.Graphics.Capture）帧捕获生命周期的结构化原生
  // 日志，**始终编译**（与 utils/log.h 的 debugLog 不同——后者整体由 NDEBUG 宏门控，
  // Release（NDEBUG）下是 no-op，且只往 std::cout/cerr 写，无 console 时不可靠）。
  //
  // 为什么需要它：BUG-209（GraphicsCapture.dll 0xc0000005 null-delegate UAF）经过十次
  // 修复，每次都「论证对了根因但真机 Release 仍复发」，因为延迟 UAF 的崩溃帧无任何
  // hibiki teardown 帧，只能靠 cdb 分析偶然留存的系统 WER minidump 反推。Release 下没有
  // 任何 WGC 生命周期日志，用户拿不到、也无法上传可读证据。本日志在帧池 create / retire /
  // stop / recreate / createSession-fail / startCapture-fail 等关键生命周期点写一行带
  // 时间戳 + 线程 id + 帧池指针的记录到固定可上传文件，让下次复发能自证「崩前发生了哪些
  // 帧池退役 / 替换、崩溃帧池是哪个指针」。
  //
  // 线程模型：WGC 的 create/retire/stop/recreate 与 FrameArrived 全在同一 UI 线程串行
  // 触发；minidump 崩溃 filter 在崩溃线程上同步执行。文件写入用裸 Win32 CreateFileW /
  // WriteFile（绝不碰 CRT/STL 堆分配），故在「堆可能已损坏」的崩溃 filter 里也安全。
  // 内部用进程级 SRWLOCK 串行化并发写（正常路径无竞争，纯防御）。
  //
  // 路径：%LOCALAPPDATA%\Hibiki\wgc_capture.log（native 自决，不依赖 Dart 下发——
  // 避免「下发前 capture 已发生」的时机赌注；LocalAppData 始终可写，无 Program Files
  // 权限问题）。Dart 侧用相同的 %LOCALAPPDATA%\Hibiki\ 常量定位读取并折进 ErrorLogService
  // 的上传链路（见 hibiki/lib/src/utils/misc/wgc_capture_log.dart）。
  class WgcLog {
  public:
    // 写一行结构化 WGC 生命周期日志（始终编译，Release 也写）。[event] 是事件名
    // （如 "create" / "retire" / "stop" / "recreate" / "createSession-fail"），
    // [pool] 是相关帧池指针（自证「崩溃帧池是哪个」），[detail] 是可选补充。
    // 输出行格式：`<ISO8601 UTC> tid=<线程id> evt=<event> pool=<0x指针> <detail>`。
    static void Write(const char* event, const void* pool,
      const std::string& detail = std::string());

  private:
    // 解析并惰性缓存日志文件完整路径（%LOCALAPPDATA%\Hibiki\wgc_capture.log），
    // 顺带确保 Hibiki 子目录存在。失败返回空串（日志静默禁用，绝不影响 capture）。
    static const std::wstring& LogFilePath();
    // 若文件已超过上限则截断（保留尾部最近内容），避免无界增长。
    static void TrimIfTooLarge(const std::wstring& path);

    static constexpr DWORD kMaxFileBytes = 512 * 1024;
  };
}

#endif  // FLUTTER_INAPPWEBVIEW_PLUGIN_WGC_LOG_UTIL_H_
