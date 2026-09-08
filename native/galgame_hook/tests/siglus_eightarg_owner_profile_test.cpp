#undef NDEBUG
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include "siglus_eightarg_owner_profile.h"

// Reuse the complete synthetic input PE builder. Its existing test body is
// compiled under a different name, but this test invokes the actual resolver.
namespace input_fixture {
#define main UnusedInputTestMain
#include "siglus_eightarg_input_viewport_test.cpp"
#undef main
#undef Check
}
namespace {
using namespace fushi_voice_hook;
namespace o = siglus_eightarg_owner_profile;
namespace g = siglus_eight_arg_glyph;
namespace in = siglus_eightarg_input_viewport;
size_t checks = 0;
struct Piece { uintptr_t at; exact_lookup::MaskedPattern pattern; };
struct Fixture : input_fixture::Fixture {
  in::Sites input{};
  SiglusEightArgGlyphSites glyph{};
  uintptr_t glyph_entry=0x9000, wrapper=0xa000, scenario=0xb000, message=0xc000;
  uintptr_t render=0xd000, font=0xe000, writer=0xf000, transform=0xf100;
  uintptr_t dispatch=0x10000, selector=0x10100, render_group=0x10200;
  uintptr_t evaluator, vm, normal, group, element, index, identity, normal_render;
  std::vector<Piece> owner_pieces;
  void Rel(uintptr_t at, uintptr_t target) {
    assert(at<UINT32_MAX&&target<UINT32_MAX);bytes[at]=0xe8;
    input_fixture::Fixture::Rel(at+1,static_cast<uint32_t>(target));
  }
  void Abs(uintptr_t at, uintptr_t target) {
    assert(target<UINT32_MAX);input_fixture::Fixture::Abs(at,static_cast<uint32_t>(target));
  }
  void WordAt(uintptr_t at, uint32_t value) {std::memcpy(bytes.data()+at,&value,4);}
  explicit Fixture(bool moved=false, uint32_t base=0x400000)
      : input_fixture::Fixture(base), evaluator(moved?0x18023:0x11000),
        vm(moved?0x1a025:0x12000), normal(vm+0x2d1),
        group(moved?0x16021:0x13000), element(moved?0x15011:0x14000),
        index(moved?0x13029:0x15000), identity(moved?0x14057:0x16000),
        normal_render(moved?0x17031:0x17000) {
    assert(in::Resolve(image,imports,&input));
    bytes.resize(0x24000,0xcc);image.base=bytes.data();image.size=bytes.size();
    for(size_t n=0;n<3;++n)image.sections[n].bytes=bytes.data()+image.sections[n].rva;
    image.section_count=5;
    image.sections[3]={bytes.data()+0x9000,0x16000,0x9000,IMAGE_SCN_MEM_READ|IMAGE_SCN_MEM_EXECUTE};
    image.sections[4]={bytes.data()+0x23000,0x1000,0x23000,IMAGE_SCN_MEM_READ};
    assert(in::Resolve(image,imports,&input));
    const Piece glyph_pieces[]={
      {glyph_entry,g::kGlyphEntry.pattern()},{glyph_entry+g::kGlyphFontOffset,g::kGlyphFont.pattern()},
      {glyph_entry+g::kGlyphCoordinatesOffset,g::kGlyphCoordinates.pattern()},
      {glyph_entry+g::kGlyphReturnOffset,g::kGlyphReturn.pattern()},
      {wrapper,g::kWrapper.pattern()},{scenario,g::kScenarioEntry.pattern()},
      {scenario+g::kScenarioStringOffset,g::kScenarioString.pattern()},
      {scenario+g::kScenarioFieldsOffset,g::kScenarioFields.pattern()},
      {scenario+g::kScenarioAppendOffset,g::kScenarioAppend.pattern()},
      {scenario+g::kScenarioReturnOffset,g::kScenarioReturn.pattern()},
      {message,g::kMessage.pattern()},{render,g::kRenderEntry.pattern()},
      {render+g::kRenderFirstOffset,g::kRenderFirst.pattern()},
      {render+g::kRenderSecondOffset,g::kRenderSecond.pattern()},
      {render+g::kRenderVisibleOffset,g::kRenderVisible.pattern()},
      {render+g::kRenderReturnOffset,g::kRenderReturn.pattern()},
      {font,g::kFontEntry.pattern()},{writer,g::kCoordinateWriter.pattern()},
      {transform,g::kTransformEntry.pattern()},{dispatch,g::kMessageDispatch.pattern()},
      {selector,g::kOwnerSelector.pattern()},{render_group,g::kRenderGroup.pattern()}};
    for(const auto& p:glyph_pieces)Put(p.at,p.pattern);
    for(auto at:{glyph_entry+g::kGlyphCoordinatesOffset+6,
        scenario+g::kScenarioAppendOffset+13,scenario+g::kScenarioReturnOffset+19,
        message+106,message+111,message+119,message+128,message+267,
        render+24,render+g::kRenderFirstOffset+184,font+81,
        dispatch+16,dispatch+43,dispatch+86,render_group+72,
        render+g::kRenderReturnOffset+10}) Rel(at,0x1e000);
    Rel(wrapper+g::kWrapperGlyphCall,glyph_entry);Rel(message+g::kMessageScenarioCall,scenario);
    Rel(render+g::kRenderFirstOffset+g::kRenderFirstCall,wrapper);
    Rel(render+g::kRenderSecondOffset+g::kRenderSecondCall,wrapper);
    Rel(glyph_entry+g::kGlyphFontOffset+50,font);
    Rel(glyph_entry+g::kGlyphCoordinatesOffset+105,transform);
    Rel(glyph_entry+g::kGlyphCoordinatesOffset+126,writer);
    Rel(dispatch+55,selector);Rel(dispatch+68,message);Rel(render_group+142,render);
    Rel(selector+20,evaluator);
    for(auto at:{glyph_entry+6,scenario+6,message+6,font+6})Abs(at,0x1e000);
    for(auto at:{glyph_entry+27,scenario+24,message+21,render+10,font+24})Abs(at,0x6014);
    for(auto at:{glyph_entry+g::kGlyphFontOffset+1,
        glyph_entry+g::kGlyphCoordinatesOffset+12,wrapper+65})Abs(at,input.config_slot);
    Abs(message+90,input.manager_slot);Abs(selector+2,input.manager_slot);
    owner_pieces={{evaluator,o::kEvaluator.pattern()},{vm,o::kVmEntry.pattern()},
      {vm+0x98,o::kVmDispatch.pattern()},{normal,o::kNormalCase.pattern()},
      {group,o::kGroupSelection.pattern()},{element,o::kElementSelection.pattern()},
      {index,o::kIndexSelection.pattern()},{index+0x1d7,o::kIndexReturn.pattern()},
      {identity,o::kOwnerIdentity.pattern()},{normal_render,o::kNormalRender.pattern()}};
    for(const auto& p:owner_pieces)Put(p.at,p.pattern);
    Rel(evaluator+46,vm);Rel(normal+25,group);Rel(group+131,element);
    Rel(element+102,index);Rel(element+122,identity);
    Rel(normal_render+48,render_group);Rel(normal_render+83,render_group);
    for(auto at:{group+99,normal_render+6,index+0x1d7+18})Rel(at,0x1e000);
    for(auto at:{vm+27,vm+44,group+24,group+38,element+21,index+24,identity+24})Abs(at,0x6014);
    for(auto at:{vm+9,group+9,element+6,index+6,identity+6})Abs(at,0x1e000);
    Abs(normal+9,input.scene_slot);Abs(vm+0x98+17,0x23000);
    Abs(0x23000+0x26*4,normal);
    assert(g::Resolve(image,&glyph));
  }
  void Pass(){o::Sites sites;assert(o::Resolve(image,glyph,input,&sites));++checks;
    assert(sites.scene_slot==input.scene_slot&&sites.engine_owner_slot==input.owner_slot);
    assert(sites.normal_render_return_rva==normal_render+53&&sites.normal_case_rva==normal);
    assert(sites.index_selection_rva==index&&sites.render_group_entry_rva==render_group);}
  void Reject(){o::Sites sites;sites.scene_slot=42;
    assert(!o::Resolve(image,glyph,input,&sites));assert(sites.scene_slot==0&&sites.normal_case_rva==0);++checks;}
};
}
int main(){
  Fixture{}.Pass();Fixture{true,0x240000}.Pass();
  {Fixture f;for(const auto& p:f.owner_pieces)for(size_t n=0;n<p.pattern.size;++n){
    if(!p.pattern.mask[n])continue;f.bytes[p.at+n]^=1;f.Reject();f.bytes[p.at+n]^=1;
  }f.Pass();}
  // Every independently scanned role is globally unique, including the VM
  // normal branch; a second partial family cannot complete the first family.
  for(unsigned n=0;n<8;++n){Fixture f;const Piece candidates[]={
      {f.evaluator,o::kEvaluator.pattern()},{f.vm,o::kVmEntry.pattern()},
      {f.normal,o::kNormalCase.pattern()},{f.group,o::kGroupSelection.pattern()},
      {f.element,o::kElementSelection.pattern()},{f.index,o::kIndexSelection.pattern()},
      {f.identity,o::kOwnerIdentity.pattern()},{f.normal_render,o::kNormalRender.pattern()}};
    f.Put(0x1c000,candidates[n].pattern);f.Reject();}
  for(unsigned n=0;n<8;++n){Fixture f;const uintptr_t edges[]={f.selector+20,
      f.evaluator+46,f.normal+25,f.group+131,f.element+102,f.element+122,
      f.normal_render+48,f.normal_render+83};f.Rel(edges[n],0x1e100);f.Reject();}
  for(unsigned n=0;n<26;++n){Fixture f;switch(n){
    case 0:f.Abs(f.normal+9,f.input.scene_slot+4);break;
    case 1:f.input.scene_slot=f.input.manager_slot;break;
    case 2:f.input.owner_slot+=4;break;
    case 3:f.input.root_slot+=4;break;
    case 4:f.input.config_slot+=4;break;
    case 5:f.input.manager_slot+=4;break;
    case 6:f.glyph.message_caller_return_rva++;break;
    case 7:f.glyph.owner_selector_rva++;break;
    case 8:f.glyph.render_group_entry_rva++;break;
    case 9:f.Abs(0x23000+0x26*4,f.normal+1);break;
    case 10:f.Abs(f.vm+0x98+17,0x23f00);break;
    case 11:f.image.sections[4].characteristics|=IMAGE_SCN_MEM_WRITE;break;
    case 12:f.image.sections[4].characteristics=0;break;
    case 13:f.Abs(f.vm+0x98+17,0x6400);break;
    case 14:f.Abs(f.vm+27,0x6018);break;
    case 15:f.Abs(f.vm+9,0x6014);break;
    case 16:f.Rel(f.index+0x1d7+18,0x6014);break;
    case 17:f.image.machine=IMAGE_FILE_MACHINE_AMD64;break;
    case 18:f.image.pointer_bits=64;break;
    case 19:f.image.base=nullptr;break;
    case 20:f.WordAt(f.normal+21,0xe68);break; // auxiliary group.
    case 21:f.WordAt(f.normal_render+29,0x48d10);break; // alternate root displacement.
    case 22:f.Abs(0x23000+0x26*4,0x23000);break;
    case 23:f.input.scene_slot=0;break;
    case 24:f.bytes[f.evaluator]=0xe9;break;
    case 25:f.bytes[f.index]=0xe9;break;
  }f.Reject();}
  {Fixture f;const uintptr_t cookie_operands[]={f.vm+27,f.vm+44,f.group+24,
      f.group+38,f.element+21,f.index+24,f.identity+24};
    for(auto at:cookie_operands){f.Abs(at,0x6018);f.Reject();f.Abs(at,0x6014);}f.Pass();}
  {Fixture f;for(auto at:{f.vm+9,f.group+9,f.element+6,f.index+6,f.identity+6}){
      f.Abs(at,0x6014);f.Reject();f.Abs(at,0x1e000);}f.Pass();}
  {Fixture f;for(auto at:{f.group+99,f.normal_render+6,f.index+0x1d7+18}){
      f.Rel(at,0x6014);f.Reject();f.Rel(at,0x1e000);}f.Pass();}
  // A later unrelated alias cannot overwrite a previously proved root role.
  {Fixture f;f.Abs(0x1895+28,f.input.scene_slot);f.Reject();}
  {Fixture f;f.Abs(0x400+10,f.input.owner_slot);f.Reject();}
  // An unrelated VM table case may reference other code; it is not an admitted
  // normal-owner branch, and this parser does not evaluate any expression.
  {Fixture f;f.Abs(0x23000+0x27*4,0x1e100);f.Pass();}
  {Fixture f;assert(!o::Resolve(f.image,f.glyph,f.input,nullptr));++checks;}
  std::printf("Siglus normal-owner profile: %zu checks passed\n",checks);
  return 0;
}
