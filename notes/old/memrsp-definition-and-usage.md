# MemRsp: Memory Response Packet

## Scope
Definition, attributes, creation sites, and usage pattern of `MemRsp` in SimX's cache and memory subsystem.

## Definition
[sim/simx/types.h L999-L1015](../sim/simx/types.h#L999):

```cpp
struct MemRsp {
  uint64_t tag;
  uint32_t cid;
  uint64_t uuid;

  MemRsp(uint64_t _tag = 0, uint32_t _cid = 0, uint64_t _uuid = 0)
    : tag(_tag), cid(_cid), uuid(_uuid) {}

  friend std::ostream &operator<<(...);
};
```

## Attributes

| Field  | Type      | Purpose |
|--------|-----------|---------|
| `tag`  | uint64_t  | Unique identifier to match response back to the original request; used to look up pending trace in hash table (e.g., `pending_icache_.at(mem_rsp.tag)`) |
| `cid`  | uint32_t  | Core ID that originated the request; identifies which core receives the response |
| `uuid` | uint64_t  | Per-instruction UUID for unique tracing and debugging; helps correlate response with original instruction trace |

## Creation Sites

### 1. Instruction Cache Responses
[sim/simx/core.cpp L243-L250](../sim/simx/core.cpp#L243):
- Created implicitly when I-cache response port receives data
- Used in fetch pipeline to match response to pending icache tag

### 2. Cache Bank (data cache)
[sim/simx/cache_sim.cpp L425, L457, L496](../sim/simx/cache_sim.cpp#L425):
- `MemRsp core_rsp{bank_req.req_tag, bank_req.cid, bank_req.uuid}`
- Creates response for cache hits and certain misses
- Sent via `core_rsp_port.push()`

### 3. Data Cache Adapter
[sim/simx/core.cpp L38, L133](../sim/simx/core.cpp#L38):
- Multiple dcache response ports (DCACHE_NUM_REQS)
- Bound to `dcache_adapter` outputs

### 4. DRAM Simulator Callback
[sim/simx/mem_sim.cpp L89](../sim/simx/mem_sim.cpp#L89):
- `MemRsp mem_rsp{rsp_args->request.tag, rsp_args->request.cid, rsp_args->request.uuid}`
- Created when DRAM read completes (non-write requests only)
- Pushed to crossbar `RspOut` port

### 5. Local Memory
[sim/simx/local_mem.cpp L90](../sim/simx/local_mem.cpp#L90):
- `MemRsp bank_rsp{bank_req.tag, bank_req.cid, bank_req.uuid}`
- For reads or when write response enabled
- Sent via `mem_xbar_->RspOut.at(i)`

## Ports and Transport

### Definition in module headers:
- [sim/simx/core.h L107, L110](../sim/simx/core.h#L107): `icache_rsp_ports`, `dcache_rsp_ports`
- [sim/simx/cluster.h L36](../sim/simx/cluster.h#L36): `mem_rsp_ports`
- [sim/simx/socket.h L36](../sim/simx/socket.h#L36): `mem_rsp_ports`
- [sim/simx/cache_sim.h L76](../sim/simx/cache_sim.h#L76): `CoreRspPorts`, `MemRspPorts`
- [sim/simx/mem_sim.h L44](../sim/simx/mem_sim.h#L44): `MemRspPorts`

### Transport hierarchy:
1. **L3 Cache** → **Cluster** (via `mem_rsp_ports`)
2. **L2 Cache** → **Socket** (via `mem_rsp_ports`)
3. **L1 D-cache** → **Core** (via `dcache_rsp_ports`)
4. **L1 I-cache** → **Core** (via `icache_rsp_ports`)
5. **DRAM** → **L3 Cache** (via `MemRspPorts`)

## Usage Pattern

### 1. Response matching via tag
When a response arrives, the `tag` field indexes into a tag hash-table holding the original trace:
```cpp
auto& mem_rsp = icache_rsp_port.front();
auto trace = pending_icache_.at(mem_rsp.tag);  // Look up by tag
```

### 2. Core identification via cid
Routes response to correct core:
```cpp
assert(trace->cid == core_id_);  // Verify cid matches expected core
```

### 3. Debugging via uuid
Used in trace output for cycle-accurate instruction correlation:
```cpp
os << " (#" << rsp.uuid << ")";  // uuid in debug/trace output
```

## Key design notes

- **Write responses are optional**: Only reads generate responses by default; writes only respond if `write_response` config is enabled.
- **Tag reuse**: Tag storage is finite (e.g., `pending_icache_` has limited capacity); tags are released after response is processed.
- **Async transport**: Responses flow through multiple arbiters and pipelines; latency is not immediate.
- **Port binding**: Responses are port-to-port connected via SimPort bind in constructors (cache_cluster, socket, processor).

## Next steps
- Trace response latency by adding `DT()` debug prints at key creation and consumption sites.
- Understand tag collision/exhaustion by checking `pending_icache_.full()` and similar for other pending tables.
