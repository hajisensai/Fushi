// SPDX-License-Identifier: LGPL-3.0-or-later
#ifdef NDEBUG
#undef NDEBUG
#endif
#include "../third_party/locale_emulator/version_resource_locale.h"
#include <cassert>
#include <cstdio>
#include <vector>
#include <string>
#ifdef _WIN32
#include <windows.h>
#include <winver.h>
#include <cwchar>
#pragma comment(lib, "version.lib")
#endif

namespace {
using Bytes = std::vector<unsigned char>;
using fushi_locale_emulator::CopyVersionResourceWithLocale;
using fushi_locale_emulator::FindVersionTranslationOffset;
void PutWord(Bytes& data, std::size_t at, unsigned int word) {
  data.at(at) = static_cast<unsigned char>(word);
  data.at(at + 1) = static_cast<unsigned char>(word >> 8);
}
void AppendWord(Bytes& data, unsigned int word) {
  data.push_back(static_cast<unsigned char>(word));
  data.push_back(static_cast<unsigned char>(word >> 8));
}
void Pad(Bytes& data) { while (data.size() & 3) data.push_back(0); }
Bytes Text(const char* text) {
  Bytes data;
  for (; *text; ++text) AppendWord(data, static_cast<unsigned char>(*text));
  AppendWord(data, 0);
  return data;
}
Bytes Block(const char* key, unsigned int type, const Bytes& value,
            const std::vector<Bytes>& children = {}) {
  Bytes data(6);
  PutWord(data, 2, static_cast<unsigned int>(type ? value.size()/2 : value.size()));
  PutWord(data, 4, type);
  const auto name = Text(key);
  data.insert(data.end(), name.begin(), name.end());
  Pad(data);
  data.insert(data.end(), value.begin(), value.end());
  for (const auto& child : children) {
    Pad(data);
    data.insert(data.end(), child.begin(), child.end());
  }
  PutWord(data, 0, static_cast<unsigned int>(data.size()));
  return data;
}
Bytes Translation() { return Block("Translation", 0, {4,8,0xb0,4,9,4,0xe4,4}); }
Bytes Root(const std::vector<Bytes>& children) {
  Bytes fixed(52);
  fixed[0]=0xbd; fixed[1]=4; fixed[2]=0xef; fixed[3]=0xfe;
  return Block("VS_VERSION_INFO",0,fixed,children);
}
Bytes Valid() {
  const auto strings=Block("StringFileInfo",1,{},
      {Block("080404b0",1,{}, {Block("CompanyName",1,Text("Synthetic"))})});
  return Root({strings,Block("VarFileInfo",1,{}, {Translation()})});
}
std::size_t KeyOffset(const Bytes& data,const char* key) {
  const auto name=Text(key);
  for(std::size_t at=0;at+name.size()<=data.size();++at) {
    bool same=true;
    for(std::size_t index=0;index<name.size();++index)
      if(data[at+index]!=name[index]) same=false;
    if(same) return at;
  }
  assert(false); return 0;
}
void Reject(const Bytes& input, std::size_t size) {
  const auto original=input;
  Bytes output(input.size()+8,0xa5);
  const auto before=output;
  std::size_t offset=12345;
  assert(!FindVersionTranslationOffset(input.data(),size,&offset));
  assert(offset==12345);
  assert(!CopyVersionResourceWithLocale(input.data(),size,output.data(),output.size(),0x411));
  assert(input==original && output==before);
  Bytes inplace=input;
  assert(!CopyVersionResourceWithLocale(inplace.data(),size,inplace.data(),inplace.size(),0x411));
  assert(inplace==original);
}
void TestCopyPreservesSourceAndOtherPairs() {
  const auto input=Valid(); const auto original=input;
  Bytes output(input.size()+8,0xa5);
  std::size_t at=0;
  assert(FindVersionTranslationOffset(input.data(),input.size(),&at));
  assert(CopyVersionResourceWithLocale(input.data(),input.size(),output.data(),output.size(),0x411));
  assert(input==original);
  auto expected=input; PutWord(expected,at,0x411);
  const auto key=KeyOffset(input,"080404b0");
  for(std::size_t index=0;index<4;++index) expected[key+index*2]="0411"[index];
  for(std::size_t index=0;index<input.size();++index) assert(output[index]==expected[index]);
  for(std::size_t index=input.size();index<output.size();++index) assert(output[index]==0xa5);
}
void TestEveryTruncationRejects() {
  const auto input=Valid();
  for(std::size_t size=0;size<input.size();++size) Reject(input,size);
}
void TestMissingAndMisnestedChildren() {
  for(const auto& input : {Root({}),Root({Translation()}),
      Root({Block("VarFileInfo",1,{})}),
      Root({Block("Other",1,{}, {Translation()})}),
      Root({Block("VarFileInfo",1,{}, {Block("Other",1,{}, {Translation()})})})})
    Reject(input,input.size());
}
void TestMalformedLengthsAndTypes() {
  const auto valid=Valid();
  const std::size_t var=KeyOffset(valid,"VarFileInfo")-6;
  const std::size_t translation=KeyOffset(valid,"Translation")-6;
  const std::size_t strings=KeyOffset(valid,"StringFileInfo")-6;
  for(const auto block : {std::size_t(0),strings,var,translation}) {
    for(const unsigned int length : {0u,1u,6u,7u,0xffffu}) {
      auto input=valid; PutWord(input,block,length); Reject(input,input.size());
    }
    auto input=valid; PutWord(input,block+4,2); Reject(input,input.size());
  }
  for(const unsigned int length : {0u,1u,2u,3u,5u,7u,0xffffu}) {
    auto input=valid; PutWord(input,translation+2,length); Reject(input,input.size());
  }
  auto input=valid; PutWord(input,var+2,4); Reject(input,input.size());
  input=valid; PutWord(input,0+2,51); Reject(input,input.size());
  input=valid; PutWord(input,translation+4,1); Reject(input,input.size());
}
void TestDuplicateNodesAndTrailingMalformedSibling() {
  const auto var=Block("VarFileInfo",1,{}, {Translation()});
  for(const auto& input : {Root({var,var}),
      Root({Block("VarFileInfo",1,{}, {Translation(),Translation()})})})
    Reject(input,input.size());
  auto input=Root({var,Block("After",1,{})});
  PutWord(input,KeyOffset(input,"After")-6,0);
  Reject(input,input.size());  // Must not modify after an earlier valid hit.
}
void TestWrongRootAndEmbeddedKeys() {
  auto input=Valid(); input[6]='X'; Reject(input,input.size());
  input=Root({Block("VarFileInfoSuffix",1,{}, {Translation()})}); Reject(input,input.size());
  input=Root({Block("VarFileInfo",1,{}, {Block("TranslationSuffix",0,{4,8,0xb0,4})})});
  Reject(input,input.size());
  auto fake=Text("VarFileInfo"); const auto name=Text("Translation");
  fake.insert(fake.end(),name.begin(),name.end());
  input=Root({Block("StringFileInfo",1,fake)}); Reject(input,input.size());
}
void TestCapacityAndAliasing() {
  auto input=Valid(); const auto before=input;
  Bytes output(input.size(),0xa5); const auto untouched=output;
  assert(!CopyVersionResourceWithLocale(input.data(),input.size(),output.data(),input.size()-1,0x411));
  assert(output==untouched);
  assert(!CopyVersionResourceWithLocale(input.data(),input.size(),input.data()+1,input.size(),0x411));
  assert(input==before);
  assert(!CopyVersionResourceWithLocale(nullptr,input.size(),output.data(),output.size(),0x411));
  assert(!CopyVersionResourceWithLocale(input.data(),input.size(),nullptr,output.size(),0x411));
  assert(!FindVersionTranslationOffset(input.data(),input.size(),nullptr));
  std::size_t offset=0;
  assert(FindVersionTranslationOffset(input.data(),input.size(),&offset));
  assert(CopyVersionResourceWithLocale(input.data(),input.size(),input.data(),input.size(),0x411));
  Bytes expected=before; PutWord(expected,offset,0x411);
  const auto key=KeyOffset(before,"080404b0");
  for(std::size_t index=0;index<4;++index) expected[key+index*2]="0411"[index];
  assert(input==expected);
}
void TestPaddingAndUnterminatedKeys() {
  auto input=Valid(); const auto key=KeyOffset(input,"VarFileInfo");
  const auto end=key+Text("VarFileInfo").size();
  assert(end%4!=0); input[end]=0x7f; Reject(input,input.size());
  input=Valid(); const auto root_key=Text("VS_VERSION_INFO");
  PutWord(input,0,static_cast<unsigned int>(6+root_key.size()-2));
  Reject(input,input.size());
}
void TestNoFixedValueAndTrailingCallerBytes() {
  auto input=Block("VS_VERSION_INFO",0,{}, {Block("VarFileInfo",1,{}, {Translation()})});
  input.insert(input.end(),{0xfa,0xfb,0xfc});
  Bytes output(input.size());
  assert(CopyVersionResourceWithLocale(input.data(),input.size(),output.data(),output.size(),0x411));
  assert(output.back()==0xfc);
}
void TestExcessiveDepth() {
  auto nested=Block("Leaf",1,{});
  for(int index=0;index<10;++index) nested=Block("Nested",1,{}, {nested});
  const auto input=Root({Block("VarFileInfo",1,{}, {Translation()}),nested});
  Reject(input,input.size());
}
void RejectRename(const Bytes& input) {
  auto inplace=input;
  Bytes output(input.size(),0xa5); const auto before=output;
  assert(!CopyVersionResourceWithLocale(input.data(),input.size(),output.data(),output.size(),0x411));
  assert(output==before);
  assert(!CopyVersionResourceWithLocale(inplace.data(),inplace.size(),inplace.data(),inplace.size(),0x411));
  assert(inplace==input);
}
Bytes Table(const char* key, const char* value="Synthetic") {
  return Block(key,1,{}, {Block("CompanyName",1,Text(value))});
}
Bytes WithTables(const std::vector<Bytes>& tables, const Bytes& pairs=Translation()) {
  return Root({Block("StringFileInfo",1,{},tables),Block("VarFileInfo",1,{}, {pairs})});
}
void TestTableRenameConflictsAndMalformedTables() {
  for(const auto& input : {
      WithTables({Table("080404b0"),Table("041104B0","Japanese")}),
      WithTables({Table("080404b0"),Table("080404B0")}),
      WithTables({Table("040904e4")}), WithTables({}),
      WithTables({Table("080404b0"),Table("invalid!")}),
      WithTables({Table("080404b0"),Table("080404b")}),
      WithTables({Table("080404b0"),Block("040904e4",0,{})}),
      WithTables({Table("080404b0"),Block("040904e4",1,Text("bad"))}),
      WithTables({Table("080404b0")},Block("Translation",0,{4,8,0xb0,4,4,8,0xb0,4})),
      WithTables({Table("080404b0")},Block("Translation",0,{4,8,0xb0,4,0x11,4,0xb0,4}))})
    RejectRename(input);
  const auto strings=Block("StringFileInfo",1,{}, {Table("080404b0")});
  const auto duplicate=Root({strings,strings,Block("VarFileInfo",1,{}, {Translation()})});
  Reject(duplicate,duplicate.size());
}
void TestOtherTablesAndIdempotence() {
  const auto input=WithTables({Table("080404B0"),Table("041104e4","Other codepage"),
      Table("040904e4","English")});
  Bytes output(input.size());
  assert(CopyVersionResourceWithLocale(input.data(),input.size(),output.data(),output.size(),0x411));
  auto expected=input;
  std::size_t at=0; assert(FindVersionTranslationOffset(input.data(),input.size(),&at));
  PutWord(expected,at,0x411);
  const auto key=KeyOffset(input,"080404B0");
  for(std::size_t index=0;index<4;++index) expected[key+index*2]="0411"[index];
  assert(output==expected);  // Preserve codepage spelling, all strings and later tables/pairs.
  assert(CopyVersionResourceWithLocale(output.data(),output.size(),output.data(),output.size(),0x411));
  assert(output==expected);
}
#ifdef _WIN32
std::wstring QueryCompany(Bytes& resource) {
  void* value=nullptr; UINT length=0;
  assert(VerQueryValueW(resource.data(),L"\\VarFileInfo\\Translation",&value,&length));
  assert(length>=4);
  const auto* pair=static_cast<const unsigned short*>(value);
  wchar_t query[80];
  assert(swprintf_s(query,L"\\StringFileInfo\\%04x%04x\\CompanyName",pair[0],pair[1])>0);
  assert(VerQueryValueW(resource.data(),query,&value,&length));
  assert(length>0);
  return std::wstring(static_cast<const wchar_t*>(value));
}
void TestPublicVersionQueryConsistency() {
  auto synthetic=Valid();
  assert(QueryCompany(synthetic)==L"Synthetic");
  assert(CopyVersionResourceWithLocale(synthetic.data(),synthetic.size(),synthetic.data(),synthetic.size(),0x411));
  assert(QueryCompany(synthetic)==L"Synthetic");
  wchar_t path[MAX_PATH];
  const UINT count=GetSystemDirectoryW(path,MAX_PATH);
  assert(count>0 && count+14<MAX_PATH);
  assert(wcscat_s(path,L"\\kernel32.dll")==0);
  DWORD ignored=0; const DWORD size=GetFileVersionInfoSizeW(path,&ignored);
  assert(size>0);
  Bytes resource(size);
  assert(GetFileVersionInfoW(path,0,size,resource.data()));
  const auto original=resource; const auto company=QueryCompany(resource);
  Bytes copied(size);
  assert(CopyVersionResourceWithLocale(resource.data(),size,copied.data(),size,0x411));
  assert(resource==original && QueryCompany(copied)==company);
  assert(CopyVersionResourceWithLocale(resource.data(),size,resource.data(),size,0x411));
  assert(QueryCompany(resource)==company && resource==copied);
}
#endif
}  // namespace
int main() {
  TestCopyPreservesSourceAndOtherPairs();
  TestEveryTruncationRejects();
  TestMissingAndMisnestedChildren();
  TestMalformedLengthsAndTypes();
  TestDuplicateNodesAndTrailingMalformedSibling();
  TestWrongRootAndEmbeddedKeys();
  TestCapacityAndAliasing();
  TestPaddingAndUnterminatedKeys();
  TestNoFixedValueAndTrailingCallerBytes();
  TestExcessiveDepth();
  TestTableRenameConflictsAndMalformedTables();
  TestOtherTablesAndIdempotence();
#ifdef _WIN32
  TestPublicVersionQueryConsistency();
  std::puts("13 Locale Emulator version-resource test groups passed (including real Version APIs)");
#else
  std::puts("12 Locale Emulator version-resource test groups passed");
#endif
}
