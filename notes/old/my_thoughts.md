# Plan for Vortex/Gem5 integration project

**Goal**: use vortex core within gem5 memory system.

**Configuration** that I want to achieve in gem5: gem5 ooo CPU in full system mode along with vortex gpu. Vortex will be an external device to which CPU communicates through memory. I want to run OpenCL on host CPU which will interact with GPU.

## Subgoals

### Implementation

0. Standalone working vortex core? I can feed it with data, get the responce. Probably non-functional, but building correctly
1. Smth really simple in gem5: just configuration with single vortex core, bre metal, direct mem access
2. Attach Simple Caches
3. CPU-GPU system, separate mem. spaces
4. FS mode, openCL
5. Shared mem. space, cache coherency, ruby
6. Interconnect model, garnet

### Research
1. Interconnection patterns: run benchmarks and see how CPU/GPU exchange memory

## Integration strategies (where to put gem5 mem interface)

I need to extract SIMT core functionality from vortex and wrap it in a gem5 SimObject with memory ports. For that I need to understand which where are core borders and in which parts of the code I need to do a gem5 substitution.

Vortex `Core` object does functional execution via `Emulator` object. 
```
Core::schedule -> Emulator::step -> Emulator::fetch -> Emulator::icache_read -> MemoryUnit::read
```

### Idea 1

gem5 ports in MemoryUnit::read/write

Is this access instant or latency is modeled?



### Idea 2

Mem interface inside CacheCluster or Socket
