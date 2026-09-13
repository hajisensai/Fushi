#undef NDEBUG
#include <windows.h>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <map>
#include "siglus_native_message_capture.h"

namespace {
using namespace fushi_voice_hook;
struct Memory {
  std::map<uint32_t,uint32_t> words;
  bool operator()(uint32_t address,uint32_t* out) {
    const auto it=words.find(address);if(it==words.end())return false;
    *out=it->second;return true;
  }
};
struct Fixture {
  SiglusNativeMessageLayout layout{{0x1f8,0x1e0,0x228,0x22c,0x1c0,0,0},0x7000};
  SiglusNativeMessageSavedRegisters outer{},inner{};
  SiglusNativeMessageTicket ticket{};
  SiglusMessageOwnerSnapshot frozen{};
  Memory memory;
  explicit Fixture(uint32_t esp=0x4000) {
    outer.saved_esp=esp-4;outer.ecx=0x1000;
    inner.ebx=esp-4;inner.ecx=esp+0xc;
    inner.ebp=(esp-12)&~7u;inner.edi=0x1000;
    inner.saved_esp=inner.ebp-0x60-4;
    memory.words={{0x11f8,10100125},{0x11e0,1},{0x1228,0x2000},
                  {0x122c,0x2540},{esp,0x9000},{inner.ebp+4,0x9000},
                  {inner.ebp-0x10,esp-4},{inner.ebp-0x60,0x7000}};
  }
  bool Arm(){return ArmSiglusNativeMessageTicket(layout,outer,memory,&ticket);}
  bool Consume(){return ConsumeSiglusNativeMessageTicket(layout,inner,memory,&ticket,&frozen);}
};
void TestTickets(){
  // Both possible DWORD-aligned original ESP residues exercise the actual
  // dynamic alignment, not an assumed fixed difference between entry and EBP.
  for(uint32_t esp: {0x4000u,0x4004u}) {
    Fixture x(esp);assert(x.Arm()&&x.Consume());assert(x.frozen.voice_key==10100125);
    assert(!x.Consume()&&!x.ticket.armed&&x.frozen.voice_key==0);
    assert(x.Arm()&&x.Consume()); // same owner/ESP/key, new real invocation
  }
  // A fresh invocation replaces even an unconsumed ticket at the same ESP.
  {Fixture x;assert(x.Arm());x.memory.words[0x11f8]=10100131;
   assert(x.Arm()&&x.Consume());assert(x.frozen.voice_key==10100131);}
  for(uint32_t key: {0u,0xffffu,UINT32_MAX}) {
    Fixture x;x.memory.words[0x11f8]=key;assert(x.Arm()&&x.Consume());
    assert(x.frozen.voice_key==key); // only audio binding rejects UINT32_MAX
  }
  // Different voice/silent outer callers remain legal; only this invocation's
  // copied return address is corroborated, never an external caller whitelist.
  {Fixture x;x.memory.words[0x4000]=0x812345;x.memory.words[x.inner.ebp+4]=0x812345;
   assert(x.Arm()&&x.Consume());}
  for(int i=0;i<13;++i){Fixture x;assert(x.Arm());switch(i){
    case 0:++x.inner.ebx;break;case 1:++x.inner.ecx;break;
    case 2:++x.inner.edi;break;case 3:x.inner.ebp+=8;break;
    case 4:++x.memory.words[x.inner.ebp-0x10];break;
    case 5:++x.memory.words[x.inner.ebp+4];break;
    case 6:++x.memory.words[x.inner.ebp-0x60];break;
    case 7:++x.memory.words[0x11f8];break;
    case 8:++x.memory.words[0x11e0];break;
    case 9:x.memory.words[0x1228]+=0x1c0;break;
    case 10:x.memory.words[0x122c]+=0x1c0;break;
    case 11:x.inner.saved_esp=UINT32_MAX;break;
    case 12:x.inner.saved_esp=x.inner.ebp-4;break;
   }assert(!x.Consume()&&!x.ticket.armed);assert(!x.Consume());}
  for(int i=0;i<8;++i){Fixture x;assert(x.Arm());switch(i){
    case 0:x.outer.saved_esp=UINT32_MAX;break;
    case 1:x.outer.saved_esp=UINT32_MAX-4;break;
    case 2:x.outer.saved_esp=0;break;
    case 3:x.outer.ecx=UINT32_MAX-4;break;
    case 4:x.memory.words[0x11e0]=UINT32_MAX;break;
    case 5:x.memory.words[0x11e0]=3;break;
    case 6:x.memory.words[0x122c]++;break;
    case 7:x.layout.native_text_return=0;break;
   }assert(!x.Arm()&&!x.ticket.armed);assert(!x.Consume());}
  {Fixture x;assert(x.Arm());x.outer.saved_esp=0x5000-4;
   x.memory.words[0x5000]=0x9000;assert(x.Arm());assert(!x.Consume());}
  // Both still lie below EBP and have the correct return address, so the old
  // loose inequality would admit them. Only the proved exact call depth rejects.
  for(uint32_t depth:{0x5cu,0x64u}) {
    Fixture x;assert(x.Arm());const uint32_t esp=x.inner.ebp-depth;
    x.inner.saved_esp=esp-4;x.memory.words[esp]=x.layout.native_text_return;
    assert(!x.Consume()&&!x.ticket.armed);
  }
  const uint32_t owner_words[]={0x11f8,0x11e0,0x1228,0x122c};
  for(uint32_t address:owner_words){Fixture x;assert(x.Arm());x.memory.words.erase(address);
    assert(!x.Consume()&&!x.ticket.armed);assert(!x.Arm());}
  {Fixture x;assert(x.Arm());assert(!ConsumeSiglusNativeMessageTicket(x.layout,x.inner,x.memory,&x.ticket,nullptr));assert(!x.ticket.armed);}
}

#if defined(_M_IX86)
SiglusNativeMessageSavedRegisters observed{};
uint32_t registers[8]{}, flags_after=0, expected_esp=0, baseline_esp=0, returned_esp=0;
__declspec(align(16)) unsigned char fx_before[512]{},fx_after[512]{};
__declspec(align(16)) uint32_t xmm_seed[4]={1,2,3,4};
uint32_t mxcsr_seed=0x1f80,mxcsr_changed=0x3f80;
void __stdcall Observe(const SiglusNativeMessageSavedRegisters* frame){
  observed=*frame;SetLastError(99);
  __asm { fninit }
  __asm { fld1 }
  __asm { ldmxcsr mxcsr_changed }
  __asm { pxor xmm0,xmm0 }
  __asm { xor eax,eax }
  __asm { xor ecx,ecx }
  __asm { xor edx,edx }
}
__declspec(naked) void Tail(){__asm {
  mov registers[0],eax
  mov registers[4],ecx
  mov registers[8],edx
  mov registers[12],ebx
  mov registers[16],esp
  mov registers[20],ebp
  mov registers[24],esi
  mov registers[28],edi
  pushfd
  pop flags_after
  fxsave fx_after
  ret
}}
void* original=reinterpret_cast<void*>(&Tail);
FUSHI_SIGLUS_NATIVE_MESSAGE_THUNK(Probe,Observe,original)
__declspec(naked) void Run(){__asm {
  pushfd
  pushad
  mov baseline_esp,esp
  sub esp,528
  and esp,-16
  fxsave [esp]
  mov ebx,esp
  push ebx
  fninit
  fldz
  ldmxcsr mxcsr_seed
  movdqu xmm0,xmm_seed
  fxsave fx_before
  lea eax,[esp-4]
  mov expected_esp,eax
  mov eax,101h
  mov ecx,202h
  mov edx,303h
  mov ebx,404h
  mov ebp,606h
  mov esi,707h
  mov edi,808h
  std
  stc
  call Probe
  cld
  pop ebx
  fxrstor [ebx]
  mov esp,baseline_esp
  mov returned_esp,esp
  popad
  popfd
  ret
}}
void TestNaked(){
  SetLastError(77);Run();const DWORD last=GetLastError();
  assert(observed.eax==0x101&&observed.ecx==0x202&&observed.edx==0x303);
  assert(observed.ebx==0x404&&observed.ebp==0x606&&observed.esi==0x707&&observed.edi==0x808);
  assert(SiglusNativeMessageEntryEsp(observed)==expected_esp);
  assert(registers[0]==0x101&&registers[1]==0x202&&registers[2]==0x303&&registers[3]==0x404);
  assert(registers[4]==expected_esp&&registers[5]==0x606&&registers[6]==0x707&&registers[7]==0x808);
  assert((flags_after&0x401)==0x401&&(observed.eflags&0x401)==0x401);
  // Defined FX fields: x87 control/status/tag and register stack, MXCSR, XMM0.
  assert(memcmp(fx_before,fx_after,5)==0);
  assert(memcmp(fx_before+24,fx_after+24,4)==0);
  assert(memcmp(fx_before+32,fx_after+32,128)==0);
  assert(memcmp(fx_before+160,fx_after+160,16)==0);
  assert(last==77&&returned_esp==baseline_esp);
}
#endif
}
int main(){TestTickets();
#if defined(_M_IX86)
  TestNaked();
#endif
  std::puts("siglus_native_message_capture_test passed");
}
