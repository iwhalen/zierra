# Zierra: High-Level Implementation Plan

## Architecture Overview

The simulation is divided into independent modules that mirror the conceptual layers of Tierra:
the **instruction set**, the **virtual CPU**, the **memory soup**, the **creature manager**
(reaper + slicer), the **mutation engine**, the **genebank/statistics**, and the **display layer**
(notcurses). Each module has a clean public API and its own test suite.

```
┌─────────────────────────────────────────────────────┐
│                    main.zig (CLI)                    │
├─────────────────────────────────────────────────────┤
│                  Simulation Engine                   │
│  ┌───────────┐ ┌──────────┐ ┌─────────────────────┐ │
│  │  Creature  │ │  Slicer  │ │      Reaper         │ │
│  │  Manager   │ │  Queue   │ │      Queue          │ │
│  └─────┬─────┘ └────┬─────┘ └──────────┬──────────┘ │
│        │             │                  │            │
│  ┌─────▼─────────────▼──────────────────▼──────────┐ │
│  │                    Soup                          │ │
│  │  (memory arena + allocation tracking)            │ │
│  └─────────────────────┬────────────────────────────┘ │
│                        │                             │
│  ┌─────────────────────▼────────────────────────────┐ │
│  │               Virtual CPU                        │ │
│  │  (registers, stack, IP, fetch/decode/execute)    │ │
│  └─────────────────────┬────────────────────────────┘ │
│                        │                             │
│  ┌─────────────────────▼────────────────────────────┐ │
│  │             Instruction Set                      │ │
│  │  (32 opcodes, template matching)                 │ │
│  └──────────────────────────────────────────────────┘ │
│                                                      │
│  ┌──────────────┐  ┌──────────────┐                  │
│  │   Mutation    │  │   Genebank   │                  │
│  │   Engine      │  │   & Stats    │                  │
│  └──────────────┘  └──────────────┘                  │
├──────────────────────────────────────────────────────┤
│              Display (notcurses C ABI)               │
└──────────────────────────────────────────────────────┘
```

---

## Module Breakdown

### 1. Instruction Set (`src/core/instruction.zig`)

The atomic unit of Tierra. Each instruction is 5 bits (stored in a `u5` or `u8`).

**Contents:**

- `Opcode` enum with all 32 instructions (nop_0, nop_1, or1, shl, zero, if_cz, sub_ab, sub_ac, inc_a, inc_b, dec_c, inc_c, push_ax..push_dx, pop_ax..pop_dx, jmp, jmpb, call, ret, mov_cd, mov_ab, mov_iab, adr, adrb, adrf, mal, divide)
- `decode(raw: u5) Opcode` — convert raw byte to opcode
- `encode(op: Opcode) u5` — convert opcode back to raw bits
- `isNop(op: Opcode) bool` — check if instruction is a template component
- `complement(op: Opcode) Opcode` — nop_0 ↔ nop_1

**Tests:**

- Round-trip encode/decode for all 32 opcodes
- Complement correctness
- isNop predicate

---

### 2. Soup / Memory (`src/core/soup.zig`)

The contiguous memory arena that holds all creature code.

**Contents:**

- `Soup` struct:
  - `memory: []u8` — the soup itself (each byte = one instruction)
  - `owner: []?CreatureId` — per-cell write-ownership (null = free)
  - `size: usize` — total capacity
- `init(allocator, size) Soup`
- `deinit()`
- `read(addr: usize) u8` — unrestricted read (wraps around)
- `write(addr: usize, val: u8, writer_id: CreatureId) !void` — write only if writer owns this cell
- `allocate(size: usize) ?Allocation` — find contiguous free block, mark ownership
- `deallocate(alloc: Allocation)` — release ownership
- `freeMemory() u16` — count of unowned cells
- `inoculate(code: []const u8, addr: usize) CreatureId` — seed the initial ancestor

**Tests:**

- Allocation/deallocation round-trip
- Write permission enforcement (write to unowned cell fails)
- Free memory accounting
- Wrap-around reads
- Inoculation of ancestor

---

### 3. Virtual CPU (`src/core/cpu.zig`)

Each creature has its own CPU context. This module defines the CPU state and the execution logic.

**Contents:**

- `Cpu` struct:
  - `ax, bx: u16` — address registers
  - `cx, dx: u16` — numeric registers
  - `fl: Flags` — error flags
  - `sp: u4` — stack pointer (0..9)
  - `stack: [10]u16` — 10-word stack
  - `ip: u16` — instruction pointer
- `init(ip: u16) Cpu`
- `push(val: u16) !void` — push onto stack (error on overflow)
- `pop() !u16` — pop from stack (error on underflow)
- `execute(cpu: *Cpu, op: Opcode, soup: *Soup, creature: *Creature) !void` — execute one instruction
  - Dispatches to per-opcode handlers
  - Template search logic for jmp/jmpb/call/adr/adrb/adrf
- `step(cpu: *Cpu, soup: *Soup, creature: *Creature) !void` — fetch + decode + execute + advance IP

**Template Search (`src/core/template.zig`):**

- `searchForward(soup, start, limit) ?u16`
- `searchBackward(soup, start, limit) ?u16`
- `searchBidirectional(soup, start, limit) ?u16`
- Extracts the NOP pattern following `start`, finds complementary pattern

**Tests:**

- Each opcode in isolation (zero, or1, shl, inc/dec, sub, push/pop, mov, if_cz)
- Stack overflow/underflow
- Template search: forward, backward, bidirectional, not-found
- Full step cycle (fetch → decode → execute → IP advance)

---

### 4. Creature (`src/core/creature.zig`)

Represents a living organism in the soup.

**Contents:**

- `CreatureId` — unique identifier (index or generation counter)
- `Creature` struct:
  - `id: CreatureId`
  - `cpu: Cpu`
  - `mother_alloc: Allocation` — memory block for own code
  - `daughter_alloc: ?Allocation` — memory block for daughter (set by `mal`)
  - `errors: u32` — accumulated error count
  - `instructions_executed: u64`
  - `instructions_copied: u64` — count of mov_iab executions
  - `parent_genotype: ?GenotypeId`
  - `origin_time: u64` — inst_exec_c at birth
- `init(id, alloc, ip, parent) Creature`

**Tests:**

- Construction and field defaults
- Error accumulation

---

### 5. Creature Manager / Scheduler (`src/sim/scheduler.zig`)

Manages the slicer queue, reaper queue, and the main simulation loop.

**Slicer (circular queue):**

- `SlicerQueue` struct — doubly-linked circular list of creatures
- `insert(creature, after)` — insert just ahead of `after`
- `next() *Creature` — advance to next creature
- `remove(creature)` — remove from queue
- `sliceSize(genome_size, slicer_power) u16` — compute time slice

**Reaper (linear queue):**

- `ReaperQueue` struct — doubly-linked list
- `addToBottom(creature)` — newborns go to bottom
- `killTop() CreatureId` — reap the top creature
- `moveUp(creature)` — on error, move toward top (with constraint)
- `moveDown(creature)` — on success of hard instructions, move toward bottom

**Tests:**

- Slicer round-robin ordering
- Slicer insertion order (daughter before mother)
- Slice size calculation with different powers
- Reaper kill order (FIFO with modifications)
- Reaper movement (up on error, down on success, constraints)
- Integration: creatures added/removed from both queues simultaneously

---

### 6. Mutation Engine (`src/sim/mutation.zig`)

Handles cosmic ray mutations, copy errors, and execution flaws.

**Contents:**

- `MutationConfig` struct:
  - `cosmic_rate: u32` — instructions between background mutations
  - `copy_error_rate: u32` — instructions copied between copy mutations
  - `flaw_rate: u32` — execution flaw probability
  - RNG state
- `cosmicRay(soup: *Soup)` — flip one random bit at a random location
- `maybeCopyError(instruction: u8) u8` — possibly flip a bit during mov_iab
- `maybeFlawResult(value: u16) u16` — possibly return value ± 1
- Uses Zig's `std.Random` (Xoshiro256 or similar) seeded at startup

**Tests:**

- Cosmic ray actually modifies one bit
- Copy error rate distribution (statistical test over many calls)
- Flaw magnitude is ±1 only
- Deterministic tests with fixed seed

---

### 7. Genebank & Statistics (`src/sim/genebank.zig`)

Records genotypes and tracks simulation metrics.

**Contents:**

- `GenotypeId` — size + 3-letter code (e.g., `0080aaa`)
- `GenotypeRecord` struct:
  - Name, parent name
  - Origin time
  - Metabolic data (instructions in 1st/2nd replication, errors, copies)
  - Environmental params at origin
  - `breeds_true: bool`
  - `max_prop_pop, max_prop_inst: f32`
- `Genebank` struct:
  - HashMap of GenotypeName → GenotypeRecord
  - `register(genome: []const u8, parent: ?GenotypeId, metadata) GenotypeId`
  - `lookup(id: GenotypeId) ?GenotypeRecord`
  - `nameForSize(size: usize) GenotypeName` — generates next 3-letter code for size class
- `Stats` struct:
  - `inst_exec_c: u64` — global instruction counter (the Tierran clock)
  - `population: u32`
  - `free_memory: u16`
  - Size-class histogram

**Tests:**

- Genotype naming convention (sequential letters per size)
- Registration and lookup
- Stats accumulation

---

### 8. Simulation Engine (`src/sim/simulation.zig`)

Ties everything together. Implements the main loop from the paper.

**Contents:**

- `Simulation` struct:
  - `soup: Soup`
  - `slicer: SlicerQueue`
  - `reaper: ReaperQueue`
  - `mutation: MutationEngine`
  - `genebank: Genebank`
  - `stats: Stats`
  - `config: SimConfig` — soup size, reaper threshold, mutation rates, slicer power, search limit
- `init(config) Simulation`
- `inoculate(ancestor_code: []const u8)` — seed the first creature
- `tick()` — one slicer cycle:
  1. Execute time_slice instructions for current creature
  2. Advance slicer
  3. While free memory < threshold: reap
  4. Maybe apply cosmic ray
  5. Update stats
- `run(max_instructions: u64)` — main loop calling tick()

**Ancestor genome** (`src/sim/ancestor.zig`):

- The 80-instruction self-replicating program (0080aaa) encoded as a `[80]u8`

**Tests:**

- Inoculation creates one creature with correct genome
- Ancestor self-replicates (run until population = 2)
- Reaper triggers when memory fills
- Integration test: run for N instructions, verify population > 1

---

### 9. Configuration (`src/core/config.zig`)

Runtime-configurable simulation parameters loaded from a flat `.zon` file.

**Contents:**

- `SimConfig` struct — all tunable parameters with comptime defaults matching original Tierra paper values:
  - `soup_size: u16 = 60000`
  - `reaper_threshold: f32 = 0.8` — reap when memory usage exceeds this fraction
  - `cosmic_rate: u32 = 10000` — instructions between background mutations
  - `copy_error_rate: u32 = 1000` — instructions copied between copy mutations
  - `flaw_rate: u32 = 0` — execution flaw probability (0 = disabled)
  - `slicer_power: f32 = 1.0` — exponent for time-slice calculation
  - `search_limit: u16 = 500` — template search max distance
  - `snapshot_interval: u64 = 100000` — instructions between snapshots (0 = disabled)
  - `lineage_enabled: bool = true`
  - `output_dir: []const u8 = "output"` — base directory for all output
  - `rng_seed: ?u64 = null` — null = random seed
- `loadFromFile(allocator: Allocator, path: []const u8) !SimConfig` — reads a `.zon` file and parses it using `std.zon.fromSlice(SimConfig, ...)`
- Since all fields have defaults, a partial `.zon` file works — only override what you need
- CLI: `--config path/to/config.zon`; individual CLI flags (e.g., `--soup-size 120000`) override config file values

**Example config file (`config.zon`):**

```zon
.{
    .soup_size = 120000,
    .cosmic_rate = 5000,
    .copy_error_rate = 500,
    .snapshot_interval = 50000,
    .rng_seed = 42,
}
```

**Tests:**

- Parse `.zon` with all fields specified
- Parse partial `.zon` (defaults fill in unspecified fields)
- Invalid `.zon` returns error
- Default config matches original Tierra paper values

---

### 10. Persistence & Lineage (`src/persistence/`)

First-class serialization and lineage tracking. All output goes to `output/<run_id>/`.

#### 10a. Lineage Tracking (`src/persistence/lineage.zig`)

Records every organism birth, death, and first replication as an append-only JSONL event log.

**Contents:**

- `LineageEvent` tagged union:
  - `.birth { parent_id: ?CreatureId, child_id: CreatureId, genotype_id: GenotypeId, time: u64 }`
  - `.death { creature_id: CreatureId, time: u64, cause: DeathCause }` — cause: reaped, error_limit, etc.
  - `.first_replication { creature_id: CreatureId, genotype_id: GenotypeId, time: u64 }` — marks breeds-true
- `DeathCause` enum: `reaped`, `error_limit`
- `LineageWriter` struct:
  - Buffers events in a ring buffer
  - Background thread flushes to `output/<run_id>/lineage.jsonl`
  - `record(event: LineageEvent)` — non-blocking, called from simulation hot path
  - `flush()` / `deinit()` — drain buffer and close file
- Each line is one JSON object, enabling `grep`, `jq`, streaming analysis
- Full phylogenetic tree can be reconstructed offline from the log

#### 10b. Periodic Snapshots (`src/persistence/snapshot.zig`)

Writes simulation summary at regular intervals for time-series analysis.

**Contents:**

- `SnapshotWriter` struct:
  - Configurable interval from `SimConfig.snapshot_interval`
  - Writes to `output/<run_id>/snapshots/<inst_count>.json`
  - Each snapshot captures: population count, genotype census (size-class histogram), top genotypes by population, free memory, instruction counter
  - Background thread: simulation copies snapshot data into a channel, writer thread serializes to disk
- `takeSnapshot(sim: *const Simulation) SnapshotData` — capture current state (fast, lock-free read)

#### 10c. Save/Load State (`src/persistence/state.zig`)

Full simulation serialization for pause/resume.

**Contents:**

- `save(sim: *const Simulation, path: []const u8) !void` — serialize entire simulation state
- `load(allocator: Allocator, path: []const u8) !Simulation` — deserialize and reconstruct
- Uses `std.json.stringify` for output, `std.json.parseFromSlice` for loading (JSON chosen over ZON for state files since they may be large and benefit from streaming)

**Tests (all persistence):**

- Lineage: event serialization round-trip, JSONL formatting correctness
- Lineage integration: run simulation, verify log contains birth/death events with correct parent→child relationships
- Snapshots: run for N instructions, verify files written at expected intervals
- Save/load: save simulation, load into new instance, verify state matches

---

### 11. Display Layer (`src/display/`)

Wraps notcurses via a thin Zig binding module, following idiomatic patterns for C interop.

#### 11a. Notcurses Wrapper (`src/display/notcurses.zig`)

A thin binding module that re-exports all notcurses C symbols and adds Zig-friendly helpers.

**Contents:**

- `@cImport` + `pub usingnamespace` — imports all C symbols and re-exports them so callers use a single namespace:
  ```zig
  const c = @cImport({
      @cDefine("_XOPEN_SOURCE", "700");
      @cInclude("notcurses/notcurses.h");
  });
  pub usingnamespace c;
  ```
- Default struct initializers — C structs from `@cImport` lack Zig defaults, so provide factory functions:
  ```zig
  pub fn notcurses_options_default() c.notcurses_options {
      return .{
          .termtype = null,
          .loglevel = 0,
          .margin_t = 0, .margin_r = 0, .margin_b = 0, .margin_l = 0,
          .flags = c.NCOPTION_SUPPRESS_BANNERS,
      };
  }
  ```
- Error conversion helper — wraps negative C return codes into Zig errors:
  ```zig
  pub fn err(code: c_int) !void {
      if (code < 0) return error.NotcursesError;
  }
  ```

#### 11b. Display Orchestration (`src/display/display.zig`)

Uses the wrapper module idiomatically for init/teardown and rendering.

**Contents:**

- `const nc = @import("notcurses.zig");`
- `Display` struct:
  - `ctx: *nc.notcurses`
  - `stdplane: *nc.ncplane`
  - Dedicated planes for each view
- `init() !Display` — uses `orelse` for nullable pointer handling:
  ```zig
  var opts = nc.notcurses_options_default();
  const ctx = nc.notcurses_core_init(&opts, null) orelse return error.InitFailed;
  const stdplane = nc.notcurses_stdplane(ctx) orelse return error.StdplaneFailed;
  ```
- `deinit()` — `try nc.err(nc.notcurses_stop(self.ctx));`
- `render(sim: *const Simulation)` — draw current state via `try nc.err(nc.notcurses_render(self.ctx));`
- `pollInput() ?InputEvent` — non-blocking input check

#### 11c. Views (separate source files under `src/display/`)

- `soup_view.zig` — color-coded map of the soup (each cell = one instruction, color = owner/opcode)
- `stats_view.zig` — population, diversity, instruction count, free memory
- `creature_view.zig` — detail panel for selected creature (registers, genome)
- `size_histogram.zig` — size-class distribution bar chart

**Tests:**

- Display module compiles and links against notcurses
- Init/deinit without crash (integration test)
- View rendering functions produce expected plane contents (mock plane)

---

### 12. Build Configuration (`build.zig`)

- Link notcurses-core as a system library and link libc:
  ```zig
  exe.linkSystemLibrary("notcurses-core");
  exe.linkLibC();
  ```
- **Prerequisite:** the `notcurses-core` package must be installed on the system (e.g., `apt install libnotcurses-dev` or equivalent)
- Separate build steps:
  - `zig build` — compile library + executable
  - `zig build run` — run simulation
  - `zig build test` — run all unit tests
  - `zig build test-integration` — run integration tests (requires notcurses installed)

---

## File Layout

```
zierra/
├── build.zig
├── build.zig.zon
├── config.zon                   # Runtime simulation config (optional)
├── src/
│   ├── main.zig                 # CLI entry point, arg parsing, run loop
│   ├── root.zig                 # Library root (public API re-exports)
│   ├── core/
│   │   ├── instruction.zig      # Opcode enum, encode/decode, complement
│   │   ├── soup.zig             # Memory arena, allocation, ownership
│   │   ├── cpu.zig              # CPU state, per-opcode execution
│   │   ├── template.zig         # Template pattern search algorithms
│   │   ├── creature.zig         # Creature struct and lifecycle
│   │   └── config.zig           # SimConfig struct, .zon file loading
│   ├── sim/
│   │   ├── simulation.zig       # Top-level engine, main loop
│   │   ├── scheduler.zig        # Slicer queue + Reaper queue
│   │   ├── mutation.zig         # Cosmic rays, copy errors, flaws
│   │   ├── genebank.zig         # Genotype registry and naming
│   │   └── ancestor.zig         # The 80-instruction ancestor genome
│   ├── persistence/
│   │   ├── lineage.zig          # Lineage event log (JSONL)
│   │   ├── snapshot.zig         # Periodic simulation snapshots
│   │   └── state.zig            # Full save/load for pause/resume
│   └── display/
│       ├── notcurses.zig        # @cImport wrapper, usingnamespace re-export, defaults, err()
│       ├── display.zig          # Notcurses init/teardown, render orchestration
│       ├── soup_view.zig        # Soup memory map visualization
│       ├── stats_view.zig       # Statistics dashboard
│       ├── creature_view.zig    # Creature detail inspector
│       └── size_histogram.zig   # Size-class distribution chart
├── output/                      # Runtime output (gitignored)
│   └── <run_id>/
│       ├── lineage.jsonl        # Organism birth/death/replication events
│       └── snapshots/           # Periodic simulation state snapshots
├── plan/
│   └── PLAN.md                  # This file
└── reference/                   # (read-only) Tierra paper, Zig docs
```

---

## Data Contracts Between Modules

This section defines the exact types and signatures that flow across module boundaries. Each boundary is a compile-time contract — the caller and callee must agree on these types.

### Shared Types (used across many modules)

```zig
// Fundamental identifiers
const CreatureId = u16;              // Index into creature storage ArrayList
const GenotypeId = struct {
    size: u16,                       // Genome length in instructions
    code: [3]u8,                     // 3-letter label, e.g., "aaa"
};

// Memory allocation handle — returned by Soup.allocate(), stored by Creature
const Allocation = struct {
    start: u16,                      // Starting address in soup
    len: u16,                        // Number of cells allocated
};
```

### Instruction → Soup

The soup stores raw `u8` values. Only instruction.zig knows how to interpret them.

```
Soup.read(addr) → u8          -- raw byte from soup
instruction.decode(u8) → Opcode   -- caller decodes when needed
instruction.encode(Opcode) → u8   -- for writing instructions into soup
```

The soup never decodes instructions itself. It is an opaque byte store.

### Soup → CPU

The CPU reads and writes the soup during execution. These are the calls the CPU makes:

```
soup.read(addr: u16) → u8                              -- fetch instruction or data (wraps around)
soup.write(addr: u16, val: u8, writer_id: CreatureId) → !void  -- write with ownership check
    errors: error.WriteProtected (cell not owned by writer_id)
```

The CPU calls `soup.read(cpu.ip)` to fetch the current instruction, then `instruction.decode()` to get the opcode.

### Soup → Creature (memory lifecycle)

```
soup.allocate(size: u16) → ?Allocation    -- returns null if no contiguous block found
soup.deallocate(alloc: Allocation) → void -- releases ownership of all cells in block
soup.inoculate(code: []const u8, addr: u16, owner: CreatureId) → void
    -- writes code into soup at addr, sets ownership; used only for initial seeding
```

`Allocation` is the handle stored by `Creature` in `mother_alloc` and `daughter_alloc`.

### CPU → Template Search

Template search is called by the CPU for `jmp`, `jmpb`, `call`, `adr`, `adrb`, `adrf`. The CPU passes the soup and its current position; template.zig reads the soup to find patterns.

```
template.searchForward(soup: *const Soup, start: u16, limit: u16) → ?u16
template.searchBackward(soup: *const Soup, start: u16, limit: u16) → ?u16
template.searchBidirectional(soup: *const Soup, start: u16, limit: u16) → ?u16
```

**Input contract:**

- `start` points to the instruction *after* the addressing opcode (i.e., the first NOP of the template)
- `limit` is `SimConfig.search_limit` — max distance to search
- The function reads NOPs starting at `start` to build the template pattern, then searches for the complement

**Output contract:**

- Returns the address of the instruction *after* the end of the matched complementary template (i.e., where execution should resume)
- Returns `null` if no complementary template is found within `limit`

**On null return**, the calling CPU instruction sets `cpu.fl.error = true` and the instruction is skipped (IP advances past the template NOPs).

### Creature → CPU (composition)

A `Creature` *contains* a `Cpu` — it's a direct struct embed, not a pointer.

```zig
const Creature = struct {
    id: CreatureId,
    cpu: Cpu,                           // Embedded, not referenced
    mother_alloc: Allocation,
    daughter_alloc: ?Allocation,        // Set by `mal`, cleared by `divide`
    errors: u16,                        // Accumulated error count (affects reaper position)
    instructions_executed: u64,
    instructions_copied: u64,           // Count of mov_iab executions
    parent_genotype: ?GenotypeId,
    origin_time: u64,                   // Global inst_exec_c at birth
};
```

The simulation passes `*Creature` to `cpu.step()`, which accesses `creature.mother_alloc`, `creature.daughter_alloc`, etc. when executing `mal`, `divide`, and `mov_iab`.

### CPU.execute() → Simulation callbacks

Certain opcodes have side effects beyond the CPU and soup. The CPU signals these via a returned action enum rather than calling the simulation directly (keeps CPU decoupled from lifecycle management):

```zig
const ExecAction = union(enum) {
    none,
    divide: struct {                     // `divide` instruction executed
        daughter_alloc: Allocation,      // Memory block for the new creature
    },
    mal_request: struct {                // `mal` instruction — creature wants memory
        size: u16,                       // Requested allocation size (from cx register)
    },
    error_condition,                     // An instruction generated an error flag
    hard_instruction_success,            // Successfully executed a "hard" instruction (adr/mal)
};
```

The simulation loop inspects this action after each `step()` call to:

- Create new creatures (`divide`)
- Allocate memory and update `daughter_alloc` (`mal_request`)
- Move creature in reaper queue (`error_condition` → up, `hard_instruction_success` → down)

### Scheduler → Creature (queue membership)

Slicer and reaper queues use intrusive linked list nodes embedded in the `Creature` struct:

```zig
const QueueNode = struct {
    prev: ?*QueueNode,
    next: ?*QueueNode,
};

// Added to Creature struct:
slicer_node: QueueNode,    // Membership in slicer circular queue
reaper_node: QueueNode,    // Membership in reaper linear queue
```

**Slicer contract:**

```
SlicerQueue.insert(creature: *Creature, after: *Creature) → void
    -- inserts creature just ahead of `after` (so `after` runs next after creature)
SlicerQueue.remove(creature: *Creature) → void
SlicerQueue.next() → *Creature          -- advance to next creature in queue
SlicerQueue.sliceSize(genome_size: u16, power: f32) → u16
    -- returns number of instructions to execute: floor(genome_size ^ power)
```

**Reaper contract:**

```
ReaperQueue.addToBottom(creature: *Creature) → void
ReaperQueue.killTop() → *Creature       -- returns creature to be killed
ReaperQueue.moveUp(creature: *Creature) → void
    -- constraint: only moves up if neighbor above has ≤ errors
ReaperQueue.moveDown(creature: *Creature) → void
    -- constraint: only moves down if neighbor below has ≥ errors
```

### Simulation → Mutation Engine

The mutation engine is called at three points in the simulation:

```
// 1. Background mutation — called every N instructions (cosmic_rate)
mutation.cosmicRay(soup: *Soup) → void
    -- picks random address, flips random bit in that byte

// 2. Copy error — called from mov_iab execution path
mutation.maybeCopyError(val: u8) → u8
    -- with probability 1/copy_error_rate, flips one random bit
    -- otherwise returns val unchanged

// 3. Execution flaw — called from arithmetic/bit-flip instruction handlers
mutation.maybeFlawResult(val: u16) → u16
    -- with probability 1/flaw_rate, returns val ± 1
    -- otherwise returns val unchanged
    -- disabled when flaw_rate == 0
```

The mutation engine owns its own RNG state (seeded from `SimConfig.rng_seed`). It never reads or modifies simulation state beyond the specific value passed in.

### Simulation → Genebank

The genebank is notified at creature birth to register genotypes:

```
genebank.register(
    genome: []const u8,              // Slice of soup memory for the creature's code
    parent: ?GenotypeId,             // null for the ancestor
    metadata: struct {
        origin_time: u64,
        first_repro_inst: u64,       // Instructions executed in first replication
        first_repro_errors: u32,
        first_repro_copies: u64,
    },
) → GenotypeId
    -- If genome is already known, returns existing ID
    -- If new, assigns next 3-letter code for this size class

genebank.lookup(id: GenotypeId) → ?*const GenotypeRecord
```

**Breeds-true detection:** After a creature's first replication, the simulation compares the daughter's genome bytes to the genebank's stored genome for that genotype. If they match, `breeds_true` is set to `true` on the `GenotypeRecord`.

### Simulation → Persistence (Lineage)

The simulation emits lineage events at three points:

```
lineage_writer.record(event: LineageEvent) → void   // non-blocking, buffered

const LineageEvent = union(enum) {
    birth: struct {
        parent_id: ?CreatureId,
        child_id: CreatureId,
        genotype_id: GenotypeId,
        time: u64,                   // inst_exec_c
    },
    death: struct {
        creature_id: CreatureId,
        time: u64,
        cause: enum { reaped, error_limit },
    },
    first_replication: struct {
        creature_id: CreatureId,
        genotype_id: GenotypeId,
        time: u64,
    },
};
```

**Threading contract:** `record()` writes into a ring buffer. A background thread drains the buffer to disk as JSONL. The ring buffer is lock-free (single producer, single consumer). If the buffer is full, `record()` blocks until space is available (backpressure).

### Simulation → Persistence (Snapshots)

```
snapshot.takeSnapshot(sim: *const Simulation) → SnapshotData
    -- Reads simulation state (population, genotype census, free memory, inst_exec_c)
    -- This is a fast, read-only operation on the simulation

const SnapshotData = struct {
    time: u64,                          // inst_exec_c
    population: u32,
    free_memory: u16,
    genotype_census: []GenotypeCount,   // sorted by count descending
    size_histogram: []SizeCount,
};

const GenotypeCount = struct { id: GenotypeId, count: u32 };
const SizeCount = struct { size: u16, count: u32 };
```

The simulation calls `takeSnapshot()` every `SimConfig.snapshot_interval` instructions and hands the `SnapshotData` to a background writer thread.

### Simulation → Display

The display reads simulation state but never modifies it:

```
display.render(sim: *const Simulation) → !void
    -- Reads: soup.memory, soup.owner, stats, creature list, slicer/reaper state
    -- Writes: only to notcurses planes (screen output)

display.pollInput() → ?InputEvent
    -- Non-blocking check for user input (pause, quit, select creature, etc.)

const InputEvent = union(enum) {
    quit,
    pause_toggle,
    select_creature: CreatureId,
    // ... extensible as needed
};
```

**Timing contract:** The simulation calls `display.render()` at a throttled rate (e.g., every N ticks or wall-clock interval), not every instruction. The display must handle being called with any valid simulation state.

### Config → Everything

`SimConfig` is created once at startup and passed by value or `*const` to modules that need it:

```
Simulation.init(config: SimConfig) → Simulation
    -- Passes config.soup_size to Soup.init()
    -- Passes mutation rates to MutationEngine.init()
    -- Passes config.search_limit to CPU (stored for template search calls)
    -- Passes config.slicer_power to SlicerQueue
    -- Passes config.reaper_threshold for memory pressure check
    -- Passes config.snapshot_interval to SnapshotWriter
    -- Passes config.rng_seed to MutationEngine and any other RNG consumers
```

No module modifies `SimConfig` after startup. It is effectively immutable for the lifetime of the simulation.

---

## Implementation Order

Each phase produces a testable, runnable artifact.

### Phase 1: Core Data Types

1. `core/instruction.zig` — Opcode enum, encode/decode, complement, isNop
2. `core/soup.zig` — Memory array, read/write, allocate/deallocate
3. `core/cpu.zig` — CPU struct, stack ops, register ops (no execution yet)
4. `core/config.zig` — SimConfig struct with defaults, `.zon` file loading via `std.zon.fromSlice`

### Phase 2: Execution Engine

1. `core/template.zig` — Template search (forward, backward, bidirectional)
2. CPU execution — implement all 32 opcode handlers in `core/cpu.zig`
3. `core/creature.zig` — Creature struct with CPU + allocations

### Phase 3: Lifecycle Management

1. `sim/scheduler.zig` — Slicer and Reaper queues
2. `sim/ancestor.zig` — Encode the 80-instruction ancestor
3. `sim/simulation.zig` — Main loop: inoculate → tick → reap (reads SimConfig)

### Phase 4: Evolution & Lineage

1. `sim/mutation.zig` — Cosmic rays, copy errors, flaws
2. `sim/genebank.zig` — Genotype tracking and naming
3. Wire mutations into CPU execution and main loop
4. `persistence/lineage.zig` — LineageEvent types, LineageWriter with background flush
5. Wire lineage recording into creature birth/death/replication paths

### Phase 5: Snapshots & Persistence

1. `persistence/snapshot.zig` — Periodic snapshot writer with background thread
2. Wire snapshots into main simulation loop
3. `persistence/state.zig` — Full save/load for pause/resume

### Phase 6: Visualization

1. `display/display.zig` — Notcurses init/teardown
2. `display/soup_view.zig` — Soup map
3. `display/stats_view.zig` — Stats panel
4. `display/creature_view.zig` and `display/size_histogram.zig`
5. Wire display into main loop with input handling

### Phase 7: Polish

1. CLI argument parsing (`main.zig`) — `--config`, individual parameter overrides
2. Performance profiling and optimization

---

## Testing Strategy

Every module includes `test` blocks at the bottom of the file. Tests fall into three tiers:

1. **Unit tests** (per-module, no external dependencies):
  - Opcode encoding, CPU arithmetic, stack behavior
  - Soup allocation, ownership enforcement
  - Template search correctness
  - Queue ordering (slicer, reaper)
  - Mutation determinism with fixed seeds
  - Config: parse `.zon` with all fields, partial fields (defaults fill in), invalid file returns error
  - Lineage: event serialization round-trip, JSONL formatting correctness
2. **Integration tests** (cross-module):
  - Ancestor replicates itself correctly (CPU + Soup + Creature)
  - Reaper triggers at memory threshold (Simulation + Scheduler)
  - Mutations produce non-identical offspring (Mutation + CPU + Soup)
  - Full simulation run for N instructions produces expected population dynamics
  - Lineage: run simulation, verify log contains birth/death events with correct parent→child relationships
  - Snapshots: run for N instructions, verify snapshot files written at expected intervals
  - Save/load: save simulation state, load into new instance, verify state matches
3. **Display tests** (require notcurses):
  - Init/deinit lifecycle
  - View rendering (can be tested with notcurses in headless/testing mode)

Run with: `zig build test` (unit + integration), `zig build test-integration` (display tests)

---

## Key Design Decisions


| Decision             | Choice                                                                                                            | Rationale                                                                                                            |
| -------------------- | ----------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| Instruction storage  | `u8` (5 bits used)                                                                                                | Simpler indexing; upper 3 bits available for metadata                                                                |
| Soup addressing      | `u16`                                                                                                             | Supports up to 64K soups; matches the paper's ~60K default and keeps memory compact                                  |
| Creature storage     | ArrayList + free list                                                                                             | O(1) access by ID; IDs are indices                                                                                   |
| Queue implementation | Intrusive doubly-linked list                                                                                      | O(1) insert/remove/reorder for slicer and reaper                                                                     |
| RNG                  | `std.Random.Xoshiro256`                                                                                           | Fast, good statistical properties, seedable                                                                          |
| Display binding      | `@cImport` + `pub usingnamespace` re-export, thin `err()`/default wrappers, `linkSystemLibrary("notcurses-core")` | Zero-cost FFI; single wrapper module re-exports all C symbols with Zig-friendly error conversion and struct defaults |
| Runtime config       | `.zon` file parsed by `std.zon.fromSlice` at startup                                                              | Zig-native format; struct defaults enable partial configs; no recompile to change parameters                         |
| Lineage tracking     | Append-only JSONL event log, background thread flush                                                              | Streamable, greppable, reconstructable into phylogenetic trees; async avoids simulation stalls                       |
| Snapshot interval    | Configurable via `SimConfig.snapshot_interval`                                                                    | Lets user trade disk space for temporal resolution                                                                   |
| Error handling       | Zig error unions                                                                                                  | Natural fit; CPU faults map to error returns                                                                         |


