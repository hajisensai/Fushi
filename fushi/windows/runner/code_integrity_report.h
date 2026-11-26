#ifndef RUNNER_CODE_INTEGRITY_REPORT_H_
#define RUNNER_CODE_INTEGRITY_REPORT_H_

#include <windows.h>

#include <cstddef>
#include <cwctype>
#include <string>
#include <utility>
#include <vector>

// Windows 代码完整性（WDAC / 智能应用控制）拦截记录的纯逻辑部分（BUG-5484 取证）。
// 平台调用（EvtQuery / 注册表 / 写日志）在 code_integrity_probe.cpp；这里只有
// 查询串、事件 XML 解析、「是不是 Fushi 的文件」判据、脱敏与成行格式，随每次 Windows
// runner 构建由 tests/code_integrity_report_test.cpp 执行。
//
// 起因：Surface Pro 7+ 用户的机器开着智能应用控制（强制模式），安装器报 4551（BUG-5515），
// 3.4 启动又隐形卡住（BUG-5484）。被拦的文件只记在「事件查看器 › Microsoft › Windows ›
// CodeIntegrity › Operational」里，普通用户不会去翻——所以 runner 自己读、自己写进日志，
// 下次启动折进错误日志随反馈上传。
namespace fushi {

// 「已拦截」（非审计放行）类事件：%2 = 被拦文件，%4 = 发起加载的进程（provider 元数据
// 的消息模板）。3118 = Smart App Control Block Details。审计类（3034 / 3076 等，放行了）不收。
inline constexpr unsigned kCodeIntegrityBlockEventIds[] = {
    3033, 3063, 3068, 3077, 3079, 3081, 3086, 3104, 3118};

// 只看最近 14 天：更早的拦截与当前这次故障无关。
inline constexpr unsigned long long kCodeIntegrityLookbackMs =
    14ULL * 24 * 60 * 60 * 1000;

// 每次报告最多写这么多条（新的在前），防止策略误伤整个目录时把日志刷爆。
inline constexpr std::size_t kMaxCodeIntegrityLinesPerReport = 20;

// 每次启动在主窗建好这么久后查一次（不管有没有卡住）：被拦的 DLL 可能只让某个功能
// 静默失效，不一定卡启动。启动卡死时启动期限（45 s）那一刻另查一次。
inline constexpr ULONGLONG kCodeIntegrityLaunchProbeDelayMs = 60000;

struct CodeIntegrityEvent {
  unsigned event_id = 0;
  unsigned long long record_id = 0;
  std::wstring time;  // TimeCreated/@SystemTime（UTC，ISO 8601）
  std::vector<std::pair<std::wstring, std::wstring>> data;  // EventData/Data
};

inline std::wstring BuildCodeIntegrityQuery() {
  std::wstring q = L"*[System[(";
  bool first = true;
  for (const unsigned id : kCodeIntegrityBlockEventIds) {
    if (!first) q += L" or ";
    first = false;
    q += L"EventID=" + std::to_wstring(id);
  }
  q += L") and TimeCreated[timediff(@SystemTime) <= " +
       std::to_wstring(kCodeIntegrityLookbackMs) + L"]]]";
  return q;
}

inline std::wstring ToLowerW(std::wstring s) {
  for (wchar_t& c : s) c = static_cast<wchar_t>(towlower(c));
  return s;
}

inline std::wstring DecodeXmlEntities(const std::wstring& s) {
  std::wstring out;
  out.reserve(s.size());
  for (std::size_t i = 0; i < s.size(); ++i) {
    if (s[i] != L'&') {
      out.push_back(s[i]);
      continue;
    }
    static const std::pair<const wchar_t*, wchar_t> kEntities[] = {
        {L"&amp;", L'&'}, {L"&lt;", L'<'}, {L"&gt;", L'>'},
        {L"&quot;", L'"'}, {L"&apos;", L'\''}};
    bool decoded = false;
    for (const auto& e : kEntities) {
      const std::wstring name(e.first);
      if (s.compare(i, name.size(), name) == 0) {
        out.push_back(e.second);
        i += name.size() - 1;
        decoded = true;
        break;
      }
    }
    if (!decoded) out.push_back(s[i]);
  }
  return out;
}

// 取 <tag ...>text</tag> 的 text（tag 可带属性）；找不到返回 false。
inline bool XmlElementText(const std::wstring& xml, const wchar_t* tag,
                           std::wstring* text) {
  const std::wstring open = std::wstring(L"<") + tag;
  std::size_t pos = 0;
  while ((pos = xml.find(open, pos)) != std::wstring::npos) {
    const std::size_t after = pos + open.size();
    if (after < xml.size() && (xml[after] == L'>' || xml[after] == L' ')) break;
    pos = after;
  }
  if (pos == std::wstring::npos) return false;
  const std::size_t gt = xml.find(L'>', pos);
  if (gt == std::wstring::npos || xml[gt - 1] == L'/') return false;
  const std::size_t end = xml.find(L'<', gt + 1);
  if (end == std::wstring::npos) return false;
  *text = DecodeXmlEntities(xml.substr(gt + 1, end - gt - 1));
  return true;
}

// 取 attr='v' 或 attr="v" 的 v，从 from 开始找。
inline bool XmlAttribute(const std::wstring& xml, std::size_t from,
                         const wchar_t* attr, std::wstring* value,
                         std::size_t* value_end = nullptr) {
  const std::wstring key = std::wstring(attr) + L"=";
  const std::size_t pos = xml.find(key, from);
  if (pos == std::wstring::npos || pos + key.size() >= xml.size()) return false;
  const wchar_t quote = xml[pos + key.size()];
  if (quote != L'\'' && quote != L'"') return false;
  const std::size_t start = pos + key.size() + 1;
  const std::size_t end = xml.find(quote, start);
  if (end == std::wstring::npos) return false;
  *value = DecodeXmlEntities(xml.substr(start, end - start));
  if (value_end != nullptr) *value_end = end + 1;
  return true;
}

// 解析 EvtRender(EvtRenderEventXml) 的输出。EventID 与 EventRecordID 缺一不可。
inline bool ParseCodeIntegrityEventXml(const std::wstring& xml,
                                       CodeIntegrityEvent* event) {
  std::wstring text;
  if (!XmlElementText(xml, L"EventID", &text) || text.empty()) return false;
  event->event_id = static_cast<unsigned>(wcstoul(text.c_str(), nullptr, 10));
  if (!XmlElementText(xml, L"EventRecordID", &text) || text.empty()) {
    return false;
  }
  event->record_id = wcstoull(text.c_str(), nullptr, 10);
  const std::size_t time_tag = xml.find(L"<TimeCreated");
  if (time_tag != std::wstring::npos) {
    XmlAttribute(xml, time_tag, L"SystemTime", &event->time);
  }
  event->data.clear();
  std::size_t pos = 0;
  while ((pos = xml.find(L"<Data Name=", pos)) != std::wstring::npos) {
    std::wstring name;
    std::size_t name_end = 0;
    if (!XmlAttribute(xml, pos, L"Name", &name, &name_end)) break;
    const std::size_t gt = xml.find(L'>', name_end);
    if (gt == std::wstring::npos) break;
    std::wstring value;
    if (xml[gt - 1] != L'/') {
      const std::size_t close = xml.find(L"</Data>", gt + 1);
      if (close == std::wstring::npos) break;
      value = DecodeXmlEntities(xml.substr(gt + 1, close - gt - 1));
      pos = close;
    } else {
      pos = gt;
    }
    event->data.emplace_back(std::move(name), std::move(value));
  }
  return true;
}

// 把 DOS 路径变成可在 NT 设备路径里做子串匹配的键：去掉 \\?\ 与盘符、去尾部反斜杠、
// 转小写。事件里的路径是 \Device\HarddiskVolume3\Users\...，盘符对不上，路径尾部对得上。
inline std::wstring PathMatchKey(const std::wstring& dos_path) {
  std::wstring p = dos_path;
  if (p.rfind(L"\\\\?\\", 0) == 0) p = p.substr(4);
  if (p.size() >= 2 && p[1] == L':') p = p.substr(2);
  while (!p.empty() && (p.back() == L'\\' || p.back() == L'/')) p.pop_back();
  return ToLowerW(p);
}

inline std::wstring FileNameOf(const std::wstring& path) {
  const std::size_t pos = path.find_last_of(L"\\/");
  return pos == std::wstring::npos ? path : path.substr(pos + 1);
}

// 一个字段值算「Fushi 的」：落在安装目录里（fushi.exe 加载的 DLL、随包工具），或文件名
// 以 fushi 开头（下载到别处的 fushi-*-windows-setup.exe 与它解出的同名 .tmp 安装程序）。
inline bool ValueTouchesFushi(const std::wstring& value,
                              const std::wstring& app_dir_key) {
  const std::wstring lower = ToLowerW(value);
  if (!app_dir_key.empty() &&
      lower.find(app_dir_key + L"\\") != std::wstring::npos) {
    return true;
  }
  return FileNameOf(lower).rfind(L"fushi", 0) == 0;
}

inline bool EventTouchesFushi(const CodeIntegrityEvent& event,
                              const std::wstring& app_dir_key) {
  for (const auto& field : event.data) {
    if (ValueTouchesFushi(field.second, app_dir_key)) return true;
  }
  return false;
}

inline const std::wstring* CodeIntegrityDataValue(
    const CodeIntegrityEvent& event, const wchar_t* name) {
  for (const auto& field : event.data) {
    if (field.first == name) return &field.second;
  }
  return nullptr;
}

// 路径里的用户目录换成 %USERPROFILE%：错误日志随反馈上传，不带用户名。
inline std::wstring RedactUserProfile(const std::wstring& text,
                                      const std::wstring& profile_key) {
  if (profile_key.empty()) return text;
  const std::wstring lower = ToLowerW(text);
  std::wstring out;
  std::size_t from = 0;
  for (;;) {
    const std::size_t hit = lower.find(profile_key, from);
    if (hit == std::wstring::npos) break;
    out.append(text, from, hit - from);
    out += L"%USERPROFILE%";
    from = hit + profile_key.size();
  }
  out.append(text, from, std::wstring::npos);
  return out;
}

// 只把上次报告之后的新记录写进日志（record id 单调递增），每次启动不重复报同一条。
inline bool IsUnreportedRecord(unsigned long long record_id,
                               unsigned long long last_reported_id) {
  return record_id > last_reported_id;
}

// 通道被清空（事件查看器「清除日志」、wevtutil cl、系统重置）后 record id 从 1 重新计数。
// 游标是上一轮查询结果里的最大 id；同一过滤条件下通道没被清空时，结果里最新的一条只会 >= 游标
// （或结果为空）。最新一条比游标小就是通道已重置：游标归零重新报，否则之后的拦截永远报不出。
inline bool IsCursorReset(unsigned long long newest_record_id,
                          unsigned long long last_reported_id) {
  return newest_record_id < last_reported_id;
}

// 有命中就写；启动卡死那一次即使零命中也写（「SAC 开着、没拦到 Fushi」本身就是排除项）。
inline bool ShouldWriteCodeIntegrityHeader(bool startup_stall,
                                           std::size_t matched) {
  return startup_stall || matched > 0;
}

// HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy\VerifiedAndReputablePolicyState。
inline const wchar_t* SmartAppControlStateName(bool present, DWORD value) {
  if (!present) return L"unavailable";
  switch (value) {
    case 0:
      return L"off";
    case 1:
      return L"on (enforcing)";
    case 2:
      return L"evaluation";
    default:
      return L"unknown";
  }
}

inline std::wstring FormatCodeIntegrityLine(const CodeIntegrityEvent& event,
                                            const std::wstring& app_dir_key,
                                            const std::wstring& profile_key) {
  const std::wstring* file = CodeIntegrityDataValue(event, L"File Name");
  const std::wstring* process = CodeIntegrityDataValue(event, L"Process Name");
  const std::wstring* policy = CodeIntegrityDataValue(event, L"PolicyName");
  std::wstring file_text;
  if (file != nullptr && !file->empty()) {
    file_text = *file;
  } else {
    // 3118 等没有 File Name 字段的事件：取第一个指向 Fushi 的字段值。
    for (const auto& field : event.data) {
      if (ValueTouchesFushi(field.second, app_dir_key)) {
        file_text = field.second;
        break;
      }
    }
  }
  std::wstring line = L"code-integrity: blocked event=" +
                      std::to_wstring(event.event_id) + L" at=" +
                      (event.time.empty() ? L"?" : event.time) + L" file=" +
                      (file_text.empty() ? L"?" : file_text) + L" process=" +
                      (process != nullptr && !process->empty() ? *process
                                                               : L"?");
  if (policy != nullptr && !policy->empty()) line += L" policy=" + *policy;
  return RedactUserProfile(line, profile_key);
}

}  // namespace fushi

#endif  // RUNNER_CODE_INTEGRITY_REPORT_H_
