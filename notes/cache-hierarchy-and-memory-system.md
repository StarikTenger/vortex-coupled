# Cache Hierarchy and Memory System in Vortex SimX

This note explains the multi-level cache hierarchy in Vortex SimX, how caches are connected, and the overall memory system architecture.

---

## Cache Hierarchy Overview

Vortex SimX implements a **3-level cache hierarchy**:

```
                    Cores (in each Socket)
                            ↓
            ┌───────────────────────────────┐
            │  L1 ICache     L1 DCache      │
            │  (per socket)  (per socket)   │ Socket
            │  16 KB each    16 KB each     │
            └───────────────┬───────────────┘
                            ↓
                    L1/L2 Arbiter
                            ↓
            ┌───────────────────────────────┐
            │       L2 Cache (per Cluster)   │ Cluster
            │       1 MB                    │
            └───────────────┬───────────────┘
                            ↓
                  Processor-wide L3
                            ↓
                      Main Memory
```

---

## Level 1: L1 ICache and DCache

### Location and Scope

- **ICache (Instruction Cache):** Per-socket, shared by all cores in the socket
- **DCache (Data Cache):** Per-socket, shared by all cores in the socket
- Implementation: [sim/simx/socket.h](../sim/simx/socket.h) and [sim/simx/socket.cpp](../sim/simx/socket.cpp)

### L1 Cache Configuration

From [build/hw/VX_config.h](../build/hw/VX_config.h) and [sim/simx/socket.cpp L19-70](../sim/simx/socket.cpp#L19-L70):

| Parameter | ICache | DCache |
|-----------|--------|--------|
| **Size** | 16 KB (ICACHE_SIZE) | 16 KB (DCACHE_SIZE) |
| **Line Size** | 64 bytes (L1_LINE_SIZE) | 64 bytes (L1_LINE_SIZE) |
| **Associativity** | 4-way (ICACHE_NUM_WAYS) | 4-way (DCACHE_NUM_WAYS) |
| **Banks** | 1 (single-ported) | DCACHE_NUM_BANKS (multi-bank) |
| **Write Policy** | Write-through | Write-back (configurable) |
| **MSHR Size** | 16 entries (ICACHE_MSHR_SIZE) | 16 entries (DCACHE_MSHR_SIZE) |
| **Pipeline Latency** | 2 cycles | 2 cycles |
| **Memory Ports** | 1 (ICACHE_MEM_PORTS) | Shared via L1 arbiter |

### CacheCluster Structure

L1 caches are managed as `CacheCluster` objects:
- One `CacheCluster` for ICache with multiple cache units
- One `CacheCluster` for DCache with multiple cache units
- Each cache unit handles one or more cores

Definition: [sim/simx/cache_cluster.h](../sim/simx/cache_cluster.h)

### Core-to-L1 Connection

From [sim/simx/core.h L106-110](../sim/simx/core.h#L106-L110):

```cpp
std::vector<SimPort<MemReq>> icache_req_ports;  // Core → ICache
std::vector<SimPort<MemRsp>> icache_rsp_ports;  // ICache → Core
std::vector<SimPort<MemReq>> dcache_req_ports;  // Core → DCache
std::vector<SimPort<MemRsp>> dcache_rsp_ports;  // DCache → Core
```

Cores issue requests through these ports; caches respond with data via response ports.

### L1 Request/Response Arbitration

From [sim/simx/socket.cpp L73-100](../sim/simx/socket.cpp#L73-L100):

```cpp
// L1/L2 arbiter multiplexes ICache and DCache to shared socket memory ports
for (uint32_t i = 0; i < L1_MEM_PORTS; ++i) {
  auto l1_arb = MemArbiter::Create(...);
  
  // ICache and DCache both feed into same arbiter
  icaches_->MemReqPorts.at(i).bind(&l1_arb->ReqIn.at(i));
  dcaches_->MemReqPorts.at(i).bind(&l1_arb->ReqIn.at(overlap + i));
  
  // Responses routed back
  l1_arb->RspOut.at(i).bind(&this->mem_req_ports.at(i));
}
```

**Key Insight:** ICache and DCache requests are multiplexed onto shared socket-level memory ports using round-robin arbitration.

---

## Level 2: L2 Cache

### Location and Scope

- **Per-cluster:** Shared by all sockets in a cluster
- Implementation: [sim/simx/cluster.h](../sim/simx/cluster.h) and [sim/simx/cluster.cpp](../sim/simx/cluster.cpp)

### L2 Cache Configuration

From [sim/simx/cluster.cpp L42-58](../sim/simx/cluster.cpp#L42):

| Parameter | Value |
|-----------|-------|
| **Size** | 1 MB (L2_CACHE_SIZE) |
| **Line Size** | 64 bytes (MEM_BLOCK_SIZE) |
| **Associativity** | 4-way (log2ceil(L2_NUM_WAYS)) |
| **Banks** | 16 (L2_NUM_BANKS) |
| **Write Policy** | Write-back (L2_WRITEBACK) |
| **MSHR Size** | 16 entries (L2_MSHR_SIZE) |
| **Pipeline Latency** | 2 cycles |
| **Memory Ports** | L2_MEM_PORTS (typically 2-4) |

### Cluster-to-L2 Connection

From [sim/simx/cluster.cpp L60-70](../sim/simx/cluster.cpp#L60):

```cpp
// Connect all sockets' L1 output to L2 input
for (uint32_t i = 0; i < sockets_per_cluster; ++i) {
  for (uint32_t j = 0; j < L1_MEM_PORTS; ++j) {
    sockets_.at(i)->mem_req_ports.at(j)
      .bind(&l2cache_->CoreReqPorts.at(i * L1_MEM_PORTS + j));
    l2cache_->CoreRspPorts.at(...)
      .bind(&sockets_.at(i)->mem_rsp_ports.at(j));
  }
}
```

**Key Insight:** Each socket sees L2 as a unified memory interface; responses are automatically routed back to the originating socket.

---

## Level 3: L3 Cache and Main Memory

### L3 Cache Location

- **Per-processor:** Implemented in `ProcessorImpl`
- Shared by all clusters

### Connection Pattern

From processor level (implied hierarchy):

```
Cluster L2 → Processor L3 → Main Memory
```

### Cache Enable Flags

From [build/hw/VX_config.h](../build/hw/VX_config.h):
- `L2_ENABLED`: Enable L2 cache (default: 1)
- `L3_ENABLED`: Enable L3 cache (default: 1)
- `ICACHE_ENABLED` / `DCACHE_ENABLED`: Enable L1 caches (default: 1)

If disabled, that level is **bypassed** (cache requests go directly to next level).

---

## Memory Request and Response Flow

### MemReq Structure

From [sim/simx/types.h](../sim/simx/types.h):

```cpp
struct MemReq {
  uint64_t addr;      // Physical address
  bool write;         // Read (false) or write (true)
  uint32_t cid;       // Core ID
  uint64_t uuid;      // Instruction UUID
  uint64_t tag;       // Unique tag for response matching
};
```

**Tag Field:** Critical for matching responses back to pending requests (used in `pending_icache_` hash table).

### MemRsp Structure

```cpp
struct MemRsp {
  uint64_t tag;       // Matches MemReq tag
  uint32_t cid;       // Core ID (for routing)
  uint64_t uuid;      // Instruction UUID
};
```

### Request/Response Timing

Each cache level introduces latency:

| Level | Request Latency | Response Latency | Total |
|-------|-----------------|------------------|-------|
| L1 ICache | 0 | 2 cycles | 2 |
| L1 DCache | 0 | 2 cycles | 2 |
| L2 | L1_latency + 0 | 2 cycles | L1_latency + 2 |
| L3 | L2_latency + 0 | Variable | L2_latency + ? |
| Main Memory | L3_latency + 0 | 50-100+ cycles | L3_latency + 50+ |

---

## Memory Coalescing

### Purpose

The LSU (Load/Store Unit) uses **memory coalescing** to combine multiple small memory accesses into cache-line-aligned requests.

### Implementation

From [sim/simx/core.cpp L69](../sim/simx/core.cpp#L69):

```cpp
mem_coalescers_.at(b) = MemCoalescer::Create(
  sname,
  LSU_CHANNELS,           // Input channels from LSU
  DCACHE_CHANNELS,        // Output channels to DCache
  DCACHE_WORD_SIZE,       // Word size of coalesced requests
  LSUQ_OUT_SIZE,          // Queue size
  1                       // Number of instances
);
```

### Data Path

```
Core LSU Units
    ↓ (per-thread requests)
Memory Coalescer
    ↓ (combined cache-line requests)
DCache
    ↓ (responses with full line)
LSU Units (distribute results back to threads)
```

---

## Local Memory (LMEM)

### Purpose

Shared on-chip local memory for inter-warp communication and data sharing.

### Configuration

From [build/hw/VX_config.h](../build/hw/VX_config.h):

| Parameter | Value |
|-----------|-------|
| **Size** | 16 KB (1 << LMEM_LOG_SIZE) |
| **Banks** | NUM_LSU_LANES (multi-bank for parallel access) |
| **Word Size** | XLEN bits |
| **Base Address** | LMEM_BASE_ADDR (stack base) |
| **Access Policy** | Shared by all cores/warps |

### Memory Switch Architecture

From [sim/simx/core.cpp L98-120](../sim/simx/core.cpp#L98-L120):

```cpp
// Local memory switch multiplexes LSU requests
for (uint32_t b = 0; b < NUM_LSU_BLOCKS; ++b) {
  lmem_switch_.at(b)->ReqDC.bind(&mem_coalescers_.at(b)->ReqIn);
  lmem_switch_.at(b)->ReqLmem.bind(&lmem_arb->ReqIn.at(b));
  
  // Route responses back appropriately
  mem_coalescers_.at(b)->RspIn.bind(&lmem_switch_.at(b)->RspDC);
  lmem_arb->RspIn.at(b).bind(&lmem_switch_.at(b)->RspLmem);
}
```

**Key Insight:** Each LSU block can route to either DCache or LMEM based on address.

---

## Performance Statistics

### Per-Cache Level

Each cache tracks:

```cpp
struct PerfStats {
  uint64_t reads;           // Read requests
  uint64_t writes;          // Write requests
  uint64_t read_misses;     // Read misses
  uint64_t write_misses;    // Write misses
  uint64_t evictions;       // Lines evicted
  uint64_t bank_stalls;     // Bank conflicts
  uint64_t mshr_stalls;     // MSHR full stalls
  uint64_t mem_latency;     // Accumulated latency to memory
};
```

Accessible via:
- `socket->perf_stats()` - L1 cache statistics
- `cluster->perf_stats()` - L2 cache statistics
- CSR reads via `VX_CSR_MPM_*` registers

---

## Address Space Mapping

From [build/hw/VX_config.h](../build/hw/VX_config.h):

| Region | Range (64-bit) | Purpose |
|--------|----------------|---------|
| **Local Memory** | 0x1FFFF0000 | Per-warp shared memory |
| **User/Kernel** | 0x080000000 - 0x0FFFFFFFF | Instruction/data memory |
| **I/O Region** | 0x000000040 - 0x000010000 | I/O (stdout, CSRs) |
| **Page Table** | 0x0F0000000 | VM page tables (when VM_ENABLE) |

**Key Insight:** Local memory and main memory are at different address ranges; caches route appropriately.

---

## Cache Bypass

When a cache is disabled (e.g., `ICACHE_DISABLE`), requests bypass that level and go directly to the next:

```
Core → (disabled ICache) → L2 Cache → (L3/Memory)
```

This is used for testing and performance tuning.

---

## Practical Example: Load Instruction Latency

A `lw` (load word) from main memory:

1. **Cycle 0:** Core issues dcache request via `dcache_req_ports`
2. **Cycle 1-2:** DCache latency (lookup, tag comparison)
3. **Cycle 2-3:** L1 → L2 request forwarding
4. **Cycle 4-5:** L2 lookup
5. **Cycle 6-7:** L2 → L3 request
6. **Cycle 8+:** L3 lookup, memory request, long latency to DRAM
7. **Cycle 50+:** Response bubbles back through hierarchy
8. **Cycle 52+:** Data arrives at Core via `dcache_rsp_ports`

Total: **~50+ cycles for cache miss to main memory**

If in L1 DCache: **2 cycles**

---

## Summary: Key Design Points

1. **Multi-level hierarchy** with L1/L2/L3 caches reduces memory latency
2. **Per-socket L1 caches** allow parallel access from multiple cores
3. **L1 arbitration** multiplexes ICache and DCache to shared socket memory ports
4. **Per-cluster L2** provides shared working set storage
5. **Memory coalescing** optimizes multi-threaded memory access patterns
6. **Local memory** enables fast shared data exchange
7. **Configurable hierarchy** allows selective cache enable/disable for experiments
8. **Tag-based response routing** ensures responses reach originating cores

This design balances **throughput** (multiple caches operating in parallel) with **latency** (fast L1 hits) and **area efficiency** (shared lower caches).
