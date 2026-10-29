# Zierra: High-Level Implementation Plan

This project teaches Zig 0.16.0 by building a Tierra simulation in small, testable steps.
The plan describes goals, contracts, and exercises; implementation remains the learner's work.
Work through one checkpoint at a time, predict its behavior, and write a small test before
connecting it to the next module.

## How to Use This Plan

- Checked items describe existing foundations, not a promise that an entire phase is finished.
  New acceptance criteria remain unchecked until implemented and verified. Phases 4–7
  describe future work; their modules and feature flags are not yet wired into execution.
- Existing names below follow the code. Proposed modules describe intended boundaries;
  keep their behavior consistent with the contracts below as they are introduced.
- Establish mutation-free ancestor replication before adding evolution, persistence, or display.
- Prefer a small working program over infrastructure built in anticipation of later phases.
  Each phase ends with an observable result, which can initially be a test or textual trace.
- The local paper is the source for Tierra behavior. Where it does not specify an edge case,
  this plan labels the behavior as a Zierra convention instead of claiming historical fidelity.

### References and Version Checks

- [Tierra paper](../reference/tierra_paper.tex): operating-system sections for memory,
  scheduling, reaping, and mutation; Appendix B for opcodes; Appendix C for the ancestor.
- [Zig language reference](../reference/langref.html.in) and [standard library](../reference/std/):
  documentation only; never modify this directory.
- Confirm the compiler with `zig version`. If an API differs from the local reference,
  inspect the standard library installed with Zig 0.16.0, located through `zig env`.
- Ziglings exercises below are concept practice. This checkout includes examples written
  for older Zig versions; adapt API usage to 0.16.0.

### Current Implementation and Next Checkpoint

The deterministic core is implemented and tested:

- `src/config.zig` validates `src/config.zon` at compile time and exports typed constants.
- Soup stores `[size]Instruction`, where `Instruction` is an `enum(u8)` with 32 values.
  Ownership is separate, and CPU execution consumes instructions directly.
- CPU execution and template searches support the full instruction set. Creatures have
  optional daughter allocations, persistent organism identities, and saturating counters.
- Simulation initialization, inoculation, allocation/division/death, scheduling/reaping,
  and bounded execution are present. Tests include ancestor self-examination and two
  generations of identical replication, plus equivalent split and uninterrupted runs.
- `src/root.zig` exports `Simulation` and `ancestor_genome` and imports the simulation
  into the core test graph.

The executable checkpoint is implemented: `main` prints configuration, initializes static
simulation storage, inoculates the ancestor at address zero, and calls `run` with a
20,000-instruction budget.
Low-level soup validation gaps remain listed in Phase 1; lifecycle validation does not
mean every soup helper independently provides the same guarantees.

Mutation, genebank/statistics, persistence, and display modules are planned. `GenotypeId`
formatting and the nullable `parent_genotype` field exist, but births currently set that
field to null and no genotype registration occurs. Nonzero mutation rates and enabled
lineage/display flags in the production configuration do not activate these features yet.

---

## Architecture Overview

The simulation has these conceptual layers:

```text
main / future CLI
    Simulation: lifecycle, counters, scheduling
        Soup: instructions, ownership, allocation
        Creature: CPU state, allocations, identity, counters
        CPU: fetch, execute, report ExecResult
        Template search + instruction definitions
    Planned: mutation integration, genebank and statistics
    Planned persistence: lineage, summaries, checkpoints
    Planned optional display: notcurses
```

Keep the simulation single-threaded initially. The CPU does not import the scheduler,
genebank, display, or simulation. A returned execution outcome lets the simulation
complete lifecycle operations before another instruction executes.

### Compile-Time Shape and Runtime State

Use compile-time parameters for capacities, stack depth, instruction definitions,
ancestor instructions, and optional features. Keep mutable soup contents, ownership,
creatures, queues, RNG state, and statistics at runtime.
Runtime mutation does not itself require a host allocator: bounded state can live in
fixed arrays whose capacities are known at compile time.

Production configuration comes from `src/config.zig`, which imports `src/config.zon`,
validates a typed configuration, and exports its fields as constants. `Simulation(config)`
accepts that imported module or a small test configuration. Changing production values
means rebuilding.

The existing factories are `Soup(size)`, `CPU(stack_depth, search_limit)`,
`Creature(CpuType)`, `Scheduler(CreatureType)`, and `Simulation(config)`.
Do not generalize every module before its needs are understood. A compile-time limit
bounds runtime work; it does not require unrolling loops or evaluating the simulation
at compile time.

Fixed arrays specify layout, not where an instance lives. A full simulation can be large;
choose its storage deliberately rather than assuming returning it by value or putting
multiple instances on the stack is free. Once queues or RNG interfaces hold internal
pointers, initialize the object in its final location and avoid moving it.
Use caller-provided storage and in-place initialization for Phase 3. Put the production
instance in static storage and small test instances in local storage. The simulation
and its creatures use no host allocator in this phase.

---

## Shared Behavioral Contracts

These rules describe the implemented core and requirements for its planned extensions.
The phase checklists identify unfinished work; future contracts are not completion claims.

### Memory, Addresses, and Arithmetic

- Soup stores one `Instruction` per cell. Its `enum(u8)` values are `0x00..0x1f`;
  CPU execution consumes the enum directly. Future mutation must preserve valid values,
  and persistence must validate external opcode values before creating instructions.
- Every soup cell has an instruction, including unowned cells. Simulation initialization
  fills the soup with seeded random instructions. Tiny tests may use a deterministic
  fill. Ownership determines whether memory is allocated.
- Freeing memory removes ownership and preserves its instructions, as described by the paper.
  Allocating reserves ownership without clearing old code.
- Read and execute privileges are unrestricted. A creature may write only cells owned
  by its current slot ID: its mother allocation and, before division, its daughter allocation.
  Cosmic rays are a separate privileged operation that can affect any soup cell.
- CPU instruction-pointer updates, template traversal, and register-derived memory
  accesses wrap modulo soup length. CPU fetch reads the current IP directly, so lifecycle
  initialization and IP updates must keep it valid. Low-level soup reads/writes require
  an already valid address; they do not implement wrapping.
- Allocations are linear contiguous ranges and never cross the end of the array.
  An allocation is valid when `len > 0`, `start < soup_size`, and
  `len <= soup_size - start`. Check this before indexing or changing state.
- Addresses and allocation lengths use `u16`. The current `Soup(size)` guard accepts
  capacities from 1 through 65534; it also rejects 65535, although that value fits the type.
  `CPU` applies the same restriction to stack depth. Use `usize` or a wider integer
  for intermediate range arithmetic when needed, and validate before narrowing.
- Registers are 16-bit bit patterns. Define addition/subtraction as wrapping modulo
  65536 and shifts as discarding bits beyond the register width. Normalize a register
  modulo soup length when using it as an address. These are different operations:
  register arithmetic must not accidentally wrap modulo soup length.
- Creature instruction/copy counters use saturating `u64` increments; errors use
  saturating `u32` increments. `origin_time` and global instruction time use `u64`.
  Global-time exhaustion returns `InstructionLimitReached` before executing another
  instruction. Organism identity exhaustion rejects a birth instead of wrapping.

Zierra's fixed-width registers and circular execution are explicit project conventions.
The paper's C `int` register fields do not by themselves establish 16-bit arithmetic.

### Ownership and Allocation Failure

`Soup.allocate(request_size, requester)` assigns ownership to a slot and returns an
`Allocation` or `SoupError`. Existing soup errors are `PermissionError`, `NoFreeSoup`,
and `InvalidAllocation`.

- Reject zero-size and oversized requests. Search all valid runs, including one ending
  at the final cell and one occupying the entire soup.
- Insufficient contiguous space is a normal virtual-machine failure, even when total
  free memory is sufficient. The initial allocator uses deterministic first-fit scans.
- Lifecycle methods validate ranges before inoculation, death, or division.
  Rejected lifecycle requests preserve allocations, slots, identities, and occupied
  memory; their VM error flag, error count, and possible reaper movement still apply.
- `Simulation.kill` validates the live creature pointer and expected owners before
  freeing; `divide` checks daughter ownership before transfer. `Soup.free` has no
  expected-owner parameter, and its range checks are incomplete. Keep live handles
  under lifecycle management; low-level validation work remains open in Phase 1.
- On division, ownership changes from the mother's slot to the daughter's slot.
  On death, release both the mother allocation and any gestating daughter allocation.

### Identity, Storage, and Queue Lifetimes

`slot_id: u16` is the reusable index used by soup ownership and in-memory lookup.
A separate monotonically increasing `organism_id: u64` identifies a birth for future
lineage and saved output. Slot reuse must never merge two organisms' histories.

The simulation embeds `[config.soup_size]?CreatureType`; null denotes a free slot.
`free_slots` is an `ArrayList(u16)` backed by `free_slots_buffer`, initialized with
`initBuffer` and operated without a host allocator. Every live creature owns at least
one soup cell, so soup capacity bounds the number of simultaneous creatures.
Fresh slots are acquired in ascending order; released slots are pushed for immediate
reuse. Preserve the exact free-slot order across save/load, and never read null payloads.

An `ArrayList(Creature)` that reallocates is incompatible with intrusive queue pointers.
Do not compact or swap-remove live creatures if their indices identify ownership.
Bound simultaneous slots by soup capacity and handle slot exhaustion as an explicit
resource failure.

Each live creature belongs to both queues exactly once, with separate link nodes.
Remove it from both before marking its slot free. Reinitialize both nodes before slot
reuse. The enclosing simulation must also stay in place while pointers refer into it.
A cached display selection must validate the organism identity when a slot is reused.

### CPU Outcomes, Flags, and Counters

`ExecResult` is the existing tagged union with one active variant:

| Outcome | Meaning |
| --- | --- |
| `none` | CPU-local work finished; no lifecycle request |
| `mal_request(size)` | Simulation must allocate a daughter block |
| `divide` | Payload-free request; simulation must validate and complete division for the executing creature |
| `error_condition` | Expected VM fault; record one error |
| `hard_instruction_success` | Apply the scheduler's hard-instruction reward |

`CPU.step` fetches an `Instruction`, dispatches through `execute`, and increments the
creature's executed counter once. Execution handlers own every instruction-pointer
update, including failures and requests. `step` must not increment IP again.

`Simulation.step` increments global instruction time once, dispatches `ExecResult`,
then consumes one unit of `slice_remaining`. At slice end it advances the slicer and
reaps while `occupied_cells > occupied_limit`. A failed allocation or division uses
the same error-accounting path as a CPU fault, exactly once.

Phase 4 adds cosmic mutation after outcome handling and before slice-end work;
observations in later phases see the completed instruction and any resulting reaping.
Births during execution use the updated instruction time. Inoculation uses the current
time, which is zero for the initial ancestor.

Clear `fl` at the beginning of each instruction; failures set it to 1. Successful
lifecycle completion leaves it at 0. Reading genebank/display state must not change it.
This makes `fl` describe the most recently completed instruction rather than a stale
earlier fault.

A successful `mov_iab` increments the copy counter once. Failed writes do not count
as copies. Template operand cells and skipped instructions do not count as executions.

Expected VM faults are outcomes; allocator/I/O failures in host infrastructure use
Zig error unions and cleanup paths. Do not turn an out-of-memory error from the host
allocator into an unnoticed Tierran mutation or instruction failure.

### Template Search

Template extraction and complementary search have separate limits and failure meanings.

- The operand begins at the cell after an addressing instruction. It is the consecutive
  run of `nop_0`/`nop_1` cells there.
- Extraction traverses at most one soup length. An all-NOP soup must terminate with an
  invalid-operand result. An invalid operand is distinct from an empty operand.
- Initially no extra configurable template-length cap is needed. If one is added later,
  exceeding it must not silently truncate the operand or turn it into an empty template.
  In particular, `search_limit / 2` is not a template-length definition.
- Complement swaps `nop_0` with `nop_1` at every position. Candidates are always
  read in forward order, even when candidate starts are searched backward.
- With operand start `s` and length `n`, the first forward candidate starts at
  `s + n`; the first backward candidate starts at `s - n - 1`, modulo soup size.
  Subsequent candidates move one cell in their respective direction.
- Exclude any candidate whose cells overlap the addressing instruction or its operand,
  including after wrapping around. A match elsewhere inside the same creature is legal.
- `search_limit` bounds candidate rounds per direction; zero means no search.
  Cap scanning at one soup traversal. Rejected candidates still consume a round.
- Bidirectional search compares both directions in each round and takes the first
  match; equal-round ties prefer forward. This is a Zierra convention for a detail
  the paper's prose leaves unspecified.
- A successful search returns the address immediately after the matched template.
  A failed instruction advances past its own full operand, sets `fl`, and reports
  one execution error.
- `pattern_length_at` returns zero for an empty operand, a positive length for a valid
  operand, and null for an invalid operand. Search helpers return null for no match;
  CPU handlers distinguish the empty case before treating a search as failed.

### Mutation Units and Reproducibility

The fields and derived-interval validation exist; mutation execution does not.
Phase 4 retains the following planned Zierra units:

| Field | Meaning |
| --- | --- |
| `cosmic_rate` | Mean executed global instructions per cosmic event; 0 disables |
| `copy_error_rate` | Mean successful instruction copies per copy mutation; 0 disables |
| `flaw_rate` | Floating-point multiplier of the copy interval; 0 disables flaws |

For Zierra's initial model, each eligible opportunity is an independent trial:
probability `1 / cosmic_rate` after an executed instruction and
`1 / copy_error_rate` for a permitted copy. Flaws use probability `1 / interval`
per eligible arithmetic/bit execution, where
`interval = max(1, ceil(copy_error_rate * flaw_rate))`.
Disable flaws when either input is zero. An interval of 1 means every opportunity.
Thus `flaw_rate = 1.5` is a multiplier, not a 2/3 probability per instruction.

This independent-trial model avoids fixed periodic events. The paper describes randomized
intervals and generation-relative rates; these project units are a simplification, not
an exact reproduction of its experimental parameterization.

Soup initialization currently uses a local `std.Random.Xoshiro256` seeded directly
from `rng_seed`, then discards it. Keep that initialization independent of future
cosmic, copy, and flaw streams. Add those streams in Phase 4, recording their seed
derivation and call order. Rendering, logging, and statistics must not consume them.

Keep future mutation RNG state at a stable address and retain its full state for
save/load. A seed alone cannot resume a run midway through its random sequence.

---

## Linear Implementation Plan

### Phase 1: Compile-Time Shape

Goal: establish configuration, instruction representation, soup storage, and CPU state.

#### Configuration (`src/config.zon`, `src/config.zig`)

- [x] A project-wide `src/config.zon` exists.
- [x] Add a typed config and compile-time validation.
- [x] Specialize factories from compile-time configuration, including small test configs.
- [x] Verify importing the config and rebuilding selects the intended concrete types.

Current production values, to keep distinct from experimental/test configurations:

| Field | Type | Value |
| --- | --- | --- |
| `soup_size` | `u16` | 60000 |
| `stack_depth` | `u16` | 10 |
| `search_limit` | `u16` | 300 |
| `lineage_enabled` | `bool` | true |
| `display_enabled` | `bool` | true |
| `reaper_threshold` | `f32` | 0.8 |
| `cosmic_rate` | `u32` | 10000 |
| `copy_error_rate` | `u32` | 1000 |
| `flaw_rate` | `f32` | 1.5 |
| `slicer_power` | `f32` | 1.0 |
| `snapshot_interval` | `u64` | 100000 |
| `output_dir` | `[]const u8` | "output" |
| `rng_seed` | `u64` | 8675309 |

Validation requires positive soup size and stack depth, finite floats, a reaper threshold
strictly between 0 and 1, nonnegative flaw multiplier, and nonnegative slicer power.
It also checks that the derived flaw interval is finite and fits `u32`.
The soup/CPU factories impose the additional upper bounds documented above.
Search limit zero is valid and causes searches to fail. Phase 5 will interpret zero
snapshot interval as disabled; snapshot scheduling is not implemented yet.

These are Zierra defaults. Do not test that every field matches a universal “original
Tierra default”; several are project choices or values from one experiment.

#### Instruction Set (`src/core/instruction.zig`)

- [x] All 32 opcodes are represented by `Instruction`, an `enum(u8)`.
- [x] NOP recognition and complementary-NOP helpers exist.
- [x] Opcode ordering matches Appendix B; CPU tests cover the specified register effects.

#### Soup / Memory (`src/core/soup.zig`)

- [x] Compile-time `Soup(size)`, ownership, allocation, and inoculation foundations exist.
- [x] Store `[size]Instruction` memory plus `[size]?u16` ownership.
- [x] Enforce write ownership and find exact-fit first-fit allocations, including at the end.
- [x] Reject zero capacity; current accepted capacities are 1 through 65534.
- [x] Keep soup independent of CPU execution and queue management.
- [ ] Complete low-level `free`/`inoculate` range validation and boundary tests.
  Their current checks do not cover every empty, invalid-start, or over-end range.

Retain exact-fit, permission, and allocation/free tests. Add direct low-level tests for
invalid ranges and unchanged state on failure, using wider range arithmetic before
indexing. Simulation-level tests already cover rejected lifecycle requests; they do not
replace tests of these helpers. Test wrapping in address helpers rather than soup reads.

#### CPU State (`src/core/cpu.zig`)

- [x] Registers, a compile-time-sized stack, defaults, and push/pop foundations exist.
- [x] Stack overflow/underflow and a push/pop round trip have tests.
- [x] Confirm failed stack operations preserve stack contents and pointer position.
- [x] Keep stack capacity and stack-pointer types consistent.

A CPU contains `ax`, `bx`, `cx`, `dx`, `fl`, `sp`, the stack, and `ip`.
No full executor is needed to complete this checkpoint.

Learning checkpoint: explain why capacity is known at compile time while ownership
changes at runtime, and why a stack error need not crash the simulation.

Useful Ziglings:
[035_enums](../ziglings/exercises/035_enums.zig),
[037_structs](../ziglings/exercises/037_structs.zig),
[045_optionals](../ziglings/exercises/045_optionals.zig),
[021_errors](../ziglings/exercises/021_errors.zig),
[066_comptime](../ziglings/exercises/066_comptime.zig), and
[102_testing](../ziglings/exercises/102_testing.zig).

### Phase 2: Execution Engine

Goal: run one creature deterministically, without lifecycle creation or mutations.

#### Template Search (`src/core/template.zig`)

- [x] Forward, backward, bidirectional search, and address-wrap helpers exist.
- [x] Existing tests cover basic searches and boundary wrapping.
- [x] Separate extraction from searching and align with the shared template contract.
- [x] Test equal-distance matches, zero search limit, all-NOP soup, operand overlap after
  wrapping, and invalid versus empty operands.
- [x] Verify skipping a template uses its full length, independently of search distance.

#### CPU Execution (`src/core/cpu.zig`)

Arithmetic/register operations, stack operations, conditional skips, jumps/calls/returns,
addressing, copying, and lifecycle requests are implemented and tested. Mutation hooks
are future work in Phase 4.

```text
CPU.step:
    fetch an Instruction at the current valid instruction pointer
    execute it, clearing the prior flag and updating IP in its handler
    saturating-increment the creature's executed counter once
    return its outcome
```

Every cell contains an instruction, including unowned cells. There is no empty-cell
fetch branch. Simulation outcome handling and slice boundaries follow the shared contract.

| Instruction group | Established behavior |
| --- | --- |
| Plain arithmetic/register ops | Apply Appendix B's effect using defined 16-bit arithmetic; advance IP once |
| Stack ops | On failure, preserve the destination/stack state, advance IP, report an error |
| `if_cz` | If `cx == 0`, next step executes the next instruction; otherwise skip it, including its inline template if present |
| `jmp` / `jmpb` | Search bidirectionally/backward; land after the complementary template |
| `call` / `ret` | Push the address after the caller's operand only after a successful search; return to a popped, normalized address |
| `adr` / `adrb` / `adrf` | Search bidirectionally/backward/forward; store match-end address in `ax` and operand length in `cx`; advance past own operand |
| `mov_iab` | Copy one instruction from `[bx]` to `[ax]`, enforcing ownership; leave `ax` and `bx` unchanged |
| `mal` | Advance IP and request allocation of `cx` cells |
| `divide` | Advance IP and return a payload-free division request, or report an error when no daughter allocation exists |

Appendix C's copy loop executes `inc_a` and `inc_b` separately. Incrementing them
inside `mov_iab` would skip every other instruction and break the ancestor.
The ancestor also uses the template length in `cx` when calculating its own extent;
addressing must preserve that interface.

A skipped instruction has no effects on registers, flags, stack, counters, or ownership.
On failed search, leave address-result registers unchanged. On call stack overflow,
do not jump, and continue after the caller's operand.

For empty operands, retain these explicit Zierra conventions: `jmp`/`jmpb` jump
through normalized `bx`; `call` pushes the next address and continues there;
`adr*` advances once without changing registers. Check the empty case before a
no-match failure. These details are not established by the paper's abbreviated
executor; revisit together if a fuller historical specification is adopted.

Use successful `adr*` and completed `mal` as the initial “hard instruction” reward
policy. The paper describes two difficult instructions without naming them in its prose;
this opcode choice is a Zierra policy pending a fuller specification. A `mal_request`
needs no second simultaneous union variant: the simulation applies its reward after
allocation succeeds.

#### Creature (`src/core/creature.zig`)

- The specialized CPU is embedded directly alongside `slot_id`, `organism_id`,
  `mother_alloc`, optional `daughter_alloc`, `origin_time`, and the shared counters.
- `parent_genotype: ?GenotypeId` is present but not populated by lifecycle methods.
  Phase 4 adds the creature's own birth genotype separately.
- Generic execution parameters connect CPU and creature without duplicating CPU state
  or importing the simulation into the CPU.

Tests cover overflow/underflow in registers, IP movement for every instruction
group, successful/failing copy permissions, unchanged copy address registers, flags,
template skips, `adr*` updating `cx`, call failure atomicity, and single counting
on fault paths.

Learning checkpoint: trace a small copy loop by hand, including every IP change.
Explain which effects belong to CPU execution and which must await the simulation.

Useful Ziglings:
[030_switch](../ziglings/exercises/030_switch.zig),
[039_pointers](../ziglings/exercises/039_pointers.zig),
[033_iferror](../ziglings/exercises/033_iferror.zig),
[055_unions](../ziglings/exercises/055_unions.zig),
[059_integers](../ziglings/exercises/059_integers.zig),
[097_bit_manipulation](../ziglings/exercises/097_bit_manipulation.zig), and
[108_labeled_switch](../ziglings/exercises/108_labeled_switch.zig).

### Phase 3: Lifecycle Management

Goal: make the ancestor reproduce in a mutation-free, headless simulation.

#### Scheduler (`src/sim/scheduler.zig`)

Implemented with tests for round-robin traversal, birth order, cursor removal,
empty/singleton queues, local reaper movements, and membership in both queues.
The queues depend on the stable-storage contract above.

#### Ancestor (`src/sim/ancestor.zig`)

The 80-instruction `0080aaa` genome is transcribed as `[80]Instruction`.

- [x] The transcription matches Appendix C and fits the production soup.
- [x] `src/root.zig` exports `ancestor_genome` for use by the executable.
- [x] Tests trace its self-examination: at base 0, `adrb` finds match-end 4,
  `sub_ac` obtains base 0, `adrf` finds match-end 79, and `inc_a`/`sub_ab`
  calculate size 80, then allocation, copying, and division produce two generations.

#### Simulation (`src/sim/simulation.zig`)

The type factory, in-place initialization, inoculation, allocation/division/death,
instruction stepping, slice-boundary reaping, and bounded `run` entry point are
implemented. Creature identities and widened counters are present, and `src/root.zig`
imports the simulation into the test graph.

The fixed pool, inline free-slot buffer, and local initialization RNG follow the shared
storage contract. Keep the simulation in its final storage while buffer and queue
pointers refer into it. Genebank, persistence, display, and mutation integration belong
to later phases.

Executable checkpoint:

- [x] In `main`, inoculate the ancestor at address zero after initialization and run
      a bounded mutation-free simulation using the existing `init`, `inoculate`, and
      `run` entry points.
      Static production storage is already present; full CLI parsing belongs to Phase 7.

Verified lifecycle behavior:

Tests instantiate small simulations and compare initialized fields and live creature
payloads, not raw struct bytes or unused stack entries. Slot/identity exhaustion tests
construct boundary states directly.

- [x] Empty initialization: valid instructions, no owners, all slots free, empty queues,
      zero counters, next organism ID zero, and the expected floored occupancy limit.
- [x] Equal configs/seeds produce identical initialized instructions.
- [x] Slot acquisition uses ascending fresh IDs; released slots are reused first;
      reused slots receive new organism IDs.
- [x] Inoculation initializes every live field and both queues. Empty, out-of-range,
      occupied, slot-exhausted, and identity-exhausted attempts leave the full state intact.
- [x] Successful allocation reserves cells and rewards once; duplicate, invalid, and
      fragmented requests preserve lifecycle state and record exactly one VM error.
- [x] Division transfers ownership, resets the child's CPU/counters at the updated time,
      preserves the mother's remaining budget, and does not change occupied cells.
      Missing, invalid, overlapping, or wrongly owned daughter handles leave lifecycle
      state intact.
- [x] Death releases mother and gestating daughter memory, preserves code, unlinks both
      queues, and permits slot reuse. Invalid ownership changes nothing.
- [x] Reaping uses a strict greater-than comparison, removes multiple victims when
      required, and handles singleton extinction and removal of the selected next creature.
- [x] CPU faults and failed lifecycle requests increment errors once; every executed
      instruction increments global time once. Global-time exhaustion changes nothing.
- [x] Creature execution/copy counters and accumulated errors saturate without stopping
      instruction execution or global time.
- [x] Slice budgets clamp to at least 1 and at most the maximum `u64`, including
      powers too large to represent as a finite `f64`.
- [x] Empty `step`/`run` execute nothing; zero-budget runs change nothing.
      `run(A + B)` matches `run(A)` followed by `run(B)`, including partial slices and a
      budget ending exactly at a reaping boundary.
- [x] With mutations absent, the ancestor produces an identical 80-instruction daughter, then
      that daughter reproduces. Tests compare ownership, CPU initialization, and queue
      membership as well as genome instructions.

Exit criterion met: core tests pass and `zig build run` completes bounded ancestor
execution. Preserve both when wiring in Phase 4 features.

Useful Ziglings:
[004_arrays](../ziglings/exercises/004_arrays.zig),
[043_pointers5](../ziglings/exercises/043_pointers5.zig),
[045_optionals](../ziglings/exercises/045_optionals.zig),
[047_methods](../ziglings/exercises/047_methods.zig),
[066_comptime](../ziglings/exercises/066_comptime.zig), and
[102_testing](../ziglings/exercises/102_testing.zig).

### Phase 4: Evolution and Lineage

Goal: extend the deterministic core with mutation, then genotype tracking/statistics,
then ordered organism events. Complete the Phase 3 executable checkpoint first.
The module paths in this phase are proposed additions.

#### Mutation (`src/sim/mutation.zig`)

Add one mutation class at a time, retaining the fully disabled deterministic path.

- [ ] Add separate seeded cosmic, copy, and flaw streams in stable simulation storage,
  following the shared units and reproducibility contract. Keep soup initialization
  unchanged and record the mutation streams' seed derivation and draw order.
- [ ] Add cosmic events at the shared post-outcome boundary. Flip one random bit in
  positions `0..4` at any soup address, regardless of ownership, and store a valid
  `Instruction` again.
- [ ] Add copy mutation within `mov_iab`, after destination permission is established
  and before the single write. Denied writes consume no copy randomness and do not
  count as copies. Preserve the source unless it is also the destination.
- [ ] Add execution flaws through a narrow CPU mutation context. Initially restrict
  them to arithmetic/bit operations: perturb arithmetic results by ±1 with wrapping;
  for `or1`, flip no bit or bit 1; for `shl`, shift by 0 or 2 instead of 1.
  This restricted scope is a Zierra simplification of the paper.

Keep `ExecResult`, IP updates, error accounting, and slice scheduling intact. The CPU
must not import the simulation. Disabled mutation rates must consume no mutation draws.
Verify forced events, interval 1, disabled rates, valid enum values, denied copies,
fixed-seed replay, and equivalence of split and uninterrupted instruction budgets.

#### Genebank and Statistics (`src/sim/genebank.zig`)

- [ ] Register genomes at successful inoculation and division, using owned copies of
  the allocation's instructions. Deduplicate by instruction content; if using hashes,
  compare content after a hash match. Register births before the later cosmic event.
- [ ] Reuse `GenotypeId` and its size/three-letter representation. Allocate base-26
  labels per size class (`0080aaa`, `0080aab`, ...); report exhaustion after `zzz`.
  Store the creature's birth genotype separately from `parent_genotype`, which comes
  from the reproducing parent's birth genotype. The initial ancestor has no parent.
- [ ] Track live census by birth genotype, origin time, and actual successful
  replications. Keep first-replication measurements optional until replication occurs;
  use the existing instruction/error/copy counters. Set `breeds_true` when offspring
  instructions equal the parent's stored birth genome.
- [ ] Integrate registration and census updates into the existing lifecycle methods.
  Keep census totals consistent through division, death, and slot reuse; sort reported
  census entries by genotype label for deterministic output.

Birth genotype is historical identity: later cosmic changes to living code do not
reclassify it. The same genotype can arise from different parents; actual organism
parentage belongs in lineage events. Naming each birth genotype immediately is a Zierra
simplification of the paper's replication-qualified genebank policy.

Historical genomes can outlive creatures and accumulate beyond the fixed pool's capacity.
Introduce an explicit host allocator and cleanup lifetime for the genebank. Surface
allocation failures as host errors, preserving lifecycle consistency; do not turn them
into VM faults. Test deduplication, distinct equal-size genomes, label exhaustion,
different parents, breeds-true detection, census updates, and failure cleanup.

#### Lineage (`src/persistence/lineage.zig`)

- [ ] Write synchronous buffered JSONL under the configured output directory and run ID.
  Record initial birth, later parent/child births, first successful replication, and
  reaper deaths. Use `organism_id` for organism identity, alongside genotype IDs,
  global instruction time, and an increasing event sequence.
- [ ] Capture event data while the relevant creature is live, before death releases
  its slot. Preserve lifecycle order for events sharing an instruction time.
  VM faults continue to affect the reaper; they do not introduce a new death policy.
- [ ] Write run metadata with the active configuration, RNG algorithm/seed derivation,
  Zig version, and output format version. Propagate write/flush errors and clean up
  resources on both normal shutdown and failure.
- [ ] Honor `lineage_enabled`: disabling tracing opens no lineage file and changes
  neither simulation randomness nor genebank/census behavior.

Exit criterion: a repeatable headless run exercises mutation and reports consistent
genotypes, census, and ordered lineage. Forced decisions test individual mutation rules;
tests must not require evolution to produce a particular population shape.

Learning checkpoint: distinguish slot identity, organism identity, and birth genotype;
explain why the genebank owns instructions instead of borrowing mutable soup memory.

Useful Ziglings:
[055_unions](../ziglings/exercises/055_unions.zig),
[096_memory_allocation](../ziglings/exercises/096_memory_allocation.zig),
[097_bit_manipulation](../ziglings/exercises/097_bit_manipulation.zig),
[099_formatting](../ziglings/exercises/099_formatting.zig), and
[106_files](../ziglings/exercises/106_files.zig).

### Phase 5: Summaries and Checkpoints

Goal: observe Phase 4 runs and resume them deterministically. Summary snapshots describe
a run; resumable checkpoints preserve its execution state. Both modules below are planned.

#### Periodic Summaries (`src/persistence/snapshot.zig`)

- [ ] Capture summaries every `config.snapshot_interval` global instructions, after
  outcome handling, cosmic mutation, and any slice-boundary reaping. Zero disables.
  Schedule from global time so splitting a run budget does not change capture boundaries.
- [ ] Report time, population, occupied/free memory, birth-genotype census, and size
  histogram in deterministic order. Refer to the run metadata introduced in Phase 4.
- [ ] Write synchronously with buffering. Keep observation read-only and independent
  of RNG; make any retained data's allocation and cleanup lifetime explicit.
  Surface output failures and flush on shutdown.

Verify exact boundaries, disabled summaries, census agreement, split-run equivalence,
and error cleanup before adding resumable state.

#### Save/Load (`src/persistence/state.zig`)

- [ ] Define a versioned data-only format with configuration compatibility information.
  Capture at completed instruction boundaries, including boundaries partway through
  a creature's slice.
- [ ] Preserve all soup instructions, including unowned code; ownership; live creature
  slots, CPU state, allocations, identities, counters, and birth metadata.
  Only initialized stack entries are data.
- [ ] Preserve slicer order/current position and `slice_remaining`, reaper order,
  exact `free_slots.items` order, next organism identity, full mutation RNG states,
  genebank/statistics, and event/observation sequencing state.
- [ ] Load into final storage and rebuild queue links, buffer references, and lookup
  structures. Validate opcode values, ranges, owners, identities, queue membership,
  stack bounds, and configuration compatibility before exposing the instance.
  Release partially constructed state on failure.
- [ ] Write through a temporary file and replace the checkpoint after successful
  write/flush. Resume into a new output run whose metadata identifies the checkpoint.

Do not serialize raw struct memory, pointers, intrusive nodes, allocator internals,
or file handles. A seed alone cannot restore the mutation streams' current states.

Exit criterion: run A+B uninterrupted and compare its logical state with run A,
save/load, then B, including a partial slice and enabled mutations. Compare soup,
ownership, creature/queue state, free-slot order, identities, genebank, counters, and
RNG states. Reject truncated files, invalid state, unsupported versions, and incompatible
configurations without exposing a partial load.

Learning checkpoint: explain why a population count or original seed cannot resume a run.

Useful Ziglings:
[029_errdefer](../ziglings/exercises/029_errdefer.zig),
[096_memory_allocation](../ziglings/exercises/096_memory_allocation.zig),
[106_files](../ziglings/exercises/106_files.zig), and
[107_files2](../ziglings/exercises/107_files2.zig).

### Phase 6: Visualization

Goal: display Phase 4 statistics and live soup state while preserving the headless run.
Display modules and notcurses integration are planned additions.

- [ ] Wire `display_enabled` into build/import decisions for display artifacts, using
  Zig 0.16.0's C interop and linking APIs. Headless builds and core tests must work
  without notcurses. Document its system dependency when adding it.
- [ ] Start with a soup map and basic statistics, then add creature inspection and a
  size histogram. Render read-only state at a throttled rate between completed
  instructions/batches on the simulation thread.
- [ ] Add quit, pause/resume, selection, and single-step input. Single-step completes
  one `Simulation.step`, including its lifecycle and reaping work. Pausing must not
  advance simulation counters or RNG.
- [ ] Handle resizing and extinction; validate selections against both `slot_id` and
  `organism_id` when slots are recycled. Clean up terminal resources on all exit paths.
- [ ] Add `zig build test-display` when display-specific checks exist. Keep view-mapping
  tests independent of terminal initialization; exercise terminal lifecycle in a
  suitable terminal or PTY.

Exit criterion: inspect and control a running simulation, then verify that display
enabled/disabled gives identical logical simulation state for a fixed instruction budget.

Learning checkpoint: explain why observing state must not change execution or randomness.

Useful Ziglings:
[093_hello_c](../ziglings/exercises/093_hello_c.zig),
[094_c_math](../ziglings/exercises/094_c_math.zig),
[045_optionals](../ziglings/exercises/045_optionals.zig), and
[027_defer](../ziglings/exercises/027_defer.zig).

### Phase 7: CLI and Performance

Goal: make the completed simulation convenient to run and optimize measured bottlenecks.

#### CLI (`src/main.zig`)

Extend existing configuration printing and the basic ancestor execution path from
Phase 3 with controls for the features introduced in Phases 4–6.

- [ ] Parse instruction budgets, output directory/run ID, checkpoint save/load, and
  headless execution where display support is compiled in. Reject invalid arguments
  and protect existing run output from accidental overwriting.
- [ ] Keep shape, mutation settings, seed, and compiled features in `src/config.zon`.
  Record effective runtime options alongside that configuration in run metadata.
- [ ] Report budget completion, extinction, global instruction-limit exhaustion,
  and persistence failures clearly. Preserve output flushing and terminal cleanup.

Exit criterion: start a bounded experiment and resume a checkpoint through the CLI,
with useful diagnostics for invalid arguments and output failures.

#### Performance

Profile instruction dispatch, allocation scans, queue operations, and rendering after
replication and checkpoint-replay tests pass. Benchmark headless runs with output
disabled to separate simulation cost from I/O. Optimize one measured bottleneck at
a time, preserving stable storage and deterministic behavior with fixed-seed comparisons.

---

## Planned File Layout

Core paths below exist. Entries marked planned are future additions.
Split display files only as their views are introduced.

```text
src/
    config.zon
    config.zig                # validated production configuration exports
    main.zig
    root.zig                  # public API and core test reachability
    core/
        instruction.zig
        soup.zig
        cpu.zig
        template.zig
        creature.zig
    sim/
        simulation.zig
        scheduler.zig
        ancestor.zig
        mutation.zig          # planned, Phase 4
        genebank.zig          # planned, Phase 4
    persistence/              # planned, Phases 4–5
        lineage.zig
        snapshot.zig
        state.zig
    display/                  # planned, Phase 6: notcurses integration and views
output/<run_id>/              # planned default run directory
    metadata.json
    lineage.jsonl
    snapshots/                # observational summaries
    checkpoints/
plan/PLAN.md
reference/                   # read-only documentation
ziglings/                    # concept exercises
```

When runtime output is introduced, add its default directory to `.gitignore`;
the current ignore file does not include it.

## Testing Strategy

Tests should demonstrate a rule or reveal a boundary failure. Start with small,
hand-checkable soups and deterministic CPU states; avoid tests that simply mirror
the implementation.

1. Retain existing CPU/template, soup, scheduler, and lifecycle tests, including
   ancestor replication, counter saturation, and exact/split run budgets. Add direct
   low-level soup boundary checks for the unfinished Phase 1 guarantees.
2. Add deterministic mutation, genebank, and ordered-lineage checks with Phase 4,
   then summary/checkpoint checks with Phase 5. Use `std.testing.allocator` for
   allocation-bearing tests and exercise host failure cleanup.
3. Add display compilation/linking and pure view-mapping checks in Phase 6, with
   terminal lifecycle tests in an appropriate terminal or PTY.

`zig build test` already includes core unit and lifecycle integration tests through
`src/root.zig`. `zig test src/root.zig` runs the library-root graph directly. Import
new modules into the appropriate test roots as they are introduced: Zig does not
discover every source file's tests automatically. Keep external display dependencies
out of the core test graph. `zig build test-display` is planned for Phase 6;
there is no current `test-integration` step.

Do not assert that evolution must produce a particular population shape or that every
daughter must differ. Mutations are stochastic, and a bit flip can later be reversed.
Use forced decisions for specific mutation rules, fixed seeds for repeatable integration
runs, and structural invariants for larger runs.

## Key Design Decisions

| Decision | Current implementation or planned direction | Why |
| --- | --- | --- |
| Instruction storage | `[size]Instruction`, with 32 `enum(u8)` values | Direct execution and valid opcodes without a decoding layer |
| Addressing | Circular CPU access, linear allocations, `u16` addresses | Explicit bounds without split allocation handles |
| Register arithmetic | Defined 16-bit wrapping, separate from address normalization | Mutated programs cannot rely on host overflow behavior |
| Config | `src/config.zig` validates ZON and exports typed constants | One production source of truth; factories also accept small test configs |
| Creature storage | Fixed optional pool and inline-buffer-backed free-slot list | Stable addresses and no per-birth host allocation |
| Simulation initialization | Initialize caller-provided final storage in place, then inoculate separately | Explicit storage ownership; internal pointers remain valid |
| Identity | Reusable `slot_id: u16` plus persistent `organism_id: u64` | Fast ownership checks and unambiguous lineage |
| Queues | Separate intrusive slicer/reaper nodes | Constant-time linking with explicit lifetime rules |
| RNG | Local seeded soup initialization; separate mutation streams planned | Reproducible evolution independent of observation |
| Genebank (planned) | Owned instruction sequences and birth-genotype identity | Stable history despite soup changes and slot reuse |
| Persistence (planned) | Synchronous buffered output; data-only versioned checkpoints | Explicit ownership, error handling, and deterministic continuation |
| Display (planned) | Optional C integration, read-only views on the simulation thread | Headless core remains usable without notcurses |
| Error handling | `ExecResult` for VM outcomes; error unions for direct lifecycle calls and future host failures | Keep simulated faults distinct from infrastructure errors |
