#undef NDEBUG
#include <windows.h>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>
#include "launch_failure_policy.h"

namespace {
int checks=0;
void Check(bool value,const char* boundary){
  ++checks;if(!value){std::fprintf(stderr,"FAIL %s\n",boundary);std::exit(91);}
}
struct Observation {
  bool siglus=true,ready=true;
  unsigned classify=0,wait=0,apply=0,inject=0,terminate=0,resume=0,report=0;
  HANDLE waited_handle=nullptr;
  DWORD waited_pid=0,timeout=0;
  fushi_voice_hook::LaunchFailureReason failure=fushi_voice_hook::LaunchFailureReason::kNone;
  int failure_code=0;
  std::wstring classified_path;
  std::vector<HANDLE> closed;
  std::vector<std::string> order;
} observed;
// Existing engine detection is a seam, not a second basename/directory matcher.
// It records the final child's actual identity supplied to the production block.
bool IsSiglusGame(const std::wstring& path){
  ++observed.classify;observed.classified_path=path;observed.order.push_back("classify");
  return observed.siglus;
}
bool WaitForReadyGameWindow(HANDLE handle,DWORD pid,DWORD timeout){
  ++observed.wait;observed.waited_handle=handle;observed.waited_pid=pid;
  observed.timeout=timeout;observed.order.push_back("wait");return observed.ready;
}
void ReportFailureReason(fushi_voice_hook::LaunchFailureReason reason,int code){
  ++observed.report;observed.failure=reason;observed.failure_code=code;
  observed.order.push_back("report");
}
BOOL TestCloseHandle(HANDLE handle){observed.closed.push_back(handle);observed.order.push_back("close");return TRUE;}
[[maybe_unused]] BOOL TestTerminateProcess(HANDLE,UINT){++observed.terminate;return TRUE;}
[[maybe_unused]] DWORD TestResumeThread(HANDLE){++observed.resume;return 1;}
template<typename... Args>bool ResumeLaunchedGame(Args&&...){++observed.resume;return true;}
void ApplyLunaProfiles(){++observed.apply;observed.order.push_back("apply");}
int RunInjection(){++observed.inject;observed.order.push_back("inject");return 0;}

int Orchestrate(HANDLE child_process,HANDLE target_process,DWORD target_pid,
                const std::wstring& target_exe,const PROCESS_INFORMATION& pi){
#define CloseHandle TestCloseHandle
#define TerminateProcess TestTerminateProcess
#define ResumeThread TestResumeThread
#include "followed_siglus_readiness.inc"
#undef ResumeThread
#undef TerminateProcess
#undef CloseHandle
  ApplyLunaProfiles();
  return RunInjection();
}
int OrchestrateAttach(HANDLE target,DWORD pid,const std::wstring& target_exe){
#define CloseHandle TestCloseHandle
#define TerminateProcess TestTerminateProcess
#define ResumeThread TestResumeThread
#include "attached_siglus_readiness.inc"
#undef ResumeThread
#undef TerminateProcess
#undef CloseHandle
  ApplyLunaProfiles();
  return RunInjection();
}
void TestProductionBlock(){
  const auto child=reinterpret_cast<HANDLE>(0x1100);
  const auto target=reinterpret_cast<HANDLE>(0x2200);
  PROCESS_INFORMATION pi{};pi.hProcess=reinterpret_cast<HANDLE>(0x3300);
  pi.hThread=reinterpret_cast<HANDLE>(0x4400);pi.dwProcessId=123;
  const std::wstring final_exe=L"C:\\Synthetic\\StartData\\GameData\\RenamedEngine.exe";
  // Use distinct target and owned child handle values to catch forwarding the
  // wrong handle; closure still follows ownership, not the readiness argument.
  observed={};observed.ready=false;
  Check(Orchestrate(child,target,987,final_exe,pi)==1,"unready child fails before injection");
  Check(observed.wait==1&&observed.waited_handle==target&&observed.waited_pid==987,
        "readiness uses final target handle and PID");
  Check(observed.timeout==20000,"existing bounded readiness budget");
  Check(observed.classify==1&&observed.classified_path==final_exe,"classify final child identity");
  Check(observed.report==1&&observed.failure==fushi_voice_hook::LaunchFailureReason::kInjectionFailed&&observed.failure_code==1,
        "readiness failure reported once");
  Check(observed.closed==std::vector<HANDLE>{child,pi.hThread,pi.hProcess},"close only three owned handles in order");
  Check(observed.apply==0&&observed.inject==0&&observed.terminate==0&&observed.resume==0,
        "failure neither injects nor controls game lifetime");
  Check(observed.order==std::vector<std::string>{"classify","wait","report","close","close","close"},
        "failure returns directly after cleanup");
  observed={};
  Check(Orchestrate(child,target,987,final_exe,pi)==0,"ready Siglus child continues");
  Check(observed.order==std::vector<std::string>{"classify","wait","apply","inject"},"ready gate precedes both downstream operations");
  Check(observed.closed.empty()&&observed.report==0&&observed.terminate==0&&observed.resume==0,"ready path has no failure cleanup");
  observed={};observed.siglus=false;observed.ready=false;
  Check(Orchestrate(child,target,987,L"C:\\Synthetic\\other.exe",pi)==0,"other engine child unchanged");
  Check(observed.wait==0&&observed.apply==1&&observed.inject==1&&observed.closed.empty(),"no readiness wait for non-Siglus child");
  for(bool siglus:{false,true}){
    observed={};observed.siglus=siglus;observed.ready=false;
    Check(Orchestrate(nullptr,pi.hProcess,pi.dwProcessId,final_exe,pi)==0,"direct launch unchanged");
    Check(observed.classify==0&&observed.wait==0&&observed.apply==1&&observed.inject==1&&observed.closed.empty(),
          "no duplicate wait without discovered child");
  }
}
void TestAutomaticAttachAfterFailedLaunch(){
  const auto child=reinterpret_cast<HANDLE>(0x1100);
  const auto retry_handle=reinterpret_cast<HANDLE>(0x5500);
  PROCESS_INFORMATION pi{};pi.hProcess=reinterpret_cast<HANDLE>(0x3300);
  pi.hThread=reinterpret_cast<HANDLE>(0x4400);pi.dwProcessId=123;
  const std::wstring final_exe=L"C:\\Synthetic\\GameData\\RenamedEngine.exe";
  observed={};observed.ready=false;
  Check(Orchestrate(child,child,987,final_exe,pi)==1,"failed launch leaves child uninjected");
  Check(OrchestrateAttach(retry_handle,987,final_exe)==1,
        "automatic PID retry cannot bypass unavailable child window");
  Check(observed.wait==2&&observed.waited_handle==retry_handle&&observed.waited_pid==987&&observed.timeout==20000,
        "retry waits on its own target handle and unchanged game PID");
  Check(observed.classify==2&&observed.classified_path==final_exe,
        "both entry paths classify actual game identity");
  Check(observed.closed==std::vector<HANDLE>{child,pi.hThread,pi.hProcess,retry_handle},
        "retry failure closes exactly its one additional owned handle");
  Check(observed.apply==0&&observed.inject==0&&observed.terminate==0&&observed.resume==0,
        "launch plus retry failure never injects or controls game lifetime");
  Check(observed.report==2&&observed.failure==fushi_voice_hook::LaunchFailureReason::kInjectionFailed&&observed.failure_code==1,
        "each unavailable entry reports failure once");
  Check(observed.order==std::vector<std::string>{"classify","wait","report","close","close","close",
      "classify","wait","report","close"},"retry keeps readiness before all downstream operations");
  observed={};
  Check(OrchestrateAttach(retry_handle,987,final_exe)==0,"ready PID attachment continues");
  Check(observed.wait==1&&observed.waited_handle==retry_handle&&observed.waited_pid==987&&observed.timeout==20000,
        "ready attachment forwards target identity and bounded wait");
  Check(observed.order==std::vector<std::string>{"classify","wait","apply","inject"},
        "attach readiness precedes profiles and injection");
  Check(observed.closed.empty()&&observed.report==0&&observed.terminate==0&&observed.resume==0,
        "ready attach does not run failed-gate cleanup");
  observed={};observed.siglus=false;observed.ready=false;
  Check(OrchestrateAttach(retry_handle,987,L"C:\\Synthetic\\other.exe")==0,
        "non-Siglus attachment unchanged");
  Check(observed.wait==0&&observed.order==std::vector<std::string>{"classify","apply","inject"}&&observed.closed.empty(),
        "other-engine attachment has no added wait or cleanup");
}
void TestProductionPlacement(const std::filesystem::path& source_path){
  std::ifstream input(source_path,std::ios::binary);
  Check(input.good(),"actual injector source available for placement guard");
  const std::string source((std::istreambuf_iterator<char>(input)),{});
  const std::string marker="#include \"followed_siglus_readiness.inc\"";
  const size_t launch=source.find("int RunLaunch(");
  const size_t gate=source.find(marker,launch);
  Check(launch!=std::string::npos&&gate!=std::string::npos,"actual RunLaunch contains production gate");
  Check(source.find(marker,gate+marker.size())==std::string::npos,"only one readiness include");
  const size_t child_path=source.find("target_exe = ProcessImagePath(child_process)",launch);
  const size_t apply=source.find("ApplyLunaProfiles(target_exe",gate);
  const size_t inject=source.find("RunInjection(target_process, target_pid",gate);
  Check(child_path!=std::string::npos&&child_path<gate&&gate<apply&&apply<inject&&inject!=std::string::npos,
        "gate after final child identity and before profiles and injection");
  Check(source.find("target_exe =",gate)>apply,"target identity is not reassigned after readiness");
  const std::string attached_marker="#include \"attached_siglus_readiness.inc\"";
  const size_t main=source.find("int main(");
  const size_t attach_open=source.find("HANDLE target = OpenProcess(kInjectionProcessRights, FALSE, pid)",main);
  const size_t attach_image=source.find("target_exe = ProcessImagePath(target)",main);
  const size_t attach_gate=source.find(attached_marker,main);
  const size_t attach_apply=source.find("ApplyLunaProfiles(target_exe, pid",main);
  const size_t attach_inject=source.find("RunInjection(target, pid",main);
  Check(main!=std::string::npos&&attach_open!=std::string::npos&&attach_image!=std::string::npos&&
        attach_gate!=std::string::npos&&attach_apply!=std::string::npos&&attach_inject!=std::string::npos,
        "actual PID attach uses shared process rights and readiness block");
  Check(main<attach_open&&attach_open<attach_image&&attach_image<attach_gate&&attach_gate<attach_apply&&attach_apply<attach_inject,
        "PID gate follows actual image discovery before profiles and injection");
  Check(source.find(attached_marker,attach_gate+attached_marker.size())==std::string::npos&&
        source.find("target_exe =",attach_gate)>attach_apply,"single attach gate with stable target identity");
  const size_t rights=source.find("constexpr DWORD kInjectionProcessRights =");
  Check(rights!=std::string::npos,"shared injection process rights declaration exists");
  const size_t end_rights=source.find(';',rights);
  Check(end_rights!=std::string::npos,"shared rights initializer is bounded");
  const std::string initializer=source.substr(rights,end_rights-rights);
  Check(initializer.find("| SYNCHRONIZE")!=std::string::npos&&
        initializer.find('&')==std::string::npos&&initializer.find('~')==std::string::npos,
        "PID attach handle grants SYNCHRONIZE for readiness wait");
}
}
int main(int argc,char** argv){
  TestProductionBlock();TestAutomaticAttachAfterFailedLaunch();
  const std::filesystem::path source=argc==2?std::filesystem::path(argv[1]):
      std::filesystem::path(__FILE__).parent_path().parent_path()/"injector"/"injector_main.cpp";
  TestProductionPlacement(source);
  std::printf("siglus_child_readiness_test: PASS (%d checks)\n",checks);
}
