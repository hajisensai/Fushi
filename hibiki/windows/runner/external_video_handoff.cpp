#include "external_video_handoff.h"

#include <vector>

namespace hibiki {

namespace {

// UTF-16 → UTF-8。失败 / 空输入返回空串。
std::string Utf8FromWide(const std::wstring& wide) {
  if (wide.empty()) {
    return std::string();
  }
  int size = ::WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                   static_cast<int>(wide.size()), nullptr, 0,
                                   nullptr, nullptr);
  if (size <= 0) {
    return std::string();
  }
  std::string out(static_cast<size_t>(size), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                        static_cast<int>(wide.size()), out.data(), size,
                        nullptr, nullptr);
  return out;
}

}  // namespace

bool SendExternalVideoPath(HWND target, const std::wstring& video_path) {
  if (target == nullptr) {
    return false;
  }
  const std::string utf8 = Utf8FromWide(video_path);
  if (utf8.empty()) {
    return false;
  }
  // COPYDATASTRUCT::lpData 是非 const void*，但接收方只读不改；用一份本地拷贝喂给
  // SendMessage（同步、跨进程封送，函数返回时数据已被首实例处理完）。
  std::vector<char> buffer(utf8.begin(), utf8.end());
  COPYDATASTRUCT cds;
  cds.dwData = kExternalVideoCopyDataMagic;
  cds.cbData = static_cast<DWORD>(buffer.size());
  cds.lpData = buffer.data();
  ::SendMessageW(target, WM_COPYDATA, 0,
                 reinterpret_cast<LPARAM>(&cds));
  return true;
}

std::string DecodeExternalVideoPath(const COPYDATASTRUCT* data) {
  if (data == nullptr) {
    return std::string();
  }
  if (data->dwData != kExternalVideoCopyDataMagic) {
    return std::string();  // 不是本协议的消息，忽略。
  }
  if (data->cbData == 0 || data->lpData == nullptr) {
    return std::string();
  }
  return std::string(static_cast<const char*>(data->lpData),
                     static_cast<size_t>(data->cbData));
}

}  // namespace hibiki
