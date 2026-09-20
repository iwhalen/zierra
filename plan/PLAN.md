# Zierra: High-Level Implementation Plan

## Architecture Overview

The simulation is divided into independent modules that mirror the conceptual layers of Tierra:
the **instruction set**, the **virtual CPU**, the **memory soup**, the **creature manager**
(reaper + slicer), the **mutation engine**, the **genebank/statistics**, and the **display layer**
(notcurses). Each module has a clean public API and its own test suite.

The implementation should be **compile-time first**. Anything that defines the shape of the
simulation is a comptime parameter or generated constant; only the evolutionary process itself is
runtime state. In practice:

- Soup capacity, address width assumptions, owner array shape, stack depth, instruction tables, template
  limits, default config values, ancestor genome bytes, and feature toggles are known at compile time.
  Shape and feature settings come from `src/config.zon` imported with `@import`, not from `zig build -D`
  flags.
- The soup's backing memory is allocated as fixed-size arrays inside a comptime-specialized type,
  rather than heap-allocating the arena on startup.
- Zig will still initialize mutable soup contents when the simulation starts; the compile-time win is
  that capacity, storage layout, address assumptions, and bounds are known to the compiler.
- Configuration comes from one `Config` object imported from `src/config.zon`. Fields that define
  storage shape and fields that tune evolutionary behavior live together in that object.
- The main simulation remains runtime behavior: creature birth/death, allocation occupancy, mutations,
  scheduling, genebank growth, lineage output, and display state are all data that evolves while running.
- Prefer factory functions like `Soup(comptime size: u16) type` and
  `Simulation(comptime config: Config) type` when a module's storage or dispatch can be specialized.

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
│  │  (32 instructions, template matching)            │ │
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

## Linear Implementation Plan

Each phase should produce a testable, runnable artifact. Work through the sections in order; everything
needed for a phase is grouped under that phase header.

---

### [x] Phase 1: Compile-Time Shape

Goal: establish the fixed simulation shape, byte-addressed instruction storage, and the basic CPU state.

#### Configuration (`src/config.zon`, `src/core/config.zig`)

Configuration is one project-wide object imported from `src/config.zon`. Values that affect type
layout and values that tune evolutionary behavior are kept together so the simulation has one source of
truth.

**Contents:**

- [x] `Config` struct populated from `src/config.zon`:
  - `soup_size: u16 = 60000`
  - `stack_depth: u8 = 10`
  - `search_limit: u16 = 500`
  - `lineage_enabled: bool = true`
  - `display_enabled: bool = true`
  - `reaper_threshold: f32 = 0.8`
  - `cosmic_rate: u32 = 10000`
  - `copy_error_rate: u32 = 1000`
  - `flaw_rate: f32 = 1.5`
  - `slicer_power: f32 = 1.0`
  - `snapshot_interval: u64 = 100000`
  - `output_dir: []const u8 = "output"`
  - `rng_seed: u64 = 8675309`

**Example `src/config.zon`:**

```zon
.{
    .soup_size = 60000,
    .stack_depth = 10,
    .search_limit = 500,
    .lineage_enabled = true,
    .display_enabled = true,
    .cosmic_rate = 5000,
    .copy_error_rate = 500,
    .flaw_rate = 1.5,
    .slicer_power = 1.0,
    .snapshot_interval = 50000,
    .output_dir = "output",
    .rng_seed = 42,
}
```

**Tests:**

- Default config matches original Tierra paper values
- Config validation rejects invalid soup size, stack depth, and template limit

#### Instruction Set (`src/core/instruction.zig`)

The atomic unit of Tierra. The paper defines 32 instructions, so the logical instruction code is 5
bits. The soup still stores one instruction per byte, matching the paper's 60,000 byte soup holding
60,000 Tierran instructions.

**Contents:**

- [x] `Instruction` enum with all 32 instructions
- [x] `decode(raw: u8) Instruction` — mask/truncate to the low 5 bits
- [x] `encode(instruction: Instruction) u8` — returns `0x00..0x1f`
- [x] Use switches or enum iteration where helpful instead of premature metadata tables

**Storage rule from Tierra:**

- Treat each soup cell as one byte of storage, not as a packed 5-bit bitstream.
- Only the low 5 bits are genetic instruction data.
- The upper 3 bits are padding and should not participate in decode, mutation, genotype comparison, or
  copy-error mutation.

**Tests:**

- [x] Sanity checks for decoding and encoding
- [x] Decode ignores upper 3 storage bits

#### Soup / Memory (`src/core/soup.zig`)

The contiguous memory arena that holds all creature code.

**Contents:**

- [x] `pub fn Soup(comptime size: u16) type`
- [x] Specialized `Soup(size)` struct:
  - `memory: [size]u8`
  - `owner: [size]?CreatureId`
- [x] `read(addr: usize) u8`
- [x] `write(addr: usize, val: u8, writer_id: CreatureId) !void`
- [x] `allocate(size: usize) ?Allocation`
- [x] `free(alloc: Allocation)`
- [x] `count_free_memory() u16`
- [x] `inoculate(code: []const u8, addr: u16, owner: CreatureId) !Allocation`

**Comptime constraints:**

- [x] `size` must fit in `u16` and default to `60000`.
- [x] Compile-time assertions reject `size == 0` and values larger than `std.math.maxInt(u16)`.
- [x]Changing `src/config.zon` and rebuilding specializes a new binary.

**Tests:**

- [x] Allocation/deallocation round-trip
- [x] Write permission enforcement
- [x] Free memory accounting
- [x] Wrap-around reads (not doing a circular soup right now).
- [x] One-byte-per-instruction behavior
- [x] Inoculation of ancestor

#### CPU State (`src/core/cpu.zig`)

Each creature has its own CPU context. In this phase, implement CPU shape and stack/register helpers
without full instruction execution.

**Contents:**

- `pub fn Cpu(comptime opts: Config) type`
- Specialized `Cpu(opts)` struct:
  - `ax, bx: u16`
  - `cx, dx: u16`
  - `fl: u8`
  - `sp: u8`
  - `stack: [opts.stack_depth]u16`
  - `ip: u16`
- `init(ip: u16) Cpu`
- `push(val: u16) !void`
- `pop() !u16`

This mirrors the original Tierra CPU register struct:

```c
struct cpu {  /* structure for registers of virtual cpu */
    int   ax;      /* address register */
    int   bx;      /* address register */
    int   cx;      /* numerical register */
    int   dx;      /* numerical register */
    char  fl;      /* flag */
    char  sp;      /* stack pointer */
    int   st[10];  /* stack */
    int   ip;      /* instruction pointer */
};
```

**Stack behavior pseudo code:**

```text
push(value):
    if sp == stack_depth:
        fl = 1
        return StackOverflow

    stack[sp] = value
    sp += 1
    fl = 0

pop():
    if sp == 0:
        fl = 1
        return StackUnderflow

    sp -= 1
    fl = 0
    return stack[sp]
```

**Tests:**

- [x] Construction and defaults (initializers used, no constructor needed)
- [x] Stack overflow/underflow

Useful Ziglings: exercises on `enum`, `struct`, `array`, `error_union`, and `comptime`.

---

### Phase 2: Execution Engine

Goal: make one creature's CPU fetch, decode, execute, and advance through soup memory.

#### Template Search (`src/core/template.zig`)

**Contents:**

- [x] `searchForward(soup, start, limit) ?u16`
- [x] `searchBackward(soup, start, limit) ?u16`
- [x] `searchBidirectional(soup, start, limit) ?u16`
- [x] Extract the NOP pattern following `start`, then find the complementary pattern

When the limit is fixed at compile time, loops can be bounded with comptime-known constants. Runtime
limits may still be useful for tests or experiments.

**Tests:**

- [x] Forward, backward, and bidirectional search
- [x] Not-found behavior
- [x] Template extraction at wrap-around boundaries

#### CPU Execution (`src/core/cpu.zig`)

**Contents:**

- `execute(cpu: *Cpu, instruction: Instruction, soup: *Soup, creature: *Creature) ExecResult`
- `step(cpu: *Cpu, soup: *Soup, creature: *Creature) ExecResult`
- `advance_ip(increment: u16, soup_len: u16)` — overflow-safe `ip` advance, no promotion needed
- Implement all 32 instruction handlers, each taking `soup_len: u16` for `ip` updates:
  - e.g. `nop(cpu: *Cpu, soup_len: u16)`, `or1(cpu: *Cpu, soup_len: u16)`, ...
  - arithmetic/register ops
  - stack ops
  - control flow and template-addressing ops
  - memory/copy ops
  - lifecycle signaling ops (`mal`, `divide`)
- Return `ExecResult` for side effects that belong to the simulation layer:
  - `none`
  - `divide`
  - `mal_request`
  - `error_condition`
  - `hard_instruction_success`

**Responsibility split:**

- `step` owns the fetch-decode-dispatch-counter cycle (mirrors the paper's
  `time_slice`: `fetch` → `decode` → `execute` → `increment_ip`). It never
  allocates memory, creates creatures, or moves queues.
- `execute` owns all CPU-local effects: registers, stack, `fl`, soup reads/writes
  via `soup.read`/`soup.write`, **and every `ip` update**. `step` never advances
  `ip` itself, which removes the double-advance hazard where a successful jump
  would be incremented past its target.
- The simulation owns everything `ExecResult` reports (see Phase 3
  "`ExecResult` handling"): allocation, division, `creature.errors` counting,
  and reaper movement. `step`/`execute` only *return* the result; they do not
  touch queues or the genebank.

**`step` pseudo code:**

```text
step(cpu, soup, creature):
    # 1. Fetch. All address arithmetic wraps modulo soup length,
    #    so the soup behaves as a circular arena.
    raw = soup.read(wrap(cpu.ip))

    # 2. Empty cell. Only reachable if the soup type models
    #    uninitialized cells as null (the paper's soup is always
    #    full of random bits, so every fetch decodes to something).
    if raw is empty:
        cpu.fl = 1
        cpu.advance_ip(1, soup.len)   # always advance: never re-execute a fault
        creature.instructions_executed += 1
        return error_condition      # simulation counts the error, moves reaper up

    # 3. Decode (masks to the low 5 bits per the storage rule) and dispatch.
    instruction = decode(raw)
    result = execute(cpu, instruction, soup, creature)

    # 4. Count the executed instruction. Error counting lives in the
    #    simulation's error_condition branch, not here.
    creature.instructions_executed += 1
    return result
```

**`execute` dispatch rules (per instruction group):**

```text
execute(cpu, instruction, soup, creature):
    switch instruction:
        # Plain ops: nop_0, nop_1, or1, shl, zero, sub_ab, sub_ac,
        # inc_a, inc_b, dec_c, inc_c, mov_cd, mov_ab.
        # Each handler takes soup_len and applies register effect
        # (with flaw hook where configured), then default advance:
        #     cpu.advance_ip(1, soup.len)
        #     return none

        # Stack ops: push_ax/bx/cx/dx, pop_ax/bx/cx/dx.
        # On success: move value, default advance, return none.
        # On StackOverflow/StackUnderflow (fl is already set by
        # push/pop itself): still default-advance past the failing
        # instruction, return error_condition.

        # if_cz: conditional skip.
        #     if cpu.cx == 0: cpu.advance_ip(1, soup.len)   # run next instr
        #     else: skip one instruction AND its template, if any:
        #         target = wrap(cpu.ip + 1)
        #         if soup cell at target starts a template-user
        #         (jmp, jmpb, call, adr, adrb, adrf):
        #             target = skip_template(soup, target)
        #         else:
        #             target = wrap(target + 1)
        #         cpu.ip = target
        #     return none

        # Jumps: jmp (bidirectional), jmpb (backward), call (bidirectional + push).
        #     pattern_start = wrap(cpu.ip + 1)
        #     match = template.search_*(soup, pattern_start, search_limit)
        #     if match is null:
        #         cpu.fl = 1
        #         cpu.ip = skip_template(soup, cpu.ip)  # land past our own NOPs
        #         return error_condition
        #     if instruction is call:
        #         try push(wrap(cpu.ip + 1 + template_len))  # return addr past our NOPs
        #         on overflow: fl set, ip = skip_template, return error_condition
        #     cpu.ip = match   # match is already "after the complementary template"
        #     return none

        # ret:
        #     on pop success: cpu.ip = wrap(popped_value); return none
        #     on StackUnderflow: fl set, default advance, return error_condition

        # Address-to-register: adr (bidirectional), adrb (backward), adrf (forward).
        # Same search as jumps, but writes the result instead of jumping:
        #     if match is null: fl = 1, ip = skip_template, return error_condition
        #     else: cpu.ax = match, ip = skip_template, return hard_instruction_success
        # (hard_instruction_success lets the simulation move the creature
        # down the reaper queue; see Phase 3.)

        # mov_iab (copy with ownership check):
        #     data = soup.read(wrap(cpu.bx))       # read is always allowed
        #     if data is empty: fl = 1, default advance, return error_condition
        #     try soup.write(wrap(cpu.ax), maybeCopyError(data), creature.id)
        #     on WriteProtected: fl = 1, default advance, return error_condition
        #     on success: cpu.ax = wrap(cpu.ax + 1); cpu.bx = wrap(cpu.bx + 1)
        #         creature.instructions_copied += 1
        #         cpu.advance_ip(1, soup.len)   # old_ip = ip on entry to mov_iab
        #         return none
        # Note: ax/bx wrap independently of ip; all three use modulo soup length.

        # mal: do NOT allocate here; the simulation owns the soup free list.
        #     cpu.advance_ip(1, soup.len)   # advance BEFORE returning,
        #                                   # or the same mal re-executes forever
        #     return mal_request(cpu.cx)

        # divide: do NOT create the creature here.
        #     if creature.daughter_alloc is null:
        #         cpu.fl = 1; cpu.advance_ip(1, soup.len); return error_condition
        #     cpu.advance_ip(1, soup.len)   # same advance-first rule as mal
        #     return divide(creature.daughter_alloc)
```

**IP helpers used above:**

```text
advance_ip(increment, soup_len):
    # Overflow-safe ip update without promoting to a wider int.
    # Assumes ip < soup_len and soup_len > 0.
    step = increment mod soup_len
    threshold = soup_len - step
    if ip < threshold: ip += step
    else: ip -= threshold

wrap(addr): addr mod soup.len   # for address reads (bx/ax/pattern_start),
                                # ip itself always moves via advance_ip

skip_template(soup, instr_addr):
    # Width of "this instruction plus its trailing NOP template", or 1
    # when the next cell is not a NOP. Used both for landing past our own
    # template after a failed search and for if_cz skipping over a
    # template-user plus its NOPs.
    length = count of consecutive NOP cells starting at wrap(instr_addr + 1)
    return wrap(instr_addr + 1 + length)
```

**Flag and counter ownership (who writes what):**

- `cpu.fl`: set to `1` by `push`/`pop` failures, failed template searches,
  failed ownership checks, empty-cell fetch, and `divide` with no daughter;
  cleared to `0` by successful `push`/`pop`. Successful `adr*` reports via
  `hard_instruction_success` rather than touching `fl` directly.
- `creature.instructions_executed`: incremented once per `step`, on every path
  including faults.
- `creature.instructions_copied`: incremented only by successful `mov_iab`
  inside `execute`.
- `creature.errors`: incremented only by the simulation's `error_condition`
  branch, never by `step`/`execute` (keeps reaper policy in one place).

**Tests:**

- Each instruction in isolation
- Full step cycle: fetch, decode, execute, advance IP
- `step` on an empty cell returns `error_condition` and advances `ip`
- Jump/call land on the address *after* the complementary template; failed
  search sets `fl`, lands past the instruction's own NOPs, returns
  `error_condition`
- `if_cz` with `cx != 0` skips a plain instruction (width 1) and skips a
  template-user plus its NOPs (width 1 + template length)
- `call` pushes the return address past its own template; `ret` pops it back
- `mov_iab` advances `ax`/`bx`, counts the copy, and returns `error_condition`
  on write-protection instead of propagating the soup error
- `mal`/`divide` advance `ip` before returning their `ExecResult`, and
  `divide` without a daughter allocation returns `error_condition`
- Error flag behavior
- `ExecResult` behavior for `mal` and `divide`
- Wrap-around: `ip`, `ax`, `bx` arithmetic modulo soup length

#### Creature (`src/core/creature.zig`)

Represents a living organism in the soup.

**Contents:**

- `CreatureId`
- `Creature` struct:
  - `id: CreatureId`
  - `cpu: Cpu`
  - `mother_alloc: Allocation`
  - `daughter_alloc: ?Allocation`
  - `errors: u32`
  - `instructions_executed: u64`
  - `instructions_copied: u64`
  - `parent_genotype: ?GenotypeId`
  - `origin_time: u64`
- `init(id, alloc, ip, parent) Creature`

**Tests:**

- Construction and field defaults
- Error accumulation

Useful Ziglings: 030_switch / 108_labeled_switch (dispatch in `execute`), 035_enums
(switching over `Instruction`), 045_optionals (empty-cell fetch, nullable search
results), 039_pointers (`*Cpu`/`*Soup`/`*Creature` mutation in `step`), 021_errors
through 024_errors4 plus 033_iferror (`StackError`, `WriteProtected` mapped to
`error_condition`), and 055_unions (the `ExecResult` tagged union).

---

### Phase 3: Lifecycle Management

Goal: run a minimal Tierra loop with creatures, queues, allocation, division, and reaping.

#### Scheduler (`src/sim/scheduler.zig`)

Manages the slicer queue, reaper queue, and the main simulation loop's creature ordering.

**Slicer contents:**

- `SlicerQueue` — doubly-linked circular list of creatures
- `insert(creature, after)`
- `next() *Creature`
- `remove(creature)`
- `sliceSize(genome_size, slicer_power) u16`

**Reaper contents:**

- `ReaperQueue` — doubly-linked list
- `addToBottom(creature)`
- `killTop() CreatureId`
- `moveUp(creature)`
- `moveDown(creature)`

**Tests:**

- Slicer round-robin ordering
- Daughter-before-mother insertion order
- Slice size calculation with different powers
- Reaper kill order
- Reaper movement constraints
- Creatures added/removed from both queues simultaneously

#### Ancestor Genome (`src/sim/ancestor.zig`)

**Contents:**

- The 80-instruction self-replicating program (`0080aaa`) encoded as `[80]u8`
- Compile-time validation that every byte decodes to a known instruction
- Compile-time validation that the genome fits in `config.soup_size`

**Tests:**

- Ancestor bytes decode successfully
- Ancestor length matches expected genome size

#### Simulation Engine (`src/sim/simulation.zig`)

Ties together soup, CPU, creatures, scheduler queues, and the main loop.

**Contents:**

- `pub fn Simulation(comptime config: Config) type`
- Specialized `Simulation(config)` struct:
  - `soup: Soup(config.soup_size)`
  - `slicer: SlicerQueue`
  - `reaper: ReaperQueue`
  - `stats: Stats`
- `config: Config`
- `init() Simulation(config)`
- `inoculate(ancestor_code: []const u8) !CreatureId`
- `tick()`:
  1. Execute the current creature's time slice
  2. Handle `ExecResult` values from CPU steps
  3. Advance slicer
  4. Reap while free memory is below threshold
  5. Update stats
- `run(max_instructions: u64)`

**`ExecResult` handling:**

`ExecResult` reports only work that crosses the CPU/soup boundary and must be completed by the
simulation. CPU-local effects such as changing registers, the stack, flags, or the instruction pointer
are applied by `execute` itself.

`ExecResult` is a tagged union, not a struct containing independent boolean flags. Each call returns
exactly one active result. Variants carry a payload only when the simulation needs data: `mal_request`
carries the requested size and `divide` carries the daughter allocation. `none`, `error_condition`,
and `hard_instruction_success` are payload-free tags; giving them boolean payloads would permit
meaningless states such as `.none = false`.

Expected Tierran execution failures are values, not Zig errors. Stack overflow or underflow, failed
template searches, write protection, and invalid lifecycle operations are converted to
`error_condition` inside `execute`. Zig error unions remain reserved for unexpected infrastructure or
programming failures that cannot be represented as an execution outcome.

- `none`:
  - No additional simulation work is required after CPU execution.
  - The instruction may still have changed CPU registers, stack state, flags, the instruction pointer,
    or soup memory.
- `mal_request: size`:
  - Request a daughter-cell allocation of `size` instructions, normally taken from `cpu.cx`.
  - Reject the request if the creature already owns a daughter allocation.
  - On success, assign ownership of the allocation to the requesting creature, store it in
    `creature.daughter_alloc`, and place its starting address in `cpu.ax`.
  - On failure, set the CPU error flag and process the outcome as an `error_condition`.
- `divide: daughter_alloc`:
  - Reject division when the creature has no valid daughter allocation.
  - Remove the mother's write privileges over the daughter allocation and clear
    `mother.daughter_alloc`, allowing the mother to request another daughter cell later.
  - Create a new creature and CPU whose mother allocation is the former daughter allocation, and set
    the daughter's initial instruction pointer.
  - Insert the daughter into the slicer queue immediately ahead of its mother and at the bottom of the
    reaper queue.
  - Update population, genotype, lineage, and replication statistics.
- `error_condition`:
  - The CPU sets `fl = 1` when it detects the failed instruction.
  - Increment `creature.errors` and attempt to move the creature one position toward the top of the
    reaper queue, subject to the queue's error-count ordering constraint.
- `hard_instruction_success`:
  - Clear the CPU error flag as appropriate for the successful instruction.
  - Attempt to move the creature one position toward the bottom of the reaper queue, subject to the
    queue's error-count ordering constraint.
  - The original paper says that two difficult instructions receive this treatment but does not name
    them in its prose; verify their identities against the original simulator before fixing this result
    to particular opcodes.

**Tests:**

- Inoculation creates one creature with correct genome
- Ancestor self-replicates far enough to create a second creature
- Reaper triggers when memory fills
- Integration test: run for N instructions and verify population changes

Useful Ziglings: exercises on linked lists or pointer-like data structures, allocator-backed containers,
and testing.

---

### Phase 4: Evolution & Lineage

Goal: add mutation, genotype tracking, statistics, and birth/death/replication event recording.

#### Mutation Engine (`src/sim/mutation.zig`)

**Contents:**

- `MutationConfig`:
  - `cosmic_rate: u32`
  - `copy_error_rate: u32`
  - `flaw_rate: u32`
  - RNG state
- `cosmicRay(soup: *Soup)`
- `maybeCopyError(instruction: u8) u8`
- `maybeFlawResult(value: u16) u16`
- Use Zig's `std.Random` with deterministic startup seed

**Integration points:**

- Background mutation from the main loop every `cosmic_rate` instructions
- Copy error in the `mov_iab` execution path
- Execution flaw in arithmetic/bit-flip instruction handlers

**Tests:**

- Cosmic ray modifies exactly one low-5-bit position
- Copy errors only flip bit positions `0..4`
- Copy errors return canonical `0x00..0x1f` instruction bytes
- Flaw magnitude is only +/- 1
- Deterministic tests with fixed seed

#### Genebank & Statistics (`src/sim/genebank.zig`)

**Contents:**

- `GenotypeId` — size + 3-letter code, e.g. `0080aaa`
- `GenotypeRecord`:
  - name and parent name
  - origin time
  - metabolic data
  - environmental params at origin
  - `breeds_true: bool`
  - `max_prop_pop, max_prop_inst: f32`
- `Genebank`:
  - genotype hash map
  - `register(genome: []const u8, parent: ?GenotypeId, metadata) GenotypeId`
  - `lookup(id: GenotypeId) ?GenotypeRecord`
  - `nameForSize(size: usize) GenotypeName`
- `Stats`:
  - `inst_exec_c: u64`
  - `population: u32`
  - `free_memory: u16`
  - size-class histogram

**Tests:**

- Genotype naming convention
- Registration and lookup
- Stats accumulation

#### Lineage Tracking (`src/persistence/lineage.zig`)

Records every organism birth, death, and first replication as an append-only JSONL event log.

**Contents:**

- `LineageEvent` tagged union:
  - `.birth { parent_id: ?CreatureId, child_id: CreatureId, genotype_id: GenotypeId, time: u64 }`
  - `.death { creature_id: CreatureId, time: u64, cause: DeathCause }`
  - `.first_replication { creature_id: CreatureId, genotype_id: GenotypeId, time: u64 }`
- `DeathCause` enum: `reaped`, `error_limit`
- `LineageWriter`:
  - ring buffer of events
  - background thread flushing to `output/<run_id>/lineage.jsonl`
  - `record(event: LineageEvent)`
  - `flush()` / `deinit()`

**Integration points:**

- Creature birth from `divide`
- Creature death from reaper/error paths
- First replication and breeds-true updates

**Tests:**

- Event serialization round-trip
- JSONL formatting correctness
- Simulation run writes birth/death events with correct parent-child relationships

Useful Ziglings: exercises on random numbers, tagged unions, JSON/string formatting, and allocators.

---

### Phase 5: Snapshots & Persistence

Goal: make simulation state observable over time and resumable.

#### Periodic Snapshots (`src/persistence/snapshot.zig`)

**Contents:**

- `SnapshotWriter`
  - interval from `config.snapshot_interval`
  - writes to `output/<run_id>/snapshots/<inst_count>.json`
  - captures population, genotype census, top genotypes, free memory, and instruction counter
  - background writer thread
- `takeSnapshot(sim: *const Simulation) SnapshotData`

**Tests:**

- Run for N instructions and verify files are written at expected intervals
- Snapshot data matches simulation state

#### Save/Load State (`src/persistence/state.zig`)

**Contents:**

- `save(sim: *const Simulation, path: []const u8) !void`
- `load(allocator: Allocator, path: []const u8) !Simulation`
- Use `std.json.stringify` for output and `std.json.parseFromSlice` for loading

**Tests:**

- Save simulation, load into a new instance, verify state matches
- Continue running after load

Useful Ziglings: exercises on file I/O, JSON, allocators, and error cleanup.

---

### Phase 6: Visualization

Goal: add an optional notcurses display without changing the simulation core.

#### Build Configuration (`build.zig`)

The basic build/test/run wiring can stay minimal until the display layer needs C interop.

**Contents:**

- Link notcurses-core as a system library and link libc:
  ```zig
  exe.linkSystemLibrary("notcurses-core");
  exe.linkLibC();
  ```
- Add a display integration test step:
  - `zig build test-integration` — run tests that require notcurses installed
- Keep normal commands available:
  - `zig build`
  - `zig build run`
  - `zig build test`

#### Notcurses Wrapper (`src/display/notcurses.zig`)

**Contents:**

- `@cImport` + `pub usingnamespace` re-export:
  ```zig
  const c = @cImport({
      @cDefine("_XOPEN_SOURCE", "700");
      @cInclude("notcurses/notcurses.h");
  });
  pub usingnamespace c;
  ```
- Default C struct initializer helpers
- `err(code: c_int) !void` for negative C return codes

#### Display Orchestration (`src/display/display.zig`)

**Contents:**

- `Display` struct:
  - `ctx: *nc.notcurses`
  - `stdplane: *nc.ncplane`
  - dedicated planes for each view
- `init() !Display`
- `deinit()`
- `render(sim: *const Simulation)`
- `pollInput() ?InputEvent`

#### Views (`src/display/`)

**Contents:**

- `soup_view.zig` — color-coded soup map
- `stats_view.zig` — population, diversity, instruction count, free memory
- `creature_view.zig` — selected creature registers and genome
- `size_histogram.zig` — size-class distribution bar chart

**Tests:**

- Display module compiles and links against notcurses
- Init/deinit without crash
- View rendering functions produce expected plane contents, preferably against a mock plane

**Prerequisite:** the `notcurses-core` package must be installed on the system, for example
`apt install libnotcurses-dev` or equivalent.

Useful Ziglings: exercises on C interop, optionals, and error handling.

---

### Phase 7: Polish

Goal: make the simulation convenient to run and tune.

#### CLI (`src/main.zig`)

**Contents:**

- Show the active config at startup
- Headless/display selection based on `config.display_enabled`
- Run length / max instruction argument
- Output directory/run ID handling

#### Performance

**Contents:**

- Profile the hot loop after correctness tests pass
- Optimize soup allocation scans, queue updates, and instruction dispatch only where measurement shows a
  real problem
- Keep compile-time specialization for fixed storage shape and template limits

---

## File Layout

```
zierra/
├── build.zig
├── build.zig.zon
├── src/
│   ├── config.zon               # Compile-time defaults imported with @import
│   ├── main.zig                 # CLI entry point, arg parsing, run loop
│   ├── root.zig                 # Library root (public API re-exports)
│   ├── core/
│   │   ├── instruction.zig      # Instruction enum, encode/decode, complement
│   │   ├── soup.zig             # Memory arena, allocation, ownership
│   │   ├── cpu.zig              # CPU state, per-instruction execution
│   │   ├── template.zig         # Template pattern search algorithms
│   │   ├── creature.zig         # Creature struct and lifecycle
│   │   └── config.zig           # Config type and config.zon import
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

The address type is intentionally fixed at `u16` while the soup is capped at `u16` capacity. This keeps
the Tierra-like memory model explicit and lets wrap-around arithmetic stay simple.

### Instruction → Soup

The soup stores raw `u8` values. Only instruction.zig knows how to interpret them.

```
Soup.read(addr) → u8          -- raw byte from soup
instruction.decode(u8) → Instruction   
instruction.encode(Instruction) → u8 
```

The soup never decodes instructions itself. It is an opaque byte store. However, code that creates,
copies, mutates, or serializes genotypes should treat only the low 5 bits as meaningful Tierra
instruction data. This preserves the paper's model of 60,000 byte-addressed instructions while keeping
the mutational surface at 300,000 bits.

### Soup → CPU

The CPU reads and writes the soup during execution. These are the calls the CPU makes:

```
soup.read(addr: u16) → u8                              -- fetch instruction or data (wraps around)
soup.write(addr: u16, val: u8, writer_id: CreatureId) → !void  -- write with ownership check
    errors: error.WriteProtected (cell not owned by writer_id)
```

The CPU calls `soup.read(cpu.ip)` to fetch the current instruction, then `instruction.decode()` to get the instruction value.

### Soup → Creature (memory lifecycle)

```
soup.allocate(size: u16) → ?Allocation    -- returns null if no contiguous block found
soup.free(alloc: Allocation) → void -- releases ownership of all cells in block
soup.inoculate(code: []const u8, addr: u16, owner: CreatureId) → !Allocation
    -- writes code into soup at addr, sets ownership for owner, and returns the seeded allocation
```

`Allocation` is the handle stored by `Creature` in `mother_alloc` and `daughter_alloc`. The concrete
soup type is `Soup(comptime size)`, so allocation scans operate over fixed-size arrays.

`Soup.inoculate` does not create a creature id or register the creature with any queue. It is a low-level
seeding helper used by `Simulation.inoculate`, which creates the initial creature, calls
`soup.inoculate`, stores the returned `Allocation` on that creature, and enqueues it for scheduling.

### CPU → Template Search

Template search is called by the CPU for `jmp`, `jmpb`, `call`, `adr`, `adrb`, `adrf`. The CPU passes the soup and its current position; template.zig reads the soup to find patterns.

```
template.searchForward(soup: *const Soup, start: u16, limit: u16) → ?u16
template.searchBackward(soup: *const Soup, start: u16, limit: u16) → ?u16
template.searchBidirectional(soup: *const Soup, start: u16, limit: u16) → ?u16
```

**Input contract:**

- `start` points to the instruction *after* the addressing instruction (i.e., the first NOP of the template)
- `limit` is `config.search_limit` — max distance to search
- The function reads NOPs starting at `start` to build the template pattern, then searches for the complement

**Output contract:**

- Returns the address of the instruction *after* the end of the matched complementary template (i.e., where execution should resume)
- Returns `null` if no complementary template is found within `limit`

**On null return**, the calling CPU instruction sets `cpu.fl = 1` and the instruction is skipped (IP advances past the template NOPs).

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

Certain instructions have side effects beyond the CPU and soup. The CPU signals these via a returned action enum rather than calling the simulation directly (keeps CPU decoupled from lifecycle management):

```zig
const ExecResult = union(enum) {
    none,
    divide: Allocation,                  // Memory block for the new creature
    mal_request: u16,                    // Requested allocation size (from cx register)
    error_condition,                     // An instruction generated an error flag
    hard_instruction_success,            // Successfully executed a "hard" instruction (adr/mal)
};
```

`execute` and `step` return `ExecResult`. A `.none` result means execution completed without requiring
simulation-level work; it does not mean that the instruction had no CPU-local effects. Expected virtual
machine faults return `.error_condition` rather than escaping through a Zig error union.

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
    -- picks random address, flips one random low-5-bit genetic bit in that byte

// 2. Copy error — called from mov_iab execution path
mutation.maybeCopyError(val: u8) → u8
    -- with probability 1/copy_error_rate, flips one random low-5-bit genetic bit
    -- otherwise returns val unchanged

// 3. Execution flaw — called from arithmetic/bit-flip instruction handlers
mutation.maybeFlawResult(val: u16) → u16
    -- with probability 1/flaw_rate, returns val ± 1
    -- otherwise returns val unchanged
    -- disabled when flaw_rate == 0
```

The mutation engine owns its own RNG state, seeded from `config.rng_seed`. It never reads or modifies
simulation state beyond the specific value passed in.

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

The simulation calls `takeSnapshot()` every `config.snapshot_interval` instructions and hands the
`SnapshotData` to a background writer thread.

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

`Config` is known at compile time and determines both concrete storage types and behavior knobs. It is
derived from `src/config.zon` through `@import`:

```
const cfg = config.config;
const Sim = Simulation(cfg);
Sim.init() → Sim
    -- Instantiates Soup(cfg.soup_size) with in-struct arrays
    -- Passes mutation rates to MutationEngine.init()
    -- Specializes CPU/template search with cfg.search_limit
    -- Passes cfg.slicer_power to SlicerQueue
    -- Passes cfg.reaper_threshold for memory pressure check
    -- Passes cfg.snapshot_interval to SnapshotWriter
    -- Passes cfg.rng_seed to MutationEngine and any other RNG consumers
```

No module modifies `Config` after startup. It is effectively immutable for the lifetime of the
simulation; changing it means editing `src/config.zon` and rebuilding.

---

## Testing Strategy

Every module includes `test` blocks at the bottom of the file. Tests fall into three tiers:

1. **Unit tests** (per-module, no external dependencies):
  - Instruction encoding, CPU arithmetic, stack behavior
  - Soup allocation, ownership enforcement
  - Template search correctness
  - Queue ordering (slicer, reaper)
  - Mutation determinism with fixed seeds
  - Config: import `.zon`, default values match expectations, invalid values fail validation
  - Config validation: comptime validation for fixed-size simulation shapes
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
| Instruction storage  | `u8` soup cells with low 5 bits used                                                                              | Matches Tierra's byte-addressed soup while preserving the 32-instruction genetic alphabet                            |
| Mutation bit range   | Only bit positions `0..4` of each instruction byte                                                                | Matches the paper's 60,000 instructions totaling 300,000 mutable bits                                                |
| Soup addressing      | `u16`                                                                                                             | Supports up to 64K soups; matches the paper's ~60K default and keeps memory compact                                  |
| Soup storage         | `Soup(comptime size)` with `[size]u8` and `[size]?CreatureId`                                                     | Moves arena shape and capacity to compile time; no allocator required for the core memory soup                       |
| Config               | One `Config` object from `src/config.zon` imported with `@import`                                                 | Keeps shape and behavior values in one source of truth; changing config means rebuilding                             |
| Creature storage     | ArrayList + free list                                                                                             | O(1) access by ID; IDs are indices                                                                                   |
| Queue implementation | Intrusive doubly-linked list                                                                                      | O(1) insert/remove/reorder for slicer and reaper                                                                     |
| RNG                  | `std.Random.Xoshiro256`                                                                                           | Fast, good statistical properties, seedable                                                                          |
| Display binding      | `@cImport` + `pub usingnamespace` re-export, thin `err()`/default wrappers, `linkSystemLibrary("notcurses-core")` | Zero-cost FFI; single wrapper module re-exports all C symbols with Zig-friendly error conversion and struct defaults |
| Lineage tracking     | Append-only JSONL event log, background thread flush                                                              | Streamable, greppable, reconstructable into phylogenetic trees; async avoids simulation stalls                       |
| Snapshot interval    | Configurable via `config.snapshot_interval`                                                                       | Lets user trade disk space for temporal resolution                                                                   |
| Error handling       | Zig error unions                                                                                                  | Natural fit; CPU faults map to error returns                                                                         |
