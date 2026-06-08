# Timing Accesses vs. Functional Accesses

## Scope

This note explains the fundamental separation in SimX between **timing-aware** accesses (through caches via SimPorts) and **functional** accesses (through direct memory read/write). We clarify whether data is sent with cache responses and how data flows through the system.

---

## The Two-Channel Architecture

SimX uses a **dual-path memory access model**:

```
                     Core (ICache/DCache ports)
                              ↓
         ┌────────────────────┴────────────────────┐
         │                                          │
    TIMING PATH                              FUNCTIONAL PATH
    (with latency)                           (immediate)
         │                                          │
    ICache/DCache                           Emulator
    (SimPorts)                              (mmu_.read/write)
         │                                          │
    Cache simulator                        Memory unit
    (pipeline model)                       (data values)
         │                                          │
    Response flows                        Data flows back
    back via ports                        to emulator
    (tagged)                              (via output parameter)
         ↓                                          ↓
    Timing delay                          Immediate
```

---

## Functional Accesses: The Bypass Channel

### When Functional Accesses Occur

The **Emulator** performs direct functional accesses to memory during instruction execution in [sim/simx/emulator.cpp L310-340](../sim/simx/emulator.cpp#L310-L340):

```cpp
void Emulator::dcache_read(void *data, uint64_t addr, uint32_t size) {
  auto type = get_addr_type(addr);
  if (type == AddrType::Shared) {
    core_->local_mem()->read(data, addr, size);  // Local memory access
  } else {
    mmu_.read(data, addr, size, ACCESS_TYPE::LOAD);  // Memory unit access
  }
}

void Emulator::dcache_write(const void* data, uint64_t addr, uint32_t size) {
  auto type = get_addr_type(addr);
  if (type == AddrType::Shared) {
    core_->local_mem()->write(data, addr, size);  // Local memory write
  } else {
    mmu_.write(data, addr, size, ACCESS_TYPE::STORE);  // Memory unit write
  }
}
```

### Key Characteristics

- **Direct function call:** `mmu_.read(data, addr, size, ...)` from [sim/common/mem.h L207-208](../sim/common/mem.h#L207-L208)
- **Synchronous:** Returns immediately with data in the `data` buffer
- **No timing:** No SimPort delay, no cache pipeline simulation
- **Purpose:** Retrieve actual data values for functional execution

### Data Flow

Functional reads/writes operate on **output parameters**:

```cpp
// Example: Load instruction execution
uint32_t value = 0;
emulator_.dcache_read(&value, address, sizeof(uint32_t));
// After call, 'value' contains the actual data from memory
// No timing delay applied
```

The data is placed directly into memory (for writes) or returned in the provided buffer (for reads).

---

## Timing Accesses: The Cache Simulation Channel

### When Timing Accesses Occur

The **Core pipeline** issues timing-aware memory requests through SimPorts during fetch/decode/LSU stages in [sim/simx/core.cpp L264](../sim/simx/core.cpp#L264) and [sim/simx/func_unit.cpp L320](../sim/simx/func_unit.cpp#L320):

```cpp
// Fetch stage issues ICache request
icache_req_ports.at(0).push(mem_req, 2);  // 2-cycle port delay

// LSU issues DCache request
core_->lmem_switch_.at(block_idx)->ReqIn.push(lsu_req);  // 1-cycle default
```

### What Responses Contain

**Critical finding:** Cache responses (MemRsp) contain **only metadata, not data**:

From [sim/simx/types.h L999-1015](../sim/simx/types.h#L999):

```cpp
struct MemRsp {
  uint64_t tag;      // Tag to match response to request
  uint32_t cid;      // Core ID
  uint64_t uuid;     // Instruction UUID
  // NO DATA FIELD
};
```

**Responses do NOT carry actual data values.**

### How Data Flows Back

Data is **not** sent through cache responses. Instead, when the Core receives a response:

1. **Response indicates cache hit/miss occurred**
2. **Tag identifies which instruction caused the miss**
3. **Actual data is retrieved separately** via functional accessor

Example from fetch path [sim/simx/core.cpp L243-250](../sim/simx/core.cpp#L243):

```cpp
void Core::fetch() {
  // Handle icache response
  auto& icache_rsp_port = icache_rsp_ports.at(0);
  if (!icache_rsp_port.empty()) {
    auto& mem_rsp = icache_rsp_port.front();
    auto trace = pending_icache_.at(mem_rsp.tag);  // Look up trace by tag
    decode_latch_.push(trace);                     // Move trace forward
    pending_icache_.release(mem_rsp.tag);
    icache_rsp_port.pop();
    // Note: No data from mem_rsp used here
    // Actual instruction code fetched via emulator_.icache_read()
    // at a different time in the execution cycle
  }
}
```

The trace (`instr_trace_t*`) already contains the necessary instruction data fetched previously via the emulator's functional accessor.

### DCache Accesses (Explicit)

For LSU memory instructions, SimX does two separate things:

1. **Functional data access now** (inside emulator execute path)
2. **Timing request/response tracking** (inside LSU/cache path)

Evidence:

- Functional load/store access in emulator execute path:
  - [sim/simx/execute.cpp L663-L723](../sim/simx/execute.cpp#L663)
  - Load uses `dcache_read()` at [sim/simx/execute.cpp L674](../sim/simx/execute.cpp#L674)
  - Store uses `dcache_write()` at [sim/simx/execute.cpp L719](../sim/simx/execute.cpp#L719)
- Timing LSU request issue in LSU unit:
  - [sim/simx/func_unit.cpp L320](../sim/simx/func_unit.cpp#L320)
- LSU response handling:
  - [sim/simx/func_unit.cpp L175-L198](../sim/simx/func_unit.cpp#L175)

Important detail: LSU timing messages are metadata-only too:

- `LsuReq` has `mask`, `addrs`, `write`, `tag`, `cid`, `uuid` (no data payload) at [sim/simx/types.h L907-L942](../sim/simx/types.h#L907)
- `LsuRsp` has `mask`, `tag`, `cid`, `uuid` (no data payload) at [sim/simx/types.h L944-L964](../sim/simx/types.h#L944)

So for DCache accesses, the value path is functional (`dcache_read/write`), while the cache path contributes timing/backpressure.

---

## Synchronization: How Timing and Functional Paths Coordinate

### Single Pipeline Cycle Example

Consider a load instruction over one cycle:

**Cycle N (LSU execute):**

```
1. LSU executes load via functional path:
   emulator_.dcache_read(&value, addr, size)
   → Returns actual data immediately
   
2. Emulator computes architectural result immediately:
  loaded value is placed in `rd_data` and then written to warp register file
  (see writeback to `warp.ireg_file` / `warp.freg_file` in
  [sim/simx/execute.cpp L1490-L1543](../sim/simx/execute.cpp#L1490))
   
3. LSU issues timing request via timing path:
   lmem_switch_->ReqIn.push(lsu_req)
   → Request enters cache simulator
   → Pipeline delay begins
```

**Cycle N+3 (Response arrives):**

```
1. Cache simulator issues response:
   lsu_rsp_port.push(mem_rsp)
   → Contains tag, not data
   
2. LSU handles response:
   entry = pending_rd_reqs[mem_rsp.tag]
   trace = entry.trace
  // Response unlocks timing dependency; no payload data in response
   Outputs.at(iw).push(trace, 1)
   → Move instruction forward
```

**Key insight:** Data is retrieved/applied by functional execution (`dcache_read/write`) before timing completion. The timing path models ordering/latency and uses metadata-only responses.

---

## Why This Design?

### Correctness Without Redundancy

- **Functional path:** Ensures correct data values for ISA semantics
- **Timing path:** Models cache pipeline delays without duplicating data transmission

If data were sent through responses:
- Responses would be much larger (carrying cache-line-sized payloads)
- Risk of consistency issues between functional and timing paths
- Unnecessary complexity in cache simulator

### Performance Model Accuracy

The separation allows:
- **Cache timing model** to focus purely on hit/miss decisions and latency
- **Functional model** to focus purely on correct data values
- Independent tuning of each aspect

---

## Memory Access Types

SimX recognizes different address regions with different access patterns:

From [sim/simx/emulator.cpp L309-340](../sim/simx/emulator.cpp#L309-L340):

| Address Type | Access Path | Timing Model |
|--------------|-------------|--------------|
| **Shared** (local memory) | `core_->local_mem()->read/write()` | Local memory simulator |
| **Global** (main memory) | `mmu_.read/write()` | MMU → main memory simulator |
| **I/O** (stdout) | `writeToStdOut()` | Special handling |

All use functional path (direct calls), but route to different backend simulators.

---

## Request vs. Response Symmetry

**Requests carry data, responses don't:**

| Direction | Message Type | Contains Data? | Path |
|-----------|--------------|----------------|------|
| **Core → Cache** | MemReq | No (just address) | Timing |
| **Cache → Core** | MemRsp | No (just metadata) | Timing |
| **Emulator → RAM** | read()/write() | Yes (in buffer) | Functional |
| **RAM → Emulator** | (return value) | Yes (in buffer) | Functional |

---

## Practical Example: Complete Load Lifecycle

**Instruction:** `lw r1, 0(r2)` at address 0x80001000 (data in L1 cache)

### Timeline

| Time | Component | Action | Data Flow |
|------|-----------|--------|-----------|
| **Execute** (Emulator functional) | Emulator | `dcache_read(&val, 0x80001000, 4)` | Reads actual data from memory into `val` |
| | Emulator | Writes architectural result | Value is written to destination register file in execute path |
| | LSU | Issues timing request | `lsu_req.addrs[0] = 0x80001000` (address only, no data) |
| **+1 cycle** | Cache | Request arrives at L1 | Port delay: 1 cycle |
| **+2-3 cycles** | Cache | Hit in L1 tag array | Cache latency: 2 cycles |
| **+4 cycles** | Cache | Response generated | `LsuRsp(tag=123)` (metadata only) |
| | LSU | Response received | `lsu_rsp = LsuRsp(tag=123)` |
| | LSU | Lookup pending load | `entry = pending_rd_reqs[123]` |
| | LSU | Forward to writeback | Response releases pipeline dependency; no data copied from response |

**Data source:** Functional emulator access (immediate)
**Response content:** Metadata only (`tag/cid/uuid/mask` depending on channel)
**Timing role:** Response indicates completion/availability, not value transport

---

## Boundaries and Coupling

### What's Tightly Coupled

- `Emulator` functional path **must** precede Core timing path for each instruction
- LSU timing bookkeeping depends on tags that connect traces to response completion

### What's Loosely Coupled

- Cache simulator does NOT see or process actual data values
- Cache responses are purely timing signals
- MemRsp doesn't depend on cache contents (no payload)

---

## Recommendations

- For debugging: Set breakpoint at emulator functional access to see when data is fetched vs. when timing response arrives
- For performance analysis: Profile difference between functional access time and timing response time to understand pipeline efficiency
- For extension: If adding coherency, send invalidation messages via timing path; keep functional path for correct values

---

## Key Takeaway

**SimX cleanly separates concerns:**
- **Functional correctness** via emulator's direct `mmu_.read/write()` calls
- **Timing accuracy** via cache simulator's response latency model
- **Responses are metadata-only** (tag for matching, no data payload)
- **DCache value transport is functional**, while DCache timing transport is via request/response metadata

This design achieves both ISA correctness and realistic cache timing without the complexity of passing data through the timing simulation path.
