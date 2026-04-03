# ICache and DCache Operation in SimX

## Scope

This note explains how instruction cache (ICache) and data cache (DCache) operate in SimX, including when memory requests are issued, when responses arrive, and where pipeline latency is modeled.

---

## ICache: Instruction Fetch Pipeline

### When Requests Are Issued

ICache requests are issued from the **fetch pipeline stage** in [sim/simx/core.cpp L264](../sim/simx/core.cpp#L264).

**Trigger:** One per cycle when `fetch_latch_` is not empty.

```cpp
void Core::fetch() {
  // Check for responses first
  auto& icache_rsp_port = icache_rsp_ports.at(0);
  if (!icache_rsp_port.empty()) {
    // Process response (details below)
  }

  // Send request if there's a pending trace
  if (fetch_latch_.empty())
    return;
  
  auto trace = fetch_latch_.front();
  MemReq mem_req;
  mem_req.addr  = trace->PC;
  mem_req.write = false;
  mem_req.tag   = pending_icache_.allocate(trace);
  mem_req.cid   = trace->cid;
  mem_req.uuid  = trace->uuid;
  icache_req_ports.at(0).push(mem_req, 2);  // 2-cycle latency
}
```

### Request Format

- `addr`: Program counter (PC) address
- `write`: Always false (instruction fetch is read-only)
- `tag`: Unique tag allocated from `pending_icache_` hash table for response matching
- `cid`: Core ID
- `uuid`: Instruction unique ID

### Latency Modeling: Push with Delay

The key line is `icache_req_ports.at(0).push(mem_req, 2)`:

- **`.push(packet, delay)` method** from [sim/common/simobject.h L168](../sim/common/simobject.h#L168) takes two parameters:
  - `packet`: The MemReq to send
  - `delay`: Number of cycles before request appears at sink port (default=1)
  - **Value 2 means:** request takes 2 cycles to traverse the port before arriving at ICache
  
This delay is **hardcoded** and represents the pipeline latency of the link from core to ICache.

### When Responses Arrive

Responses arrive at `icache_rsp_ports.at(0)` after the cache processes the request:

1. **Cycle N:** Core `.push(mem_req, 2)`
2. **Cycle N+1 to N+2:** Request in flight (SimPort delay)
3. **Cycle N+3+:** Cache lookup + hit/miss processing
4. **Cycle N+5+:** Response arrives back at `icache_rsp_ports.at(0)`

Exact response latency depends on:
- Cache hit/miss
- Cache pipeline depth (typically 2 cycles per level)
- Hierarchy depth (L1 → L2 → L3 → memory)

### Response Matching

ICache responses include a `tag` field that matches the original request tag.

```cpp
// Response handling
if (!icache_rsp_port.empty()) {
  auto& mem_rsp = icache_rsp_port.front();
  auto trace = pending_icache_.at(mem_rsp.tag);  // Lookup by tag
  decode_latch_.push(trace);                     // Forward to decode
  pending_icache_.release(mem_rsp.tag);          // Free the tag slot
  icache_rsp_port.pop();
}
```

**Key insight:** `pending_icache_` is a hash table mapping response tags back to original `instr_trace_t*` objects. This decouples request issue time from response arrival time.

---

## DCache: Data Load/Store Pipeline

### When Requests Are Issued

DCache requests are issued from the **LSU (Load/Store Unit)** functional unit in [sim/simx/func_unit.cpp L320](../sim/simx/func_unit.cpp#L320).

**Trigger:** One per cycle when LSU has pending memory operations and output capacity.

```cpp
void LsuUnit::tick() {
  // Handle responses first (details below)
  
  // Issue memory requests
  for (uint32_t iw = 0; iw < ISSUE_WIDTH; ++iw) {
    auto& input = Inputs.at(iw);
    if (input.empty())
      continue;
    
    auto trace = input.front();
    
    // Check if it's a load or store
    bool is_write = (lsu_type == LsuType::STORE);
    
    // Setup request with memory addresses
    LsuReq lsu_req;
    lsu_req.write = is_write;
    lsu_req.addrs = ...;  // From LSU trace data
    
    // Send to local memory switch (routes to DCache or LMEM)
    core_->lmem_switch_.at(block_idx)->ReqIn.push(lsu_req);
  }
}
```

### Request Format

- `write`: true for stores, false for loads
- `addrs`: Array of memory addresses (one per active thread)
- `mask`: Thread mask indicating which lanes are active
- `tag`: Allocated only for loads (stores don't need response matching)
- `cid`, `uuid`: Trace identifiers

### Latency Modeling: No Explicit Push Delay

Unlike ICache requests, LSU memory requests are pushed **without an explicit delay parameter**:

```cpp
core_->lmem_switch_.at(block_idx)->ReqIn.push(lsu_req);
// Equivalent to: .push(lsu_req, 1)  [default delay = 1 cycle]
```

This means:
- **1-cycle delay** for request to traverse from LSU to LMEM switch
- LMEM switch routes to DCache or local memory based on address
- DCache then processes the request independently

### When Responses Arrive

For **loads only**, responses arrive at [sim/simx/func_unit.cpp L175](../sim/simx/func_unit.cpp#L175):

```cpp
// Handle memory responses
for (uint32_t b = 0; b < NUM_LSU_BLOCKS; ++b) {
  auto& lsu_rsp_port = core_->lmem_switch_.at(b)->RspIn;
  if (lsu_rsp_port.empty())
    continue;
  
  auto& lsu_rsp = lsu_rsp_port.front();
  auto& entry = state.pending_rd_reqs.at(lsu_rsp.tag);  // Lookup by tag
  
  entry.count -= lsu_rsp.mask.count();  // Track batches
  if (entry.count == 0) {
    // Full response received
    Outputs.at(iw).push(trace, 1);  // Forward to writeback
  }
}
```

**Stores** do **not** wait for responses; they are considered complete immediately after issuance (from Core's perspective).

### Response Latency Sources

DCache response latency includes:

| Component | Latency | Notes |
|-----------|---------|-------|
| LSU → LMEM switch | 1 cycle | Default SimPort delay |
| LMEM switch routing | 0 cycles | Combinational logic |
| DCache lookup (hit) | 2 cycles | Cache pipeline latency |
| DCache miss → L2 | 2 cycles | Per-level delay |
| L2 miss → L3 | 2 cycles | Per-level delay |
| L3 miss → Memory | 50+ cycles | Main memory latency |
| Response path back | Symmetric | Return through hierarchy |
| **Total (L1 hit)** | ~4-6 cycles | Realistic hit latency |
| **Total (L1 miss)** | 50+ cycles | Depends on hierarchy |

---

## Where Latency Is Modeled

### 1. SimPort Push Delay

**File:** [sim/common/simobject.h L168](../sim/common/simobject.h#L168)

```cpp
void push(const Pkt& pkt, uint64_t delay = 1);
```

- ICache requests explicitly use `push(..., 2)` → 2-cycle delay
- LSU requests use implicit default `push(...)` → 1-cycle delay
- Delay is realized by event scheduling in SimPlatform

### 2. Cache Pipeline Latency

**File:** [sim/simx/cache_sim.h L25](../sim/simx/cache_sim.h#L25)

```cpp
struct Config {
  uint8_t latency;  // Pipeline latency (typically 2)
};
```

**Usage:** [sim/simx/socket.cpp L48](../sim/simx/socket.cpp#L48) for L1 caches

```cpp
icaches_ = CacheCluster::Create(..., 2);  // 2-cycle latency
dcaches_ = CacheCluster::Create(..., 2);  // 2-cycle latency
```

The latency value is used internally by the cache simulator to delay response arrival.

### 3. Memory Hierarchy Miss Penalties

When a cache miss occurs and the request propagates to higher levels:

- Each cache level adds its configured latency
- Miss handling register (MSHR) tracks outstanding requests
- Responses bubble back through the hierarchy with accumulated latency

This is modeled inside **CacheSim::Impl** (implementation hidden in [sim/simx/cache_sim.cpp](../sim/simx/cache_sim.cpp)), not exposed directly.

### 4. Memory Response Timing (Main Memory)

**File:** [sim/simx/mem_sim.cpp L89](../sim/simx/mem_sim.cpp#L89)

```cpp
rsp_args->memsim->mem_xbar_->RspOut.at(rsp_args->bank_id)
  .push(mem_rsp, 1);
```

Main memory simulator schedules response with 1-cycle delay per message hop, modeling realistic memory latencies (50-100+ cycles typical).

---

## Complete Timeline Example: Load from L1 DCache

**Scenario:** Thread 0 executes `lw r1, 0(r2)` with data at L1 DCache hit.

| Cycle | Event | Component |
|-------|-------|-----------|
| 0 | LSU issues load | LSU |
| 1 | Request arrives at LMEM switch | LMEM Switch |
| 1 | LMEM switch routes to DCache | DCache |
| 2-3 | DCache tag lookup (2-cycle latency) | DCache |
| 3 | Cache hit, response generated | DCache |
| 4 | Response arrives at LSU via RspIn | LSU |
| 4 | LSU matches response tag, prepares output | LSU |
| 5 | Trace forwarded to writeback stage | LSU Output |
| 6 | Register written (in commit) | Core |

**Total load-to-use latency:** ~6 cycles (realistic for in-order pipeline)

---

## Complete Timeline Example: Load Miss to Main Memory

| Cycle | Event | Component |
|-------|-------|-----------|
| 0 | LSU issues load | LSU |
| 1 | Request arrives at DCache | DCache |
| 2 | L1 tag miss, request forwarded to L2 | L1 DCache |
| 3 | Request arrives at L2 (1-cycle link delay) | L2 Cache |
| 4-5 | L2 lookup (2-cycle latency) | L2 Cache |
| 5 | L2 miss, request to L3 | L2 Cache |
| 6 | Request arrives at L3 | L3 Cache |
| 7 | L3 miss, request to memory | L3 Cache |
| 8-50 | Main memory access (50+ cycles) | Memory |
| 50-52 | Response through L3 (2-cycle latency) | L3 Cache |
| 52-54 | Response through L2 | L2 Cache |
| 54-56 | Response through L1 | L1 Cache |
| 56 | Response arrives at LSU | LSU |
| 57 | Register written (in commit) | Core |

**Total load-to-use latency:** ~50+ cycles (realistic for main memory miss)

---

## Key Findings

1. **Request issue**: Both ICache and DCache issue requests **one per cycle** from fetch and LSU stages respectively.

2. **Latency sources**:
   - SimPort push delay (ICache: 2 cycles, LSU: 1 cycle)
   - Cache pipeline latency (2 cycles per level)
   - Hierarchy traversal for misses (50+ cycles to main memory)

3. **Response matching**:
   - ICache uses `pending_icache_` hash table keyed by response tag
   - DCache uses `pending_rd_reqs` per LSU block keyed by response tag
   - This design decouples request and response timing

4. **Store semantics**:
   - Stores do not require response tracking
   - Marked complete immediately after issue to LSU
   - Actual memory write happens asynchronously in cache

5. **Delay parameter mechanics**:
   - `.push(packet, delay)` schedules delivery after `delay` cycles
   - Default delay is 1 cycle
   - ICache explicitly specifies delay=2 for link latency
   - Cache internal latency separate from link delay

---

## Recommendations

- For debugging: Add breakpoints at `Core::fetch()` L243-250 and `LsuUnit::tick()` L175 to observe request/response matching.
- For performance analysis: Profile `perf_stats_.ifetch_latency` and `perf_stats_.load_latency` to measure stall impact.
- For tuning: Adjust cache latency config values in [sim/simx/socket.cpp](../sim/simx/socket.cpp) and [sim/simx/cluster.cpp](../sim/simx/cluster.cpp) to model different cache implementations.
