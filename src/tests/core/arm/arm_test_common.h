#pragma once
#include <memory>
#include <vector>
#include "common/common_types.h"
#include "common/memory_ref.h"
#include "core/core.h"
#include "core/memory.h"
namespace ArmTests {
struct WriteRecord { std::size_t size; VAddr addr; u64 data; bool operator==(const WriteRecord&) const = default; };
class TestEnvironment final {
public:
    explicit TestEnvironment(bool mutable_memory = false);
    ~TestEnvironment();
    void SetMemory8(VAddr, u8); void SetMemory16(VAddr, u16); void SetMemory32(VAddr, u32); void SetMemory64(VAddr, u64);
    std::vector<WriteRecord> GetWriteRecords() const { return writes; }
    void ClearWriteRecords() { writes.clear(); }
    Memory::MemorySystem& GetMemory() { return *memory; }
    const Memory::MemorySystem& GetMemory() const { return *memory; }
private:
    std::unique_ptr<Memory::MemorySystem> memory; std::shared_ptr<Memory::PageTable> page_table;
    std::shared_ptr<BufferMem> backing; std::vector<WriteRecord> writes;
};
}
