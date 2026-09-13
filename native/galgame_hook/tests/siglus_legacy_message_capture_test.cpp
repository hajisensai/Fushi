#undef NDEBUG
#include <windows.h>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <map>
#include "siglus_legacy_message_capture.h"

namespace {
using namespace fushi_voice_hook;
struct Memory {
  std::map<uint32_t,uint8_t> bytes;
  uint32_t fail=0, change_at=0;
  size_t reads=0, change_on=0, fail_on_read=0;
  void Word(uint32_t address,uint32_t value){
    for(unsigned n=0;n<4;++n)bytes[address+n]=static_cast<uint8_t>(value>>(8*n));
  }
  bool operator()(uint32_t address,void* output,size_t size){
    ++reads;if(change_on==reads)Word(change_at,999);
    if(address==fail||reads==fail_on_read)return false;
    for(size_t n=0;n<size;++n)if(bytes.count(address+static_cast<uint32_t>(n))==0)return false;
    for(size_t n=0;n<size;++n)static_cast<uint8_t*>(output)[n]=bytes[address+static_cast<uint32_t>(n)];
    return true;
  }
};
struct Fixture {
  SiglusLegacyMessageLayout layout{0x1000,0x9000,2048};
  SiglusLegacyMessageSavedRegisters outer{},inner{};
  SiglusLegacyMessageTicket ticket{};
  SiglusLegacyMessageOccurrence result{};
  Memory memory;
  explicit Fixture(uint32_t esp=0x5000,bool heap=false){
    outer.saved_esp=esp-4;outer.ecx=0x2000;
    outer.edi=11;outer.esi=22;outer.ebp=33;outer.ebx=44;
    inner.saved_esp=esp-0x68-4;inner.ecx=esp+4;inner.edi=outer.ecx;
    inner.ebx=3;inner.ebp=4;
    memory.Word(0x1000,0x3000);memory.Word(0x319c,100200312);
    memory.Word(0x31a0,1);memory.bytes[0x31a4]=1;
    memory.Word(0x2120,UINT32_MAX);memory.bytes[0x2124]=0;
    memory.Word(esp,0xa000);memory.Word(esp+0x18,heap?14:6);
    memory.Word(esp+0x1c,heap?15:7);if(heap)memory.Word(esp+8,0x7000);
    memory.Word(esp+0x20,3);memory.Word(esp+0x24,4);memory.bytes[esp+0x28]=1;
    memory.Word(esp-0x68,layout.text_return);
    memory.Word(esp-0x60,outer.edi);memory.Word(esp-0x5c,outer.esi);
    memory.Word(esp-0x58,outer.ebp);memory.Word(esp-0x54,outer.ebx);
  }
  bool Arm(){return ArmSiglusLegacyMessageTicket(layout,outer,memory,&ticket);}
  bool Consume(){return ConsumeSiglusLegacyMessageTicket(layout,inner,memory,&ticket,&result);}
  void Reject(){assert(!Consume()&&!ticket.armed&&result.owner==0);assert(!Consume());}
};
void TestSuccess(){
  for(bool heap:{false,true})for(uint32_t esp:{0x5000u,0x5104u}){
    Fixture x(esp,heap);assert(x.Arm()&&x.Consume());
    assert(x.result.string_object==esp+4&&x.result.owner==0x2000);
    assert(x.result.snapshot.voice_key==100200312&&x.result.snapshot.prior_owner_key==UINT32_MAX);
    assert(x.result.snapshot.text_address==(heap?0x7000:esp+8));
    x.Reject();assert(x.Arm()&&x.Consume());
  }
  for(uint32_t key:{0u,0xffffu,UINT32_MAX}){Fixture x;x.memory.Word(0x319c,key);
    assert(x.Arm()&&x.Consume()&&x.result.snapshot.voice_key==key);}
  {Fixture x;assert(x.Arm());x.memory.Word(0x319c,100200313);
    assert(x.Arm()&&x.Consume()&&x.result.snapshot.voice_key==100200313);}
  // Fresh nested invocation replaces the old ticket; returning to the outer
  // invocation cannot revive it. Two independently owned tickets do not mix.
  {Fixture x;Fixture nested(0x4c00);assert(x.Arm());
    assert(ArmSiglusLegacyMessageTicket(nested.layout,nested.outer,nested.memory,&x.ticket));
    assert(ConsumeSiglusLegacyMessageTicket(nested.layout,nested.inner,nested.memory,&x.ticket,&x.result));
    x.Reject();}
  {Fixture a;Fixture b(0x6000);assert(a.Arm()&&b.Arm());assert(b.Consume()&&a.Consume());}
}
void TestRejections(){
  for(int i=0;i<26;++i){Fixture x;assert(x.Arm());switch(i){
    case 0:x.inner.edi++;break;case 1:x.inner.ecx++;break;
    case 2:x.inner.saved_esp+=4;break;case 3:x.inner.saved_esp-=4;break;
    case 4:x.inner.ebx++;break;case 5:x.inner.ebp++;break;case 6:x.inner.esi=1;break;
    case 7:x.memory.Word(0x4f98,0x9004);break;case 8:x.memory.Word(0x5000,0xa004);break;
    case 9:x.memory.Word(0x4fa0,1);break;case 10:x.memory.Word(0x4fa4,1);break;
    case 11:x.memory.Word(0x4fa8,1);break;case 12:x.memory.Word(0x4fac,1);break;
    case 13:x.memory.Word(0x1000,0x4000);break;case 14:x.memory.Word(0x319c,UINT32_MAX);break;
    case 15:x.memory.Word(0x31a0,2);break;case 16:x.memory.bytes[0x31a4]=0;break;
    case 17:x.memory.Word(0x2120,100200312);break;case 18:x.memory.bytes[0x2124]=1;break;
    case 19:x.memory.Word(0x5018,5);break;case 20:x.memory.Word(0x501c,8);break;
    case 21:x.memory.Word(0x5020,9);break;case 22:x.memory.Word(0x5024,9);break;
    case 23:x.memory.bytes[0x5028]=0;break;case 24:x.layout.script_slot+=4;break;
    case 25:x.layout.text_return+=4;break;
  }x.Reject();}
  for(int i=0;i<12;++i){Fixture x;assert(x.Arm());switch(i){
    case 0:x.outer.saved_esp=UINT32_MAX;break;
    case 1:x.outer.saved_esp=UINT32_MAX-8;break;
    case 2:x.outer.saved_esp=0x30;break;
    case 3:x.outer.ecx=UINT32_MAX-4;break;
    case 4:x.outer.ecx=0;break;
    case 5:x.memory.Word(0x1000,UINT32_MAX-4);break;
    case 6:x.memory.Word(0x5018,2049);break;
    case 7:x.memory.Word(0x501c,6);break;
    case 8:x.memory.Word(0x5018,0);break;
    case 9:x.layout.script_slot=0;break;
    case 10:x.layout.text_return=0;break;
    case 11:x.layout.max_text_units=0;break;
  }assert(!x.Arm()&&!x.ticket.armed);x.Reject();}
  {Fixture x(0x5000,true);x.memory.Word(0x5008,UINT32_MAX-3);assert(!x.Arm());}
  {Fixture x(0x5000,true);x.memory.Word(0x5008,UINT32_MAX-31);
    assert(x.Arm()&&x.Consume());} // The last WCHAR terminator fits exactly.
  {Fixture x(0x5000,true);assert(x.Arm());x.memory.Word(0x5008,0x7002);x.Reject();}
  {Fixture x;assert(x.Arm());x.ticket={};x.Reject();} // explicit session reset
  {Fixture x;assert(x.Arm());assert(!ConsumeSiglusLegacyMessageTicket(x.layout,x.inner,x.memory,&x.ticket,nullptr));assert(!x.ticket.armed);}
}
void TestReadFailuresAndDrift(){
  for(bool heap:{false,true}) {
    Fixture count(0x5000,heap);assert(count.Arm());const size_t arm_reads=count.memory.reads;
    count.memory.reads=0;assert(count.Consume());const size_t consume_reads=count.memory.reads;
    for(size_t n=1;n<=arm_reads;++n){Fixture x(0x5000,heap);assert(x.Arm());
      x.memory.reads=0;x.memory.fail_on_read=n;assert(!x.Arm()&&!x.ticket.armed);x.Reject();}
    for(size_t n=1;n<=consume_reads;++n){Fixture x(0x5000,heap);assert(x.Arm());
      x.memory.reads=0;x.memory.fail_on_read=n;x.Reject();}
  }
  // Every scalar read site is faultable, including second-pass coherence.
  const uint32_t addresses[]={0x1000,0x319c,0x31a0,0x31a4,0x2120,0x2124,
      0x5018,0x501c,0x5020,0x5024,0x5028,0x5000,0x4f98,0x4fa0,0x4fa4,0x4fa8,0x4fac};
  for(uint32_t address:addresses){Fixture x;assert(x.Arm());x.memory.fail=address;x.Reject();}
  {Fixture x;x.memory.change_at=0x319c;x.memory.change_on=14;assert(!x.Arm());}
  {Fixture x;assert(x.Arm());x.memory.reads=0;x.memory.change_at=0x319c;
    x.memory.change_on=19;x.Reject();}
  {Fixture x(0x5000,true);x.memory.fail=0x5008;assert(!x.Arm());}
}
}
int main(){TestSuccess();TestRejections();TestReadFailuresAndDrift();
  std::puts("siglus_legacy_message_capture_test passed");}
