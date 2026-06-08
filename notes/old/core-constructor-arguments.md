# Core Constructor Arguments

This note explains what each of the five constructor arguments to `Core` represents and how they're used.

## Constructor Signature

From [sim/simx/core.h L112-118](../sim/simx/core.h#L112-L118):

```cpp
Core(const SimContext& ctx,
     uint32_t core_id,
     Socket* socket,
     const Arch &arch,
     const DCRS &dcrs
);
```

---

## Argument Breakdown

### 1. `const SimContext& ctx`

**Type:** Reference to `SimContext` (empty context object)

**Purpose:** 
- Required by the base `SimObject<Core>` class to register this core with the simulation platform
- Used internally by SimPlatform for lifecycle management and object tracking
- Empty class; mainly a compile-time/structural requirement

**Definition:** [sim/common/simobject.h L305-310](../sim/common/simobject.h#L305-L310)

**Usage in Core constructor:**
```cpp
: SimObject(ctx, StrFormat("core%d", core_id))
```
Passes it to parent class for initialization. The context is used once during construction; thereafter the core operates independently.

---

### 2. `uint32_t core_id`

**Type:** Unsigned 32-bit integer

**Purpose:** 
- Unique identifier within the processor for this core
- Used to generate the core's simulation object name (`core0`, `core1`, etc.)
- Passed to functional units and the emulator for hierarchical ID reporting
- Returns via `id()` getter for queries

**Usage in Core constructor:**
```cpp
: SimObject(ctx, StrFormat("core%d", core_id))
, core_id_(core_id)
```

**Referenced by:**
- `core_->id()` in functional units and emulator
- Performance CSRs that report `VX_CSR_CORE_ID`
- Hardware trace/debugging output
- Multi-core synchronization (barriers, socket operations)

---

### 3. `Socket* socket`

**Type:** Raw pointer to parent `Socket` object

**Purpose:** 
- Provides upward link to the socket/cluster hierarchy
- Socket coordinates inter-core communication (e.g., global barriers)
- Socket manages access to shared L2/L3 caches
- Socket holds local memory and coalescing logic for the socket region

**Usage in Core constructor:**
```cpp
, socket_(socket)
```

**Accessed via:**
- `socket()` getter returns the socket pointer
- Called by functional units and dispatcher logic
- Used in barrier implementation for cross-core synchronization
- Memory system accesses routed through socket

---

### 4. `const Arch& arch`

**Type:** Const reference to `Arch` object

**Purpose:** 
- Immutable architecture configuration record
- Specifies static hardware parameters used throughout core construction and execution

**Arch contains:**
- `num_threads()` - threads per warp (e.g., 32)
- `num_warps()` - warps per core (e.g., 8)
- `num_cores()` - total cores per cluster
- `num_clusters()` - total clusters in processor
- `socket_size()` - cores per socket
- `num_barriers()` - number of barrier hardware counters
- `local_mem_base()` - base address of local memory region

**Definition:** [sim/simx/arch.h L25-70](../sim/simx/arch.h#L25-L70)

**Usage in Core constructor:**
```cpp
, arch_(arch)
, emulator_(arch, dcrs, this)
, ibuffers_(arch.num_warps(), IBUF_SIZE)
, scoreboard_(arch_)
, pending_icache_(arch_.num_warps())
```

Drives sizing of:
- Per-warp instruction buffers
- Scoreboard capacity
- Emulator warp state allocation
- ICache pending tag table

---

### 5. `const DCRS& dcrs`

**Type:** Const reference to `DCRS` object

**Purpose:** 
- Device Configuration Register State (DCRS) - the control interface for the core
- Provides runtime-configurable parameters and state accessible to executed code

**DCRS contains:**
- `BaseDCRS base_dcrs` - base device configuration registers:
  - Startup address / arguments
  - Performance counter class selection
  - Other control flags

**Definition:** [sim/simx/dcrs.h L38-47](../sim/simx/dcrs.h#L38-L47)

**Usage in Core constructor:**
```cpp
, emulator_(arch, dcrs, this)
```

Passed directly to emulator which uses DCRS to:
- Read startup PC/arguments during `Emulator::reset()`
- Provide CSR-based configuration at runtime
- Control performance counter behavior

**Key interface:**
```cpp
uint32_t read(uint32_t addr);   // Read config register
void write(uint32_t addr, uint32_t value);  // Write config register
```

---

## Parameter Flow During Construction

```
Core Constructor Call:
  ├─ SimContext ctx
  │  └─ Passed to SimObject<Core> for framework registration
  │
  ├─ core_id (e.g., 0, 1, 2)
  │  ├─ Used for name: "core0", "core1"
  │  └─ Stored in core_id_ for later access
  │
  ├─ Socket* socket
  │  └─ Stored as socket_ pointer for upward hierarchy navigation
  │
  ├─ Arch arch
  │  ├─ Stored as arch_ reference
  │  ├─ Drives ibuffer_, scoreboard_, emulator_ sizing
  │  └─ Passed to emulator_ and scoreboard_ for parameter queries
  │
  └─ DCRS dcrs
     └─ Passed to emulator_(arch, dcrs, this) for startup config
```

---

## Typical Call Pattern

From the socket/cluster layer:

```cpp
// In Socket or Cluster constructor:
auto core = Core::Create(ctx, core_id, this, arch, dcrs);
```

Where:
- `this` (Socket pointer) represents the socket containing this core
- `arch` and `dcrs` are typically inherited from processor level
- `ctx` is usually `SimContext{}` (empty)
- `core_id` is the index within the socket or cluster

---

## Summary Table

| Argument | Type | Purpose | Typical Value |
|----------|------|---------|----------------|
| `ctx` | `SimContext` | Framework registration | `SimContext{}` |
| `core_id` | `uint32_t` | Unique core identifier | `0`, `1`, `2`, ... |
| `socket` | `Socket*` | Parent socket pointer | Pointer to socket object |
| `arch` | `Arch&` | Static hardware config | Shared across all cores |
| `dcrs` | `DCRS&` | Runtime device control | Shared across all cores |

---

## Key Insight

The five arguments split into two categories:

1. **Instance-specific** (ctx, core_id, socket):
   - Each core gets unique values
   - Enable hierarchical structure

2. **Shared configuration** (arch, dcrs):
   - Same object reference across all cores
   - Ensure consistent hardware model and control state
