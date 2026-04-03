# Vortex SimX: Instruction Storage, Representation, and Decode Pipeline

## Overview

Instructions in Vortex SimX are represented and processed in two distinct forms:
1. **Binary Form**: Stored as 32-bit RISC-V encoded values in instruction memory
2. **Metadata Form**: Represented as `instr_trace_t` structures carrying execution information through the pipeline

This dual representation allows the simulator to maintain both the original instruction encoding and the decoded/executed properties as instructions flow through the core pipeline.

---

## Instruction Storage

### Binary Representation

Instructions are stored as **32-bit RISC-V encoded values** in instruction memory (part of the system's RAM):
- Stored at aligned 4-byte addresses in memory
- Follow standard RISC-V ISA instruction formats (R, I, S, B, U, J types)
- Loaded from compiled kernel/application binaries during simulation initialization

Example encodings (from [sim/simx/instr.h](../sim/simx/instr.h)):
```
R-type:  opcode[6:0] | rd[11:7] | funct3[14:12] | rs1[19:15] | rs2[24:20] | funct7[31:25]
I-type:  opcode[6:0] | rd[11:7] | funct3[14:12] | rs1[19:15] | imm[31:20]
S-type:  opcode[6:0] | imm[4:0] | funct3[14:12] | rs1[19:15] | rs2[24:20] | imm[31:25]
```

### Opcode Types

The simulator recognizes RISC-V opcode variants ([sim/simx/instr.h L20-48](../sim/simx/instr.h#L20-L48)):
- **Base Integer**: R, I, S, B, LUI, AUIPC, JAL, JALR, SYS, FENCE
- **Floating-Point**: FL, FS, FCI, FMADD, FMSUB, FNMADD, FNMSUB
- **64-bit Extensions**: R_W, I_W  
- **Vector Extensions**: VSET
- **Custom Extensions**: EXT1-EXT4 for specialized operations

---

## Instruction Trace Structure

### instr_trace_t Definition

The `instr_trace_t` structure ([sim/simx/instr_trace.h L46-123](../sim/simx/instr_trace.h#L46-L123)) carries instruction metadata through the pipeline:

```cpp
struct instr_trace_t {
  const uint64_t uuid;          // Unique instruction ID
  const Arch& arch;             // Architecture reference
  
  uint32_t    cid;              // Core ID
  uint32_t    wid;              // Warp ID
  ThreadMask  tmask;            // Thread mask (active threads in warp)
  Word        PC;               // Program counter
  bool        wb;               // Write-back enable
  
  RegOpd      dst_reg;          // Destination register (type + index)
  std::vector<RegOpd> src_regs; // Source registers (up to 3)
  
  FUType     fu_type;           // Functional unit type (ALU, LSU, FPU, etc.)
  OpType     op_type;           // Operation type (variant within FU)
  
  ITraceData::Ptr data;         // FU-specific data (LSU addresses, SFU args, etc.)
  
  int  pid;                     // Packet ID (for multi-word instructions)
  bool sop;                     // Start of packet
  bool eop;                     // End of packet
  bool fetch_stall;             // Indicates fetch-stage stall
  uint64_t issue_time;          // Cycle when issued
};
```

### Key Attributes

| Field | Purpose |
|-------|---------|
| `uuid` | Global unique identifier for instruction (warp_id \| instr_index) |
| `tmask` | Bitmask of active threads (per-thread execution tracking) |
| `PC` | Instruction address for fetch request and debugging |
| `fu_type` | Routes to functional unit: ALU, LSU, FPU, SFU, VPU, TCU |
| `op_type` | Detailed operation (AluType::ADD, LsuType::LOAD, etc.) |
| `dst_reg` / `src_regs` | Register operands (type: int/float, index: 0-31) |
| `data` | Specialization for LSU (memory addresses), SFU (arguments) |
| `wb` | Whether instruction writes results back |

---

## Fetch Pipeline Stage

### Fetch Operation Overview

The fetch stage ([sim/simx/core.cpp L239-263](../sim/simx/core.cpp#L239-L263)) retrieves instructions from the L1 instruction cache (icache):

**Two-phase process:**
1. **Request Phase**: Send memory request to icache for instruction at PC
2. **Response Phase**: Receive instruction data and forward to decode stage

### Fetch State Machine

```
[Emulator]                    [Core Fetch Stage]           [L1 ICache]
    |                              |                           |
    |---step()---------------->    |                           |
    |  (call per cycle)             |                           |
    |                               |                           |
    |<---instr_trace_t*---          |                           |
    |  (partial trace)              |                           |
    |                               |--icache_req------>        |
    |                               | (PC, uuid, tag)           |
    |                               |                    (hit)
    |                               |<----icache_rsp----
    |                               | (MemRsp: tag, data)
    |                               |                           
    |                               |--decode_latch.push->      
```

### Fetch Latch and Pending Cache

From [sim/simx/core.cpp L239-263](../sim/simx/core.cpp#L239-L263):

```cpp
void Core::fetch() {
  // Handle icache response
  auto& icache_rsp_port = icache_rsp_ports.at(0);
  if (!icache_rsp_port.empty()){
    auto& mem_rsp = icache_rsp_port.front();
    auto trace = pending_icache_.at(mem_rsp.tag);  // Lookup by tag
    decode_latch_.push(trace);
    pending_icache_.release(mem_rsp.tag);
    icache_rsp_port.pop();
  }

  // Send icache request
  if (fetch_latch_.empty())
    return;
  auto trace = fetch_latch_.front();
  MemReq mem_req;
  mem_req.addr  = trace->PC;
  mem_req.write = false;
  mem_req.tag   = pending_icache_.allocate(trace);
  icache_req_ports.at(0).push(mem_req, 2);  // 2-cycle latency
  fetch_latch_.pop();
}
```

**Key Data Structures:**
- `fetch_latch_`: Pipeline latch holding traces waiting for icache request
- `pending_icache_`: Tag-indexed lookup table matching responses to requests
- `icache_rsp_ports`: Ports receiving `MemRsp` responses with tag field
- `pending_ifetches_`: Counter for in-flight fetch requests

### Fetch Flow from Emulator

From [sim/simx/emulator.cpp L155-190](../sim/simx/emulator.cpp#L155-L190):

```cpp
instr_trace_t* Emulator::step() {
  // Find next ready warp
  for (size_t wid = 0; wid < num_warps; ++wid) {
    if (active && !stalled) {
      scheduled_warp = wid;
      break;
    }
  }
  
  auto& warp = warps_.at(scheduled_warp);
  
  // Fetch instruction if ibuffer empty
  if (warp.ibuffer.empty()) {
    uint64_t uuid = (global_wid << 32) | warp.uuid++;
    
    // Step 1: Fetch binary instruction
    auto instr_code = this->fetch(scheduled_warp, uuid);
    
    // Step 2: Decode to instr_trace_t
    this->decode(instr_code, warp_id, uuid);
    
    // Step 3: Execute to populate operands
    return this->execute(instr, warp_id);
  }
}

uint32_t Emulator::fetch(uint32_t wid, uint64_t uuid) {
  auto& warp = warps_.at(wid);
  uint32_t instr_code = 0;
  this->icache_read(&instr_code, warp.PC, sizeof(uint32_t));
  // Return 32-bit binary instruction
  return instr_code;
}
```

**Fetch Latency:** 2 cycles (configured in icache_req_ports.push)

---

## Decode Pipeline Stage

### Decode Operation Overview

The decode stage ([sim/simx/core.cpp L271-299](../sim/simx/core.cpp#L271-L299)) processes `instr_trace_t` entries from the decode latch and inserts them into the instruction buffer (ibuffer).

### Decode Latch and Instruction Buffer

```cpp
void Core::decode() {
  if (decode_latch_.empty())
    return;

  auto trace = decode_latch_.front();

  // Check ibuffer capacity (per-warp)
  auto& ibuffer = ibuffers_.at(trace->wid);
  if (ibuffer.full()) {
    ++perf_stats_.ibuf_stalls;  // Stall until space available
    return;
  }

  // Resume warp execution in emulator
  if (!trace->fetch_stall) {
    emulator_.resume(trace->wid);
  }

  DT(3, "pipeline-decode: " << *trace);

  // Insert to instruction buffer
  ibuffer.push(trace);

  decode_latch_.pop();
}
```

**Key Components:**
- `decode_latch_`: Pipeline latch holding traces from icache response
- `ibuffers_`: Per-warp instruction buffers storing ready instructions
- **Stall Conditions**: 
  - ibuffer full (limited depth, typically 4-8 entries)
  - Warp is stalled in emulator (fetch_stall flag)

### Emulator Decode and Execution

From [sim/simx/emulator.cpp L200+](../sim/simx/emulator.cpp#L200):

```cpp
// Step 2: Decode binary instruction to instr_trace_t
void Emulator::decode(uint32_t code, uint32_t wid, uint64_t uuid) {
  // Extract fields from 32-bit encoding
  uint32_t opcode = code & 0x7F;
  uint32_t rd = (code >> 7) & 0x1F;
  uint32_t rs1 = (code >> 15) & 0x1F;
  uint32_t rs2 = (code >> 20) & 0x1F;
  uint32_t funct3 = (code >> 12) & 0x7;
  uint32_t funct7 = (code >> 25) & 0x7F;
  
  // Dispatch to instruction-specific decoder
  // (Each opcode has unique extraction logic in decode.cpp)
}

// Step 3: Execute for operand values
instr_trace_t* Emulator::execute(const Instr &instr, uint32_t wid) {
  // Allocate and populate instr_trace_t
  auto trace = std::make_shared<instr_trace_t>(uuid, arch_);
  trace->cid = core_id;
  trace->wid = wid;
  trace->tmask = warp.tmask;
  trace->PC = warp.PC;
  trace->fu_type = instr.getFUType();
  trace->op_type = instr.getOpType();
  
  // Fetch source operand values
  for (int i = 0; i < 3; ++i) {
    auto reg = instr.getSrcReg(i);
    trace->src_regs[i] = reg;
    fetch_registers(operands, wid, i, reg);
  }
  
  trace->dst_reg = instr.getDestReg();
  trace->wb = (instr.getDestReg().type != RegType::None);
  
  return trace;
}
```

### Decode Process in decode.cpp

From [sim/simx/decode.cpp](../sim/simx/decode.cpp) - ~1143 lines of extraction logic:

The decode process (exemplified by ALU operations):
1. **Extract opcode** from bits [6:0]
2. **Route by opcode type** to appropriate handler
3. **Extract immediate values** and operand indices
4. **Populate Instr object** with FUType, OpType, and arguments
5. **Return Instr** for execution phase

Example decode for ALU ADD instruction:
```
Bits: [31:25] = funct7 | [24:20] = rs2 | [19:15] = rs1 | [14:12] = funct3 | [11:7] = rd | [6:0] = opcode
       0000000    reg2     reg1       000       dest        0110011 (ADD)
→ Creates: Instr with fu_type=ALU, op_type=AluType::ADD, rs1/rs2/rd fields
```

---

## Instruction Flow Through Pipeline

### Complete Execution Timeline

```
Cycle N:
  ├─ schedule(): Emulator.step() → instr_trace_t
  │  └─ fetch_latch.push(trace)
  │
  ├─ fetch():
  │  ├─ (Request) icache_req for trace->PC with tag=uuid
  │  └─ (Response pending in flight...)
  │
  ├─ decode():
  │  └─ (waiting for icache_rsp)
  │
  ├─ issue() / execute() / commit()
  │  └─ (operating on prior cycle's instructions)
  │
Cycle N+2:
  ├─ fetch():
  │  ├─ (Response arrives) icache_rsp with matching tag
  │  ├─ lookup: trace = pending_icache_[tag]
  │  └─ decode_latch.push(trace)
  │
  ├─ decode():
  │  ├─ Check ibuffer space
  │  ├─ ibuffer.push(trace)
  │  └─ resume warp in emulator
  │
  ├─ issue():
  │  ├─ Dequeue from ibuffer
  │  ├─ Check scoreboard for dependencies
  │  ├─ operand_stage.push(trace)
  │  └─ operand fetch occurs next cycle
  │
Cycle N+3:
  ├─ execute():
  │  ├─ ALU/FPU/LSU functional units
  │  ├─ Compute results
  │  └─ forward to writeback
  │
  ├─ commit():
  │  └─ Update register files / memory
```

### Key Latencies

| Stage | Latency | Notes |
|-------|---------|-------|
| Fetch → ICache | 2 cycles | Configurable, 2-cycle default |
| Decode | 1 cycle | Limited by ibuffer capacity |
| Issue | 1 cycle | Scoreboard dependency check |
| Operand Fetch | 1 cycle | Read from register file |
| Execute | 1+ cycles | Varies by FU (ALU=1, LSU=2+, FPU=5+) |
| Commit | 1 cycle | Writeback |
| **Total**: | **8+ cycles** | Best case for independent instructions |

---

## Instruction Buffer and Scoreboard

### Per-Warp Instruction Buffers

From [sim/simx/core.h](../sim/simx/core.h):
- Each warp has dedicated ibuffer queue (depth typically 4-8 instructions)
- Decouples emulator execution rate from core pipeline rate
- Enables warp to be suspended between fetch and decode

### Scoreboard Dependency Tracking

From [sim/simx/core.cpp L302-345](../sim/simx/core.cpp#L302-L345):
- Tracks register dependencies between instructions
- Prevents issue of instruction until sources are available
- Stall counter tracks dependency type (ALU/FPU/LSU/SFU source)

```cpp
// Check scoreboard during issue
if (scoreboard_.in_use(trace)) {
  auto uses = scoreboard_.get_uses(trace);
  // Stall and log dependent instructions
  ++perf_stats_.scrb_alu;  // or other FU type
} else {
  // Mark as ready for dispatch
  ready_set.set(w);
}

if (trace->wb) {
  scoreboard_.reserve(trace);  // On issue, reserve output register
}
```

---

## Key Data Structures Summary

| Structure | File | Purpose |
|-----------|------|---------|
| `Instr` | [sim/simx/instr.h L131](../sim/simx/instr.h#L131) | Decoded instruction with operand indices |
| `instr_trace_t` | [sim/simx/instr_trace.h L46](../sim/simx/instr_trace.h#L46) | Instruction with execution metadata |
| `Opcode` enum | [sim/simx/instr.h L20](../sim/simx/instr.h#L20) | 7-bit opcode values (R, I, S, etc.) |
| `MemReq` / `MemRsp` | [sim/simx/types.h](../sim/simx/types.h) | ICache request/response packets |
| `warp_t` | [sim/simx/emulator.h](../sim/simx/emulator.h) | Warp state with ibuffer and registers |
| `PipelineLatch` | [sim/simx/pipeline.h](../sim/simx/pipeline.h) | Template latch holding traces between stages |

---

## Debug and Tracing

### Instruction Trace Output

The `instr_trace_t` operator<< ([sim/simx/instr_trace.h L134-155](../sim/simx/instr_trace.h#L134-L155)) produces human-readable traces:

```
cid=0, wid=0, tmask=1, PC=0x80000000, wb=1, rd=r1, rs1=r2, ex=ALU (#0x00000000)
```

Decode to understand:
- `cid=0`: Core 0
- `wid=0`: Warp 0
- `tmask=1`: Thread 0 active
- `PC=0x80000000`: Fetch address
- `wb=1`: Writes result back
- `rd=r1`: Destination register 1
- `rs1=r2`: Source register 2
- `ex=ALU`: Functional unit type
- `(#uuid)`: Unique instruction ID

### Debug Levels (DT Macro)

From [sim/simx/core.cpp](../sim/simx/core.cpp):
- `DT(3, ...)`: Log fetch/decode pipeline activity
- `DT(4, ...)`: Log issue/scoreboard details
- Enable via `DEBUG=2` or higher in Makefile

---

## Summary: The Complete Picture

1. **Instructions originate** as 32-bit binary values in instruction memory
2. **Emulator fetches** raw instruction code and decodes to extract operands
3. **Emulator.step()** produces `instr_trace_t` with decoded metadata and values
4. **Trace flows through pipeline latches**:
   - schedule → fetch_latch → (icache fetch) → decode_latch → ibuffer → issue → execute → commit
5. **Scoreboard** ensures register dependencies respected
6. **Per-warp ibuffer** decouples emulator from core execution rate
7. **Tag-based response matching** correlates icache responses to pending requests

This dual-representation design allows SimX to efficiently model cycle-accurate execution while maintaining a functional RISC-V emulator beneath.
