# Zierra: High-Level Implementation Plan

This project teaches Zig 0.16.0 by building a Tierra simulation in small, testable steps.
The plan describes goals, contracts, and exercises; implementation remains the learner's work.
Work through one checkpoint at a time, predict its behavior, and write a small test before
connecting it to the next module.

## How to Use This Plan

- Checked items describe existing foundations, not a promise that an entire phase is finished.
  New acceptance criteria remain unchecked until implemented and verified.
- Module names and signatures describe intended boundaries. Adjust names while learning, but
  keep their behavior consistent with the contracts below.
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
  for older Zig versions; adapt API usage to 0.16.0. In particular, the old async exercises
  are not a prerequisite for persistence or display.

### Current Foundations and Remaining Alignment

The repository already contains instruction encoding, soup ownership/allocation helpers,
CPU state and some handlers, a creature type, and template searches. The following work
must still be treated as open rather than hidden by an earlier phase's completion mark:

- `src/config.zon` exists, but the typed configuration/validation module is still planned.
- Soup currently stores `?Instruction` and reads direct indices. The target below stores
  raw bytes; changing representation is a separate learning checkpoint.
- CPU and template helpers already wrap addresses. Circular execution does not require
  allocations to cross the soup boundary.
- Creature counters currently use `u16`, and its daughter allocation is not optional.
  Align these with the lifecycle contract before long simulation runs.
- CPU execution is incomplete. Existing search tests do not settle every search edge case.
- The library root does not currently import the core modules. Wire their tests into
  `zig build test` before treating that command as verification of the simulation.

---

## Architecture Overview

The simulation has these conceptual layers:

```text
main / CLI
    Simulation: lifecycle, counters, scheduling, mutation integration
        Soup: bytes, ownership, allocation
        Creature: CPU state, allocations, identity, counters
        CPU: fetch, decode, execute, report lifecycle requests
        Template search + instruction encoding
    Genebank and statistics
    Persistence: lineage, summaries, checkpoints
    Optional display: notcurses
```

Keep the simulation single-threaded initially. The CPU does not import the scheduler,
genebank, display, or simulation. A returned execution outcome lets the simulation
complete lifecycle operations before another instruction executes.

### Compile-Time Shape and Runtime State

Use compile-time parameters for capacities, stack depth, instruction definitions,
ancestor bytes, and optional features. Keep mutable soup contents, ownership, creatures,
queues, RNG state, and statistics at runtime.

Configuration comes from one typed object derived from `src/config.zon` through
`@import`. Shape and behavior fields may live together; changing the production config
means rebuilding. Tests can supply small configurations directly.

Factory types such as `Soup(size)`, `CPU(stack_depth, search_limit)`, and
`Simulation(config)` are useful where they clarify storage or behavior. Do not generalize
every module before its needs are understood. A compile-time limit bounds runtime work;
it does not require unrolling the loop or evaluating the simulation at compile time.

Fixed arrays specify layout, not where an instance lives. A full simulation can be large;
choose its storage deliberately rather than assuming returning it by value or putting
multiple instances on the stack is free. Once queues or RNG interfaces hold internal
pointers, initialize the object in its final location and avoid moving it.

---

## Shared Behavioral Contracts

These rules are defined once here and referenced by the phases below.

### Memory, Addresses, and Arithmetic

- Target soup storage is one `u8` per instruction. Decode uses only bits `0..4`.
  Copying, mutation output, genotype comparison, hashing, and serialization use canonical
  values `0x00..0x1f`; upper padding bits do not create distinct genotypes.
- Every soup cell has an instruction byte, including unowned cells. Initialize the soup
  with seeded random canonical instructions when starting a simulation. Tiny tests may
  use a deterministic fill. Ownership, rather than an optional instruction, determines
  whether memory is allocated.
- Freeing memory removes ownership and preserves its bytes, as described by the paper.
  Allocating reserves ownership without clearing old code.
- Read and execute privileges are unrestricted. A creature may write only cells owned
  by its current slot ID: its mother allocation and, before division, its daughter allocation.
  Cosmic rays are a separate privileged operation that can affect any soup cell.
- CPU fetches, template traversal, and memory dereferences normalize addresses modulo
  soup length. The soup's low-level read/write APIs require an already valid address;
  they do not silently implement wrapping.
- Allocations are linear contiguous ranges and never cross the end of the array.
  An allocation is valid when `len > 0`, `start < soup_size`, and
  `len <= soup_size - start`. Check this before indexing or changing state.
- Addresses and allocation lengths use `u16`, allowing capacities `1..65535`,
  not a capacity of 65536. Use `usize` or a wider integer for intermediate range
  arithmetic when needed, and validate before narrowing. Do not add two `u16`
  values first and widen an already-overflowed result.
- Registers are 16-bit bit patterns. Define addition/subtraction as wrapping modulo
  65536 and shifts as discarding bits beyond the register width. Normalize a register
  modulo soup length when using it as an address. These are different operations:
  register arithmetic must not accidentally wrap modulo soup length.
- Long-lived instruction/copy counters and timestamps use `u64`; accumulated errors
  use `u32`. Use a documented checked or saturating policy at their limits rather
  than allowing Debug builds to trap unexpectedly during an ordinary run.

Zierra's fixed-width registers and circular execution are explicit project conventions.
The paper's C `int` register fields do not by themselves establish 16-bit arithmetic.

### Ownership and Allocation Failure

Use an ownership-aware allocation operation, conceptually
`allocate(request_size, requester_id) -> Allocation or allocation error`.
Use one consistent failure vocabulary throughout the modules; the existing soup names
include `PermissionError`, `NoFreeSoup`, and `InvalidAllocation`.

- Reject zero-size and oversized requests. Search all valid runs, including one ending
  at the final cell and one occupying the entire soup.
- Insufficient contiguous space is a normal virtual-machine failure, even when total
  free memory is sufficient. The initial allocator uses deterministic first-fit scans.
- Validate the entire range before inoculation, freeing, or ownership transfer.
  Failed operations leave bytes, ownership, counters, and queues unchanged.
- Free/transfer operations must verify the expected owner, so a stale handle cannot
  release another creature's memory. Only the lifecycle manager retains live handles.
- On division, ownership changes from the mother's slot to the daughter's slot.
  On death, release both the mother allocation and any gestating daughter allocation.

### Identity, Storage, and Queue Lifetimes

`CreatureId` is a `u16` slot index used by soup ownership and in-memory lookup.
A separate monotonically increasing `OrganismId: u64` identifies a birth for lineage
and saved output. Slot reuse must never merge two organisms' histories.

Start with stable creature objects, for example individually allocated creatures indexed
by a growable table of pointers plus a free-slot list. A growing table may move its pointer
entries; the creatures themselves must stay at stable addresses while linked.

An `ArrayList(Creature)` that reallocates is incompatible with intrusive queue pointers.
Do not compact or swap-remove live creatures if their indices identify ownership.
Bound simultaneous slots by soup capacity and handle slot exhaustion as an explicit
resource failure.

Each live creature belongs to both queues exactly once, with separate link nodes.
Remove it from both before destroying its storage or reusing its slot. A cached display
selection must also validate the organism identity when a slot is reused.

### CPU Outcomes, Flags, and Counters

The execution outcome is a tagged union with one active variant:

| Outcome | Meaning |
| --- | --- |
| `none` | CPU-local work finished; no lifecycle request |
| `mal_request(size)` | Simulation must allocate a daughter block |
| `divide(allocation)` | Simulation must validate and complete division |
| `error_condition` | Expected VM fault; record one error |
| `hard_instruction_success` | Apply the configured reaper reward |

`step` fetches, decodes, dispatches, and increments the creature's executed counter once.
`execute` owns every instruction-pointer update, including failures and requests.
`step` must not increment IP again.

The simulation increments the global instruction counter once, then completes any request
before the next CPU step. Birth/replication events use this updated instruction time;
inoculation uses time zero. It then performs due mutation/observation work.
A failed allocation or division uses the same error-accounting path as a CPU fault,
exactly once.

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
  invalid-operand outcome, not loop forever. An overlong/invalid operand is distinct
  from an empty operand.
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
- Keep “no operand,” “invalid operand,” and “valid operand with no match” distinguishable
  in the CPU-facing extraction result. A nullable search result can still mean no match.

### Mutation Units and Reproducibility

Retain the existing configuration names, but define their units before adding RNG calls:

| Field | Meaning |
| --- | --- |
| `cosmic_rate` | Mean executed global instructions per cosmic event; 0 disables |
| `copy_error_rate` | Mean successful instruction copies per copy mutation; 0 disables |
| `flaw_rate` | Floating-point multiplier of the copy interval; 0 disables flaws |

For Zierra's initial model, each eligible opportunity is an independent trial:
probability `1 / cosmic_rate` after an executed instruction and
`1 / copy_error_rate` for a permitted copy. Flaws use an interval of
`max(1, ceil(copy_error_rate * flaw_rate))` eligible arithmetic executions.
Disable flaws when either input is zero. A value of 1 means every opportunity.
Thus `flaw_rate = 1.5` is a multiplier, not a 2/3 probability per instruction.

This independent-trial model avoids fixed periodic events. The paper describes randomized
intervals and generation-relative rates; these project units are a simplification, not
an exact reproduction of its experimental parameterization.

Use explicit, separate seeded streams for soup initialization, cosmic mutations, copy
mutations, and flaws. Specify their seed derivation and call order when implementing
Phase 4. Rendering, logging, and statistics must not consume simulation randomness.

Keep RNG state at a stable address, and retain all streams' full state for save/load.
A seed alone cannot resume a run midway through its random sequence.

---

## Linear Implementation Plan

### Phase 1: Compile-Time Shape

Goal: establish configuration, instruction representation, soup storage, and CPU state.

#### Configuration (`src/config.zon`, `src/core/config.zig`)

- [x] A project-wide `src/config.zon` exists.
- [ ] Add a typed config and compile-time validation.
- [ ] Make each concrete module receive only the configuration it needs.
- [ ] Verify importing the config and rebuilding selects the intended concrete types.

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

Validate positive soup size and stack depth; require finite floats, a reaper threshold
strictly between 0 and 1, nonnegative flaw multiplier, and nonnegative slicer power.
Check derived mutation intervals before converting floats to integers. Define zero
snapshot interval as disabled. Search limit zero is valid and causes searches to fail.

These are Zierra defaults. Do not test that every field matches a universal “original
Tierra default”; several are project choices or values from one experiment.

#### Instruction Set (`src/core/instruction.zig`)

- [x] All 32 opcodes are represented by an enum.
- [x] Encoding/decoding helpers exist and decoding ignores upper storage bits.
- [ ] Check opcode numbers and register effects against Appendix B.
- [ ] Verify encode/decode round trips for all 32 instructions.

#### Soup / Memory (`src/core/soup.zig`)

- [x] Compile-time `Soup(size)`, ownership, allocation, and inoculation foundations exist.
- [ ] Move from optional instructions to `[size]u8` memory plus
  `[size]?CreatureId` ownership.
- [ ] Implement the shared memory and failure contracts, including expected-owner checks.
- [ ] Accept the documented maximum capacity of 65535; reject zero.
- [ ] Keep the byte store independent of CPU decoding and queue management.

Use targeted tests for exact-fit allocation, the last free cell, zero requests, fragmented
space, range-end overflow, permission failures, and inoculation encountering an occupied
cell late in its range. Verify failed operations are atomic and freeing preserves code.
Test wrapping in address helpers rather than requiring low-level reads to wrap.

#### CPU State (`src/core/cpu.zig`)

- [x] Registers, a compile-time-sized stack, defaults, and push/pop foundations exist.
- [x] Stack overflow/underflow and a push/pop round trip have tests.
- [ ] Confirm failed stack operations preserve stack contents and pointer position.
- [ ] Keep stack capacity and stack-pointer types consistent.

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
- [ ] Separate extraction from searching and align with the shared template contract.
- [ ] Test equal-distance matches, zero search limit, all-NOP soup, operand overlap after
  wrapping, and invalid versus empty operands.
- [ ] Verify skipping a template uses its full length, independently of search distance.

#### CPU Execution (`src/core/cpu.zig`)

Implement groups in this order: plain arithmetic/register operations, stack operations,
conditional skips, jumps/calls/returns, addressing, copying, then lifecycle requests.
Keep mutation hooks disabled until Phase 4.

```text
step:
    clear this instruction's error flag
    fetch a valid soup byte at the normalized instruction pointer
    decode and execute one instruction
    increment the creature's executed counter once
    return its outcome

simulation's later instruction loop:
    step the current creature
    increment global executed count once
    finish any lifecycle request or error accounting
    apply due mutations
    finish scheduling/reaping if the slice ended
    record observations at this completed boundary
```

There is no empty-cell fetch in the target byte soup. While the old optional representation
is being retired, a null fetch can be treated as a VM fault that advances IP once; remove
that transitional branch and its tests when every cell has a byte.

| Instruction group | Behavior to establish |
| --- | --- |
| Plain arithmetic/register ops | Apply Appendix B's effect using defined 16-bit arithmetic; advance IP once |
| Stack ops | On failure, preserve the destination/stack state, advance IP, report an error |
| `if_cz` | If `cx == 0`, next step executes the next instruction; otherwise skip it, including its inline template if present |
| `jmp` / `jmpb` | Search bidirectionally/backward; land after the complementary template |
| `call` / `ret` | Push the address after the caller's operand only after a successful search; return to a popped, normalized address |
| `adr` / `adrb` / `adrf` | Search bidirectionally/backward/forward; store match-end address in `ax` and operand length in `cx`; advance past own operand |
| `mov_iab` | Copy one instruction from `[bx]` to `[ax]`, enforcing ownership; leave `ax` and `bx` unchanged |
| `mal` | Advance IP and request allocation of `cx` cells |
| `divide` | Advance IP and request division, or report an error when no daughter allocation exists |

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

- Embed the specialized CPU directly.
- Store slot ID, organism identity, mother allocation, optional daughter allocation,
  birth time, and the counters described in the shared contracts.
- Keep current genotype identity separate from the parent's genotype identity when
  the genebank is introduced.
- Avoid an import cycle between CPU and creature. Pass a narrow execution context or
  use generic parameters where appropriate; do not duplicate mutable CPU state.

Tests should cover overflow/underflow in registers, IP movement for every instruction
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

Start with a small queue exercise before adding both queues to the simulation.
Intrusive doubly linked queues use the stable-storage contract above.

- Slicer: circular round-robin queue, separate current cursor, insert/remove operations.
- Insert a newborn immediately before its mother in traversal order. For
  `mother -> A -> B -> mother`, birth produces
  `mother -> A -> B -> daughter -> mother`. The daughter does not immediately
  receive the remainder of the mother's slice.
- Slice size is `floor(genome_size ^ slicer_power)`, clamped to at least 1.
  Validate/clamp before narrowing to the chosen budget type; large powers must not
  overflow a `u16` conversion. A `u64` budget is suitable for long slices.
- Reaper: linear queue; newborns enter at the bottom and victims come from the top.
- On error, move up one position only if the neighbor above has no more errors.
  On a hard-instruction success, move down one position only if the neighbor below
  has at least as many errors. This is a local movement rule, not a globally sorted list.
- Define empty and singleton behavior. Queue access must be optional when empty.
  Removing a cursor target must leave a valid successor or an empty queue.

Test round-robin order, the explicit birth example, singleton removal, current-cursor
removal, movements blocked by neighbor error counts, and simultaneous membership
in both queues.

#### Ancestor (`src/sim/ancestor.zig`)

Transcribe the 80-instruction `0080aaa` genome from Appendix C as constant bytes.
Validate exact length, canonical opcode values, and fit in the selected soup.
“Every byte decodes” alone is insufficient validation because decoding masks every
possible byte into some instruction.

First trace its self-examination: at base 0, `adrb` finds match-end 4,
`sub_ac` obtains base 0, `adrf` finds match-end 79, and `inc_a`/`sub_ab`
calculate size 80. Then trace allocation, copying, and division.

#### Simulation (`src/sim/simulation.zig`)

Create a small `Simulation(config)` with soup, creature storage, queues, and basic
statistics. Introduce `init`/`deinit` with allocator ownership as needed. Keep
genebank, persistence, and display dependencies out until their phases.

- Inoculation prepares a creature/slot, claims the complete seed range, initializes
  CPU IP to its start, and links it into both queues. Failure cleans up preparation.
- Complete each CPU outcome before executing the next instruction.
- `mal`: reject an existing daughter or invalid size; claim a contiguous range for
  the mother, store the daughter handle, and set `ax` to its start.
  On allocation failure, preserve existing state and record one VM error.
- `divide`: validate ownership, prepare the daughter object/slot, then transfer
  ownership and publish the new creature to both queues. Clear the mother's daughter
  handle only when the operation commits. On preparation failure, the mother keeps it.
- Initialize the daughter's CPU with zeroed registers/flags, an empty stack, and IP at
  its mother-allocation start. The daughter starts with no daughter allocation.
- Do not require the copied counter to equal the allocation length before division;
  old code in newly allocated cells is meaningful, and later organisms may copy
  partially or use other creatures' code.
- Death unlinks both nodes, frees both owned blocks, updates population, and releases
  the slot/object. The instruction bytes remain in soup.

`tick` executes one slice, handling results after each instruction. After its last
instruction's mutation work, advance the slicer and reap while occupied memory exceeds
the configured threshold, before recording that boundary's observations.
`reaper_threshold = 0.8` means 80% occupied, hence 20% free; it is not a minimum
free fraction of 80%. Derive a single integer occupied-cell threshold at startup
using documented rounding, initially `floor(threshold * soup_size)`.
Count gestating daughter allocations as occupied memory.

Initially a fragmented/no-space `mal` fails; reaping occurs at slice boundaries.
Do not introduce hidden allocation retries or kill the executing mother inside
allocation handling without revisiting this scheduling policy.

Stop cleanly when no creatures remain. Define `run(max_instructions)` as executing
at most that many additional instructions, including a partial final slice.
Preserve the current creature and its remaining slice budget if a run is paused
mid-slice. Complete end-of-slice scheduling/reaping even when the final allowed
instruction exhausts a slice, so splitting a run does not change its scheduling. A zero budget executes nothing. Prevent huge slices from delaying
pause/quit handling indefinitely by polling at bounded instruction intervals.

Tests and exit criteria:

- [ ] Inoculation creates one correctly owned, scheduled creature.
- [ ] With all mutation rates disabled, the ancestor produces an identical 80-byte daughter.
- [ ] The daughter can reproduce too; population growth is not only a one-birth artifact.
- [ ] Allocation/division failures preserve ownership and queue invariants.
- [ ] Reaping frees gestating daughter memory and handles extinction.
- [ ] Threshold checks, exact run budgets, and empty queues behave as specified.

Learning checkpoint: explain the difference between soup allocation and host allocation,
and demonstrate why live queue pointers require stable creature addresses.

Useful Ziglings:
[043_pointers5](../ziglings/exercises/043_pointers5.zig),
[047_methods](../ziglings/exercises/047_methods.zig),
[029_errdefer](../ziglings/exercises/029_errdefer.zig),
[096_memory_allocation](../ziglings/exercises/096_memory_allocation.zig), and
[102_testing](../ziglings/exercises/102_testing.zig).
There is no dedicated linked-list exercise in this checkout; use a small local queue test.

### Phase 4: Evolution & Lineage

Goal: introduce mutation, genotype tracking, statistics, and ordered organism events.

#### Mutation (`src/sim/mutation.zig`)

Add one mutation class at a time, retaining a fully disabled configuration.

- Cosmic events flip one random bit in positions `0..4` at a random soup address,
  regardless of ownership, after instruction completion.
- Copy mutation applies only after destination permission is known to succeed and
  before storing the copied byte. The source byte stays unchanged unless source
  and destination are the same address.
- Initially apply execution flaws only to arithmetic/bit operations. For arithmetic,
  perturb the result by ±1 with defined 16-bit wrapping. For `or1`, perturb the
  chosen bit (no flip or bit 1 instead of bit 0); for `shl`, use shift 0 or 2
  instead of 1. Keep moves, stack, jumps, and lifecycle deterministic initially.
  This restricted scope is a documented simplification of the paper.
- Pass a mutation context through a narrow CPU interface; do not make CPU execution
  import or call the simulation.
- Use `std.Random.Xoshiro256` or another explicitly recorded seedable generator,
  with the separate stream/lifetime contract above.

Verify disabled rates, certain events at interval 1, single-bit mutation, canonical
bytes, denied-copy behavior, and deterministic replay. Use injected random decisions
to force edge cases. Do not write probabilistic tests that sometimes fail because no
mutation happened.

#### Genebank & Statistics (`src/sim/genebank.zig`)

A creature records its birth genotype. Cosmic mutation may change its living bytes
without changing that historical identity; census counts are initially by birth
genotype. Label live-byte inspection separately.

- Register canonical genomes at birth. Own a copy of the genome: a slice into soup
  will change, and a hash alone can collide. Compare bytes after a hash match.
- Maintain a current genotype ID as well as optional parent genotype ID.
  Derive parentage from the parent's birth genotype under this initial policy.
- Start with size + three-letter base-26 labels (`0080aaa`, `0080aab`, ...).
  Define exhaustion after `zzz`: return an explicit naming error, never silently wrap.
- A known genotype can arise from multiple parent genotypes. Keep a first-discovery
  parent on the record if useful; lineage events retain the actual organism parent.
- Record origin time, live population, replication counts, and instruction/error/copy
  totals or interval deltas as the corresponding measurements become available.
- At birth, first-replication metrics are unknown and must be optional. Populate them
  on actual replication, not with fabricated zeros during registration.
- Mark `breeds_true` when a completed replication produces bytes equal to the parent's
  stored birth genome. Track replication count separately. Naming every birth
  genotype immediately is a Zierra simplification: the paper describes one genebank
  implementation that waits for two replications and an identical offspring.
- Keep error counters, total population, and genotype census consistent on birth/death.
  Define deterministic census tie-breaking, for example by genotype label.

Test registration, high-bit canonicalization, distinct genomes of equal size, known
genomes with different parents, label exhaustion, breeds-true detection, and counters.

#### Lineage (`src/persistence/lineage.zig`)

Start with synchronous buffered JSONL, not a lock-free queue.

- Output one ordered event per line in `output/<run_id>/lineage.jsonl`.
- Record ancestor birth with no parent, later births with parent and child
  `OrganismId`, deaths, and the parent's first successful replication.
- Include genotype IDs, global instruction time, and an event sequence number so
  multiple events at the same instruction retain a defined order.
- Start with death cause `reaped`. An `error_limit` death policy requires an
  explicit future configuration/behavior decision and is not implied by VM faults.
- Use error-returning `record` and `flush`; surface I/O failures. Flush buffered output
  on successful shutdown, and ensure cleanup happens on error.
- Record the active config, RNG algorithm/seed scheme, Zig version, and simulation
  format/version in run metadata so an experiment can be interpreted later.
- A disabled lineage feature should not open its files or affect simulation randomness.

If profiling later justifies a writer thread, send owned immutable events through a
bounded queue. Define blocking/backpressure, writer-failure propagation, buffer ownership,
and shutdown/drain/join before adding it. “Non-blocking” cannot also promise to block
when full. Lock-free algorithms are an optional advanced exercise.

Learning checkpoint: distinguish organism identity from reusable storage slots and
explain why a genebank must own bytes instead of borrowing mutable soup memory.

Useful Ziglings:
[055_unions](../ziglings/exercises/055_unions.zig),
[096_memory_allocation](../ziglings/exercises/096_memory_allocation.zig),
[099_formatting](../ziglings/exercises/099_formatting.zig), and
[106_files](../ziglings/exercises/106_files.zig).
For optional later threading:
[104_threading](../ziglings/exercises/104_threading.zig) and
[105_threading2](../ziglings/exercises/105_threading2.zig).

### Phase 5: Snapshots & Persistence

Goal: observe a run and resume it deterministically. Summary snapshots and resumable
checkpoints are different artifacts with different data requirements.

#### Periodic Summaries (`src/persistence/snapshot.zig`)

- At completed instruction boundaries, capture summaries every
  `config.snapshot_interval` global instructions; zero disables.
- Record population, occupied/free memory, genotype census, size histogram, and time.
  Define ordering so identical simulation states produce identical summary content.
- The initial writer is synchronous and buffered. Snapshot construction owns its
  variable-length data and can fail allocation; expose allocator and cleanup lifetimes.
- If later sending summaries to a writer thread, deep-copy slices. A `*const Simulation`
  does not prevent another thread from mutating the same underlying memory.
- Write metadata separately so summaries can refer to the run/config version.

Test exact snapshot boundaries, disabled output, census agreement, and error cleanup.

#### Save/Load (`src/persistence/state.zig`)

Design a versioned data-only checkpoint schema before implementing serialization.
Do not serialize raw pointers, intrusive nodes, allocator internals, file handles, or
the entire in-memory simulation struct.

Capture at least:

- Config compatibility information, schema version, and instruction boundary/order.
- All soup bytes, including unowned code, plus ownership/allocation state.
- Creature slots, organism IDs, CPU registers, initialized stack portion, allocations,
  birth genotype, counters, and timestamps.
- Slicer order/cursor and remaining current-slice budget; reaper order.
- Full RNG stream states and any pending mutation schedule state.
- Genebank-owned genomes, labels/naming counters, census, replication metadata, and stats.
- Next organism ID, reusable slots, event sequence, and next observation boundaries.

Rebuild queue links and lookup structures when loading into final storage. Validate
ranges, unique identities, owners, queue membership, stack pointers, and config
compatibility before exposing the loaded instance. Free partially constructed state
on any parse/allocation/validation failure.

Use Zig 0.16.0's `std.json.Stringify` and `std.json.parseFromSlice`, checking actual
signatures in the installed library. Own or copy parsed data before releasing its
parse arena. Serialize only initialized stack entries; `undefined` storage is not
checkpoint data.

Write to a temporary file and replace the checkpoint only after a successful write/flush.
Initially resume into a new output run with metadata pointing to its parent checkpoint,
rather than appending potentially duplicated events to an old lineage file.

Exit criterion: run A+B uninterrupted and compare it with run A, save/load, then B.
Compare soup, ownership, CPU/queue state, genotypes, counters, and RNG state; matching
population alone is insufficient. Also reject truncated files, unsupported versions,
and incompatible fixed storage shapes.

Useful Ziglings:
[029_errdefer](../ziglings/exercises/029_errdefer.zig),
[096_memory_allocation](../ziglings/exercises/096_memory_allocation.zig),
[106_files](../ziglings/exercises/106_files.zig), and
[107_files2](../ziglings/exercises/107_files2.zig).

### Phase 6: Visualization

Goal: add optional notcurses views while preserving headless simulation behavior.

#### Build and C Wrapper (`build.zig`, `src/display/notcurses.zig`)

- Read `display_enabled` at build time. Only enabled artifacts import the C wrapper
  and link notcurses/libc. A headless build and normal core tests must work without
  the notcurses development package.
- With Zig 0.16.0, configure system-library linking on the relevant
  `std.Build.Module` and its `link_libc` setting; check its current signatures.
- Use `@cImport` and a namespaced `pub const c` or explicit public aliases.
  `pub usingnamespace` is unavailable in Zig 0.16.0.
- Add thin C error/default wrappers only as actual call sites require them.
- Add `zig build test-display` for display-specific checks when this phase begins.
  This command does not exist yet.
- Document the system's notcurses development package and header/library discovery.

#### Display and Views (`src/display/`)

- Initialize/tear down notcurses with cleanup on partially successful initialization.
- Start with a soup map and basic statistics; then add creature inspection and a
  size histogram.
- Render read-only state at a throttled rate on the simulation thread between completed
  instructions/batches. No cross-thread shared-state design is needed initially.
- Map input to quit, pause/resume, selection, and later single-step commands.
  Define single-step as one completed instruction, not a whole slice.
- While paused, keep polling input and rendering without advancing counters or RNG.
- Handle terminal resizing and empty/extinct populations.
- Validate a selection's organism identity when slots are recycled.

Compile/link checks can run without an interactive terminal. Actual notcurses
initialization/rendering tests require a suitable terminal or PTY; do not assume a
headless mode exists. Keep most view-mapping tests independent of terminal setup.
Verify display enabled/disabled produces the same simulation state for a fixed run.

Useful Ziglings:
[093_hello_c](../ziglings/exercises/093_hello_c.zig),
[094_c_math](../ziglings/exercises/094_c_math.zig),
[045_optionals](../ziglings/exercises/045_optionals.zig), and
[027_defer](../ziglings/exercises/027_defer.zig).

### Phase 7: Polish

Goal: make experiments convenient and optimize only measured bottlenecks.

#### CLI (`src/main.zig`)

- Show active configuration and run metadata.
- Parse bounded run length, output location/run ID, and supported pause/resume options.
- Keep shape/feature changes in `src/config.zon`. A binary compiled without display
  cannot enable it at runtime; a display-enabled binary may offer headless execution.
- Reject invalid arguments and avoid accidental overwriting of prior run output.
- Report extinction, completed budgets, and persistence failures clearly.
- Keep shutdown flushing and terminal cleanup reliable.

#### Performance

Profile instruction dispatch, allocation scans, queue operations, and rendering only
after deterministic replication and replay tests pass. Benchmark headless runs with
output disabled to separate simulation cost from I/O cost.

Possible later exercises include alternative stable-storage pools, allocation indexing,
buffered/threaded writers, and specialized dispatch. Preserve the established behavior
with fixed-seed comparisons; do not add these before a measured need or explicit
learning objective.

---

## Planned File Layout

This is the intended destination; some modules do not exist yet.

```text
src/
    config.zon
    main.zig
    root.zig                  # public API and core test reachability
    core/
        config.zig
        instruction.zig
        soup.zig
        cpu.zig
        template.zig
        creature.zig
    sim/
        simulation.zig
        scheduler.zig
        ancestor.zig
        mutation.zig
        genebank.zig
    persistence/
        lineage.zig
        snapshot.zig
        state.zig
    display/
        notcurses.zig
        display.zig
        soup_view.zig
        stats_view.zig
        creature_view.zig
        size_histogram.zig
output/<run_id>/              # runtime output, gitignored
    metadata.json
    lineage.jsonl
    snapshots/
    checkpoints/
plan/PLAN.md
reference/                   # read-only documentation
ziglings/                    # concept exercises
```

## Testing Strategy

Tests should demonstrate a rule or reveal a boundary failure. Start with small,
hand-checkable soups and deterministic CPU states; avoid tests that simply mirror
the implementation.

1. Unit tests: config validation, all opcode round trips, arithmetic/stack boundaries,
   atomic soup operations, search/skip semantics, queue invariants, deterministic mutation,
   genotype canonicalization, and serialization.
2. Integration tests: mutation-free ancestor replication across generations, correct
   ownership transfer/reaping, exact run budgets, ordered lineage, snapshot intervals,
   and deterministic checkpoint continuation.
3. Display tests: compilation/linking and pure view mapping, plus terminal lifecycle
   checks in an appropriate terminal environment.

Wire intended modules into test roots: Zig does not recursively discover every
`test` block in every source file. Keep external display dependencies out of the core
test graph. Use `std.testing.allocator` for allocation-bearing tests to expose leaks.

`zig build test` is the existing command and should grow to cover core unit and
integration tests. Add `zig build test-display` in Phase 6; there is no current
`test-integration` step.

Do not assert that evolution must produce a particular population shape or that every
daughter must differ. Mutations are stochastic, and a bit flip can later be reversed.
Use forced decisions for specific mutation rules, fixed seeds for repeatable integration
runs, and structural invariants for larger runs.

## Key Design Decisions

| Decision | Initial choice | Why |
| --- | --- | --- |
| Instruction storage | Canonical low-5-bit instructions in byte cells | Tierra's byte addressing and 32-opcode alphabet |
| Addressing | Circular CPU access, linear allocations, `u16` addresses | Explicit bounds without split allocation handles |
| Register arithmetic | Defined 16-bit wrapping, separate from address normalization | Mutated programs cannot rely on host overflow behavior |
| Config | Typed compile-time object from one ZON file | One production source of truth; small test configurations |
| Creature storage | Stable objects, slot lookup, free-slot list | Intrusive pointers survive lookup-table growth |
| Identity | Reusable slot ID plus persistent organism ID | Fast ownership checks and unambiguous lineage |
| Queues | Separate intrusive slicer/reaper nodes | Constant-time linking with explicit lifetime rules |
| RNG | Separate explicitly seeded streams | Reproducible evolution independent of observation |
| Genebank | Owned canonical genomes and byte comparison | Stable identity despite soup changes/hash collisions |
| Persistence | Synchronous buffered output first; data-only versioned checkpoints | Learn ownership and errors before concurrency |
| Display | Optional C import and module-level linking | Headless core remains usable without notcurses |
| Error handling | VM outcomes; host failures use error unions | Preserve simulated faults while surfacing infrastructure errors |
