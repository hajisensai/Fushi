// release 也要真断言（同 window_activation_policy_test.cpp 的写法说明）。
#undef NDEBUG

#include "../code_integrity_report.h"

#include <iostream>
#include <string>

namespace {

bool Expect(bool condition, const std::string& message) {
  if (condition) {
    return true;
  }
  std::cerr << "FAIL: " << message << '\n';
  return false;
}

// EvtRender(EvtRenderEventXml) 的真实形状（属性用单引号、带命名空间与 Qualifiers）。
const wchar_t kBlockedDllXml[] =
    L"<Event xmlns='http://schemas.microsoft.com/win/2004/08/events/event'>"
    L"<System><Provider Name='Microsoft-Windows-CodeIntegrity' "
    L"Guid='{4ee76bd8-3cf4-44a0-a0ac-3937643e37a3}'/>"
    L"<EventID Qualifiers=''>3077</EventID><Version>5</Version>"
    L"<TimeCreated SystemTime='2026-11-25T13:10:02.1234567Z'/>"
    L"<EventRecordID>4242</EventRecordID></System><EventData>"
    L"<Data Name='File NameLength'>80</Data>"
    L"<Data Name='File Name'>\\Device\\HarddiskVolume3\\Users\\Grim\\AppData\\"
    L"Local\\Programs\\Fushi\\fushi_web_core.dll</Data>"
    L"<Data Name='Process NameLength'>60</Data>"
    L"<Data Name='Process Name'>\\Device\\HarddiskVolume3\\Users\\Grim\\AppData\\"
    L"Local\\Programs\\Fushi\\fushi.exe</Data>"
    L"<Data Name='Requested Signing Level'>8</Data>"
    L"<Data Name='PolicyName'>VerifiedAndReputableDesktop</Data>"
    L"<Data Name='Empty'/>"
    L"</EventData></Event>";

const wchar_t kInstallerTmpXml[] =
    L"<Event><System><EventID>3118</EventID>"
    L"<TimeCreated SystemTime=\"2026-11-26T07:50:00Z\"/>"
    L"<EventRecordID>4300</EventRecordID></System><EventData>"
    L"<Data Name=\"Path\">\\Device\\HarddiskVolume3\\Users\\Grim\\AppData\\Local\\"
    L"Temp\\is-ABC12.tmp\\fushi-3.4.0-debug.32705-windows-setup.tmp</Data>"
    L"<Data Name=\"Note\">a &amp; b &lt;c&gt;</Data>"
    L"</EventData></Event>";

const wchar_t kOtherAppXml[] =
    L"<Event><System><EventID>3077</EventID>"
    L"<EventRecordID>4301</EventRecordID></System><EventData>"
    L"<Data Name='File Name'>\\Device\\HarddiskVolume3\\Program Files\\"
    L"Other\\plugin.dll</Data>"
    L"<Data Name='Process Name'>\\Device\\HarddiskVolume3\\Program Files\\"
    L"Other\\other.exe</Data></EventData></Event>";

}  // namespace

int main() {
  using namespace fushi;
  bool passed = true;

  const std::wstring query = BuildCodeIntegrityQuery();
  passed &= Expect(query.find(L"EventID=3077") != std::wstring::npos &&
                       query.find(L"EventID=3033") != std::wstring::npos &&
                       query.find(L"EventID=3118") != std::wstring::npos,
                   "query covers enforced block events and SAC block details");
  passed &= Expect(query.find(L"EventID=3076") == std::wstring::npos &&
                       query.find(L"EventID=3034") == std::wstring::npos,
                   "query skips audit-only (allowed) events");
  passed &= Expect(query.find(L"timediff(@SystemTime) <= 1209600000") !=
                       std::wstring::npos,
                   "query is bounded to the last 14 days");

  CodeIntegrityEvent dll;
  passed &= Expect(ParseCodeIntegrityEventXml(kBlockedDllXml, &dll),
                   "real-shaped 3077 XML parses");
  passed &= Expect(dll.event_id == 3077 && dll.record_id == 4242,
                   "event id and record id are read");
  passed &= Expect(dll.time == L"2026-11-25T13:10:02.1234567Z",
                   "TimeCreated/@SystemTime is read");
  const std::wstring* file = CodeIntegrityDataValue(dll, L"File Name");
  passed &= Expect(file != nullptr &&
                       file->find(L"fushi_web_core.dll") != std::wstring::npos,
                   "File Name data field is read");
  const std::wstring* empty = CodeIntegrityDataValue(dll, L"Empty");
  passed &= Expect(empty != nullptr && empty->empty(),
                   "self-closing <Data/> yields an empty value");

  const std::wstring app_key =
      PathMatchKey(L"C:\\Users\\Grim\\AppData\\Local\\Programs\\Fushi\\");
  passed &= Expect(app_key == L"\\users\\grim\\appdata\\local\\programs\\fushi",
                   "match key drops drive letter, trailing slash and case");
  passed &= Expect(PathMatchKey(L"\\\\?\\D:\\Fushi") == L"\\fushi",
                   "match key drops the \\\\?\\ prefix");
  passed &= Expect(EventTouchesFushi(dll, app_key),
                   "a DLL under the install dir (NT device path) matches");

  passed &= Expect(!ValueTouchesFushi(
                       L"\\Device\\X\\Users\\Grim\\AppData\\Local\\Programs\\"
                       L"Fushi2\\x.dll",
                       app_key),
                   "a sibling directory sharing the prefix does not match");

  CodeIntegrityEvent tmp;
  passed &= Expect(ParseCodeIntegrityEventXml(kInstallerTmpXml, &tmp),
                   "double-quoted attributes parse");
  passed &= Expect(EventTouchesFushi(tmp, app_key),
                   "the installer's extracted fushi-*.tmp in %TEMP% matches");
  const std::wstring* note = CodeIntegrityDataValue(tmp, L"Note");
  passed &= Expect(note != nullptr && *note == L"a & b <c>",
                   "XML entities are decoded");

  CodeIntegrityEvent other;
  passed &= Expect(ParseCodeIntegrityEventXml(kOtherAppXml, &other),
                   "other app's event parses");
  passed &= Expect(!EventTouchesFushi(other, app_key),
                   "another app's blocked DLL is not reported");

  passed &= Expect(!ParseCodeIntegrityEventXml(L"<Event><System></System></Event>",
                                               &other),
                   "XML without EventID is rejected");

  const std::wstring profile_key = PathMatchKey(L"C:\\Users\\Grim");
  const std::wstring line = FormatCodeIntegrityLine(dll, app_key, profile_key);
  passed &= Expect(line.find(L"event=3077") != std::wstring::npos &&
                       line.find(L"policy=VerifiedAndReputableDesktop") !=
                           std::wstring::npos &&
                       line.find(L"fushi_web_core.dll") != std::wstring::npos,
                   "line names the event, the blocked file and the policy");
  passed &= Expect(line.find(L"Grim") == std::wstring::npos &&
                       line.find(L"%USERPROFILE%\\AppData") != std::wstring::npos,
                   "user name is redacted from every path in the line");
  const std::wstring tmp_line = FormatCodeIntegrityLine(tmp, app_key, profile_key);
  passed &= Expect(tmp_line.find(L"windows-setup.tmp") != std::wstring::npos &&
                       tmp_line.find(L"process=?") != std::wstring::npos,
                   "events without File Name fall back to the Fushi-touching value");

  passed &= Expect(IsUnreportedRecord(4243, 4242) && !IsUnreportedRecord(4242, 4242),
                   "records are reported once (cursor is exclusive)");
  passed &= Expect(ShouldWriteCodeIntegrityHeader(true, 0),
                   "startup stall always records the SAC state");
  passed &= Expect(!ShouldWriteCodeIntegrityHeader(false, 0) &&
                       ShouldWriteCodeIntegrityHeader(false, 1),
                   "a normal launch only writes when something was blocked");

  passed &= Expect(std::wstring(SmartAppControlStateName(true, 1)) ==
                       L"on (enforcing)" &&
                       std::wstring(SmartAppControlStateName(true, 2)) ==
                           L"evaluation" &&
                       std::wstring(SmartAppControlStateName(true, 0)) == L"off" &&
                       std::wstring(SmartAppControlStateName(false, 0)) ==
                           L"unavailable",
                   "SAC registry states map to names");

  if (!passed) return 1;
  std::cout << "code_integrity_report_test: all assertions passed\n";
  return 0;
}
