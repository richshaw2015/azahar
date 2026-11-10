#include "tests/core/arm/arm_test_common.h"
namespace ArmTests {
TestEnvironment::TestEnvironment(bool)
    : memory(std::make_unique<Memory::MemorySystem>(Core::System::GetInstance())),
      page_table(std::make_shared<Memory::PageTable>()),
      backing(std::make_shared<BufferMem>(0x20000)) {
    page_table->Clear();
    memory->MapMemoryRegion(*page_table, 0, static_cast<u32>(backing->GetSize()), MemoryRef(backing));
    memory->SetCurrentPageTable(page_table);
}
TestEnvironment::~TestEnvironment() { memory->UnmapRegion(*page_table, 0, static_cast<u32>(backing->GetSize())); }
void TestEnvironment::SetMemory8(VAddr a, u8 v) { memory->Write8(a, v); }
void TestEnvironment::SetMemory16(VAddr a, u16 v) { memory->Write16(a, v); }
void TestEnvironment::SetMemory32(VAddr a, u32 v) { memory->Write32(a, v); }
void TestEnvironment::SetMemory64(VAddr a, u64 v) { memory->Write64(a, v); }
}
