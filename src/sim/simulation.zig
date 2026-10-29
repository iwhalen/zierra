const std = @import("std");

const cpu_module = @import("../core/cpu.zig");
const ExecResult = cpu_module.ExecResult;
const CPU = cpu_module.CPU;
const creature_module = @import("../core/creature.zig");
const Creature = @import("../core/creature.zig").Creature;
const Instruction = @import("../core/instruction.zig").Instruction;
const soup_module = @import("../core/soup.zig");
const Soup = soup_module.Soup;
const Allocation = soup_module.Allocation;
const SoupError = soup_module.SoupError;
const Scheduler = @import("./scheduler.zig").Scheduler;
const wrap_increment = @import("../core/template.zig").wrap_increment;

pub const SimulationError = error{ NoFreeSlots, OrganismIdExhausted, InoculationFailure, PermissionError, InvalidAllocation, InstructionLimitReached };

pub const global_max_instructions = std.math.maxInt(u64);

pub fn Simulation(comptime config: anytype) type {
    const SoupType = Soup(config.soup_size);
    const CPUType = CPU(config.stack_depth, config.search_limit);
    const CreatureType = Creature(CPUType);
    const SchedulerType = Scheduler(CreatureType);

    return struct {
        const Self = @This();

        soup: SoupType,
        scheduler: SchedulerType,

        creatures: [config.soup_size]?CreatureType,
        free_slots_buffer: [config.soup_size]u16,
        free_slots: std.ArrayList(u16),
        occupied_cells: u16,
        instructions_executed: u64,
        next_organism_id: u64,
        slice_remaining: u64,
        occupied_limit: u16,

        pub fn init(self: *Self) void {
            var rng = std.Random.Xoshiro256.init(config.rng_seed);

            self.soup = SoupType{};
            const mask = @as(u64, @typeInfo(Instruction).@"enum".fields.len - 1);
            for (0..self.soup.len) |i| {
                self.soup.memory[i] = @enumFromInt(rng.next() & mask);
            }

            self.scheduler = SchedulerType{};

            self.creatures = .{null} ** self.soup.len;

            self.free_slots = .initBuffer(&self.free_slots_buffer);
            for (0..self.soup.len) |i| {
                self.free_slots.appendAssumeCapacity(@intCast(self.soup.len - i - 1));
            }

            self.occupied_cells = 0;
            self.instructions_executed = 0;
            self.next_organism_id = 0;
            self.slice_remaining = 0;

            self.occupied_limit = @intFromFloat(@floor(@as(f64, config.reaper_threshold) * @as(f64, @floatFromInt(self.soup.len))));
        }

        fn generate_next_organism_id(self: *Self) u64 {
            const temp = self.next_organism_id;
            self.next_organism_id += 1;
            return temp;
        }

        pub fn inoculate(self: *Self, code: []const Instruction, address: u16) SimulationError!u16 {
            if (code.len == 0 or address >= self.soup.len or code.len > self.soup.len - address) {
                return SimulationError.InoculationFailure;
            }

            if (self.next_organism_id == std.math.maxInt(u64)) {
                return SimulationError.OrganismIdExhausted;
            }

            const id = self.free_slots.pop() orelse return SimulationError.NoFreeSlots;
            const allocation = self.soup.inoculate(code, address, id) catch {
                self.free_slots.appendAssumeCapacity(id);
                return SimulationError.InoculationFailure;
            };

            const creature = CreatureType{
                .slot_id = id,
                .organism_id = self.generate_next_organism_id(),
                .cpu = CPUType{ .ip = address },
                .mother_alloc = allocation,
                .daughter_alloc = null,
                .parent_genotype = null,
                .origin_time = self.instructions_executed,
            };

            self.creatures[id] = creature;
            self.occupied_cells += allocation.len;

            self.scheduler.add_initial(&self.creatures[id].?);

            return id;
        }

        pub fn mal_request(self: *Self, size: u16, creature: *CreatureType) void {
            if (size == 0 or creature.daughter_alloc != null) {
                creature.cpu.fl = 1;
                self.scheduler.on_error(creature);
                return;
            }

            const allocation = self.soup.allocate(size, creature.slot_id) catch {
                creature.cpu.fl = 1;
                self.scheduler.on_error(creature);
                return;
            };

            creature.daughter_alloc = allocation;
            creature.cpu.ax = allocation.start;
            self.occupied_cells += allocation.len;

            self.scheduler.on_hard_success(creature);
        }

        pub fn divide(self: *Self, creature: *CreatureType) void {
            if (!valid_allocation(creature.daughter_alloc, self.soup.len)) {
                creature.cpu.fl = 1;
                self.scheduler.on_error(creature);
                return;
            }

            if (!disjoint_allocations(&creature.mother_alloc, &creature.daughter_alloc.?)) {
                creature.cpu.fl = 1;
                self.scheduler.on_error(creature);
                return;
            }

            // Check that the mother owns all the daughter allocation cells.
            var address: u16 = undefined;
            for (creature.daughter_alloc.?.start..creature.daughter_alloc.?.start + creature.daughter_alloc.?.len) |i| {
                address = wrap_increment(@intCast(i), 0, self.soup.len);

                if (self.soup.owner[address] != creature.slot_id) {
                    creature.cpu.fl = 1;
                    self.scheduler.on_error(creature);
                    return;
                }
            }

            // Check there are IDs left to assign.
            if (self.next_organism_id == std.math.maxInt(u64)) {
                creature.cpu.fl = 1;
                self.scheduler.on_error(creature);
                return;
            }

            // Check there are slots left to hand out.
            const daughter_id = self.free_slots.pop() orelse {
                creature.cpu.fl = 1;
                self.scheduler.on_error(creature);
                return;
            };

            const daughter = CreatureType{
                .slot_id = daughter_id,
                .organism_id = self.generate_next_organism_id(),
                .cpu = CPUType{ .ip = creature.daughter_alloc.?.start },
                .mother_alloc = creature.daughter_alloc.?,
                .daughter_alloc = null,
                .parent_genotype = null,
                .origin_time = self.instructions_executed,
            };

            self.creatures[daughter_id] = daughter;
            creature.daughter_alloc = null;

            self.scheduler.add_child(creature, &self.creatures[daughter_id].?);

            for (daughter.mother_alloc.start..daughter.mother_alloc.start + daughter.mother_alloc.len) |i| {
                address = wrap_increment(@intCast(i), 0, self.soup.len);
                self.soup.owner[address] = daughter_id;
            }
        }

        pub fn kill(self: *Self, creature: *CreatureType) SimulationError!void {
            if (creature.slot_id >= self.creatures.len or self.creatures[creature.slot_id] == null) {
                return SimulationError.InvalidAllocation;
            }

            if (&self.creatures[creature.slot_id].? != creature) {
                return SimulationError.PermissionError;
            }

            if (!valid_allocation(creature.mother_alloc, self.soup.len)) {
                return SimulationError.InvalidAllocation;
            }

            if (creature.daughter_alloc != null and !valid_allocation(creature.daughter_alloc, self.soup.len)) {
                return SimulationError.InvalidAllocation;
            }

            if (creature.daughter_alloc != null and !disjoint_allocations(&creature.mother_alloc, &creature.daughter_alloc.?)) {
                return SimulationError.InvalidAllocation;
            }

            var address: u16 = undefined;
            for (creature.mother_alloc.start..creature.mother_alloc.start + creature.mother_alloc.len) |i| {
                address = wrap_increment(@intCast(i), 0, self.soup.len);

                if (self.soup.owner[address] != creature.slot_id) {
                    return SimulationError.PermissionError;
                }
            }

            if (creature.daughter_alloc != null) {
                for (creature.daughter_alloc.?.start..creature.daughter_alloc.?.start + creature.daughter_alloc.?.len) |i| {
                    address = wrap_increment(@intCast(i), 0, self.soup.len);

                    if (self.soup.owner[address] != creature.slot_id) {
                        return SimulationError.PermissionError;
                    }
                }
            }

            self.soup.free(creature.mother_alloc) catch {
                return SimulationError.InvalidAllocation;
            };
            self.occupied_cells -= creature.mother_alloc.len;

            if (creature.daughter_alloc != null) {
                self.soup.free(creature.daughter_alloc.?) catch {
                    return SimulationError.InvalidAllocation;
                };
                self.occupied_cells -= creature.daughter_alloc.?.len;
            }

            if (self.scheduler.slicer_current == &creature.slicer_node) {
                self.slice_remaining = 0;
            }

            self.scheduler.remove(creature);

            const slot_id = creature.slot_id;
            self.creatures[slot_id] = null;
            self.free_slots.appendAssumeCapacity(slot_id);
        }

        pub fn step(self: *Self) SimulationError!bool {
            // All slots are free, our population is empty.
            if (self.free_slots.items.len == self.creatures.len) {
                return false;
            }

            if (self.instructions_executed >= global_max_instructions) {
                return SimulationError.InstructionLimitReached;
            }

            const creature = self.scheduler.current_creature() orelse return false;

            if (self.slice_remaining == 0) {
                const power_result: f64 = std.math.pow(f64, @floatFromInt(creature.mother_alloc.len), config.slicer_power);

                var slice: u64 = undefined;
                if (power_result < 1) {
                    slice = 1;
                } else if (power_result >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) {
                    slice = std.math.maxInt(u64);
                } else {
                    slice = @intFromFloat(@floor(power_result));
                }

                self.slice_remaining = slice;
            }

            const result = creature.cpu.step(&self.soup, creature);
            self.instructions_executed += 1;

            switch (result) {
                .none => {},
                .error_condition => {
                    self.scheduler.on_error(creature);
                },
                .divide => {
                    self.divide(creature);
                },
                .mal_request => |size| {
                    self.mal_request(size, creature);
                },
                .hard_instruction_success => {
                    self.scheduler.on_hard_success(creature);
                },
            }

            self.slice_remaining -= 1;

            if (self.slice_remaining == 0) {
                self.scheduler.advance();

                while (self.occupied_cells > self.occupied_limit) {
                    const victim = self.scheduler.next_victim() orelse break;
                    try self.kill(victim);
                }
            }

            return true;
        }

        pub fn run(self: *Self, max_instructions: u64) SimulationError!u64 {
            var instructions_executed: u64 = 0;
            var step_ok: bool = undefined;

            while (instructions_executed < max_instructions) : (instructions_executed += 1) {
                step_ok = try self.step();

                if (!step_ok) {
                    break;
                }
            }

            return instructions_executed;
        }
    };
}

fn valid_allocation(maybe_alloc: ?Allocation, soup_len: u16) bool {
    const alloc = maybe_alloc orelse return false;
    return alloc.len > 0 and alloc.start < soup_len and alloc.len <= soup_len - alloc.start;
}

fn disjoint_allocations(a: *Allocation, b: *Allocation) bool {
    const a_start = @as(u32, a.start);
    const a_end = @as(u32, a_start + a.len);

    const b_start = @as(u32, b.start);
    const b_end = @as(u32, b_start + b.len);

    return a_start >= b_end or b_start >= a_end;
}

//
// AI generated unit tests.
//

test "valid_allocation handles optional values and null" {
    const valid: ?Allocation = .{ .start = 4, .len = 5 };
    const invalid: ?Allocation = .{ .start = 15, .len = 2 };

    try std.testing.expect(valid_allocation(valid, 16));
    try std.testing.expect(!valid_allocation(invalid, 16));
    try std.testing.expect(!valid_allocation(null, 0));
    try std.testing.expect(!valid_allocation(null, 16));
    try std.testing.expect(!valid_allocation(null, std.math.maxInt(u16)));
}

test "valid_allocation accepts contained ranges and exact fits" {
    const allocations = [_]Allocation{
        .{ .start = 0, .len = 16 },
        .{ .start = 4, .len = 5 },
        .{ .start = 15, .len = 1 },
        .{ .start = 12, .len = 4 },
    };

    for (allocations) |allocation| {
        try std.testing.expect(valid_allocation(allocation, 16));
    }
}

test "valid_allocation rejects empty ranges and empty soup" {
    try std.testing.expect(!valid_allocation(.{ .start = 0, .len = 0 }, 16));
    try std.testing.expect(!valid_allocation(.{ .start = 8, .len = 0 }, 16));
    try std.testing.expect(!valid_allocation(.{ .start = 0, .len = 0 }, 0));
    try std.testing.expect(!valid_allocation(.{ .start = 0, .len = 1 }, 0));
}

test "valid_allocation rejects starts and ends outside soup" {
    const allocations = [_]Allocation{
        .{ .start = 16, .len = 1 },
        .{ .start = 17, .len = 1 },
        .{ .start = 15, .len = 2 },
        .{ .start = 1, .len = 16 },
        .{ .start = 0, .len = 17 },
    };

    for (allocations) |allocation| {
        try std.testing.expect(!valid_allocation(allocation, 16));
    }
}

test "valid_allocation handles u16 boundaries without overflow" {
    const maximum = std.math.maxInt(u16);
    const soup_len = maximum - 1;

    try std.testing.expect(valid_allocation(.{ .start = 0, .len = soup_len }, soup_len));
    try std.testing.expect(valid_allocation(.{ .start = soup_len - 1, .len = 1 }, soup_len));
    try std.testing.expect(!valid_allocation(.{ .start = soup_len - 1, .len = 4 }, soup_len));
    try std.testing.expect(!valid_allocation(.{ .start = 1, .len = maximum }, soup_len));
    try std.testing.expect(!valid_allocation(.{ .start = maximum, .len = maximum }, soup_len));
}

const SimulationTestConfig = struct {
    soup_size: u16 = 16,
    stack_depth: u16 = 4,
    search_limit: u16 = 16,
    rng_seed: u64 = 12345,
    reaper_threshold: f32 = 0.6,
    slicer_power: f32 = 1,
    cosmic_rate: u32 = 0,
    copy_error_rate: u32 = 0,
    flaw_rate: f32 = 0,
    display_enabled: bool = false,
    lineage_enabled: bool = false,
    snapshot_interval: u64 = 0,
};
const simulation_test_config: SimulationTestConfig = .{};
const TestSimulation = Simulation(simulation_test_config);

fn SimulationTestState(comptime Sim: type) type {
    const count = @typeInfo(@FieldType(Sim, "creatures")).array.len;
    const CreatureType = @typeInfo(@typeInfo(@FieldType(Sim, "creatures")).array.child).optional.child;
    const CpuType = @FieldType(CreatureType, "cpu");
    return struct {
        const Payload = struct {
            slot_id: u16,
            organism_id: u64,
            registers: [4]u16,
            fl: u8,
            ip: u16,
            sp: u16,
            // Only stack[0..sp] is meaningful. The rest is canonicalized to zero.
            stack: @FieldType(CpuType, "stack"),
            mother: Allocation,
            daughter: ?Allocation,
            errors: u32,
            executed: u64,
            copied: u64,
            parent: ?creature_module.GenotypeId,
            origin: u64,
        };
        memory: @FieldType(Soup(count), "memory"),
        owners: [count]?u16,
        creatures: [count]?Payload = .{null} ** count,
        free_slots: [count]?u16 = .{null} ** count,
        slicer: [count]?u16,
        reaper: [count]?u16,
        current: ?u16,
        occupied: u16,
        time: u64,
        next_identity: u64,
        remaining: u64,
        limit: u16,
    };
}

fn simulationTestQueue(sim: anytype, comptime field: []const u8) ![@typeInfo(@FieldType(@TypeOf(sim.*), "creatures")).array.len]?u16 {
    const count = sim.creatures.len;
    const CreatureType = @typeInfo(@typeInfo(@FieldType(@TypeOf(sim.*), "creatures")).array.child).optional.child;
    const queue = if (comptime std.mem.eql(u8, field, "slicer_node")) &sim.scheduler.slicer else &sim.scheduler.reaper;
    var result: [count]?u16 = .{null} ** count;
    var seen = [_]bool{false} ** count;
    var node = queue.first;
    var previous: ?*std.DoublyLinkedList.Node = null;
    var index: usize = 0;
    while (node) |current| {
        try std.testing.expect(index < count);
        try std.testing.expectEqual(previous, current.prev);
        const creature: *CreatureType = @fieldParentPtr(field, current);
        try std.testing.expect(creature.slot_id < count);
        const id = creature.slot_id;
        try std.testing.expect(sim.creatures[id] != null);
        try std.testing.expectEqual(&@field(sim.creatures[id].?, field), current);
        try std.testing.expect(!seen[id]);
        seen[id] = true;
        result[index] = id;
        index += 1;
        previous = current;
        node = current.next;
    }
    try std.testing.expectEqual(previous, queue.last);
    for (sim.creatures, 0..) |maybe_creature, id| {
        try std.testing.expectEqual(maybe_creature != null, seen[id]);
    }
    return result;
}

fn simulationTestSnapshot(sim: anytype) !SimulationTestState(@TypeOf(sim.*)) {
    var result: SimulationTestState(@TypeOf(sim.*)) = .{
        .memory = sim.soup.memory,
        .owners = sim.soup.owner,
        .slicer = try simulationTestQueue(sim, "slicer_node"),
        .reaper = try simulationTestQueue(sim, "reaper_node"),
        .current = if (sim.scheduler.current_creature()) |creature| creature.slot_id else null,
        .occupied = sim.occupied_cells,
        .time = sim.instructions_executed,
        .next_identity = sim.next_organism_id,
        .remaining = sim.slice_remaining,
        .limit = sim.occupied_limit,
    };
    for (sim.free_slots.items, 0..) |id, i| result.free_slots[i] = id;
    for (&sim.creatures, 0..) |*maybe_creature, i| {
        if (maybe_creature.*) |*creature| {
            var stack: @TypeOf(creature.cpu.stack) = @splat(0);
            @memcpy(stack[0..creature.cpu.sp], creature.cpu.stack[0..creature.cpu.sp]);
            result.creatures[i] = .{
                .slot_id = creature.slot_id,
                .organism_id = creature.organism_id,
                .registers = .{ creature.cpu.ax, creature.cpu.bx, creature.cpu.cx, creature.cpu.dx },
                .fl = creature.cpu.fl,
                .ip = creature.cpu.ip,
                .sp = creature.cpu.sp,
                .stack = stack,
                .mother = creature.mother_alloc,
                .daughter = creature.daughter_alloc,
                .errors = creature.errors,
                .executed = creature.instructions_executed,
                .copied = creature.instructions_copied,
                .parent = creature.parent_genotype,
                .origin = creature.origin_time,
            };
        }
    }
    return result;
}

fn simulationTestPopulation(sim: anytype) !void {
    _ = try simulationTestQueue(sim, "slicer_node");
    _ = try simulationTestQueue(sim, "reaper_node");
    var free = [_]bool{false} ** sim.creatures.len;
    for (sim.free_slots.items) |id| {
        try std.testing.expect(id < sim.creatures.len);
        try std.testing.expect(!free[id]);
        try std.testing.expect(sim.creatures[id] == null);
        free[id] = true;
    }
    var expected_owners: @TypeOf(sim.soup.owner) = @splat(null);
    var occupied: usize = 0;
    var live: usize = 0;
    for (&sim.creatures, 0..) |*maybe_creature, id| {
        try std.testing.expectEqual(maybe_creature.* == null, free[id]);
        if (maybe_creature.*) |*creature| {
            live += 1;
            try std.testing.expectEqual(id, creature.slot_id);
            const allocations = [_]?Allocation{ creature.mother_alloc, creature.daughter_alloc };
            for (allocations) |maybe_alloc| {
                if (maybe_alloc) |alloc| {
                    try std.testing.expect(valid_allocation(alloc, sim.soup.len));
                    const end = @as(usize, alloc.start) + alloc.len;
                    for (alloc.start..end) |address| {
                        try std.testing.expectEqual(null, expected_owners[address]);
                        expected_owners[address] = creature.slot_id;
                        occupied += 1;
                    }
                }
            }
        }
    }
    try std.testing.expectEqualSlices(?u16, &expected_owners, &sim.soup.owner);
    try std.testing.expectEqual(occupied, sim.occupied_cells);
    if (live == 0) {
        try std.testing.expectEqual(null, sim.scheduler.slicer_current);
    } else {
        const current = sim.scheduler.current_creature() orelse return error.TestExpectedEqual;
        try std.testing.expectEqual(&sim.creatures[current.slot_id].?, current);
    }
}

fn simulationTestOrder(sim: anytype, comptime field: []const u8, expected: []const u16) !void {
    const actual = try simulationTestQueue(sim, field);
    for (expected, 0..) |id, i| try std.testing.expectEqual(@as(?u16, id), actual[i]);
    for (actual[expected.len..]) |id| try std.testing.expectEqual(null, id);
}

fn simulationTestNewborn(creature: anytype, slot: u16, identity: u64, allocation: Allocation, time: u64) !void {
    try std.testing.expectEqual(slot, creature.slot_id);
    try std.testing.expectEqual(identity, creature.organism_id);
    try std.testing.expectEqualDeep(allocation, creature.mother_alloc);
    try std.testing.expectEqual(null, creature.daughter_alloc);
    try std.testing.expectEqual(null, creature.parent_genotype);
    try std.testing.expectEqual(time, creature.origin_time);
    try std.testing.expectEqual(@as(u64, 0), creature.instructions_executed);
    try std.testing.expectEqual(@as(u64, 0), creature.instructions_copied);
    try std.testing.expectEqual(@as(u32, 0), creature.errors);
    try std.testing.expectEqual(allocation.start, creature.cpu.ip);
    try std.testing.expectEqual(@as(u16, 0), creature.cpu.ax);
    try std.testing.expectEqual(@as(u16, 0), creature.cpu.bx);
    try std.testing.expectEqual(@as(u16, 0), creature.cpu.cx);
    try std.testing.expectEqual(@as(u16, 0), creature.cpu.dx);
    try std.testing.expectEqual(@as(u16, 0), creature.cpu.sp);
    try std.testing.expectEqual(@as(u8, 0), creature.cpu.fl);
}

test "simulation: empty initialization and seeded reproducibility" {
    var a: TestSimulation = undefined;
    var b: TestSimulation = undefined;
    a.init();
    b.init();
    try std.testing.expectEqualSlices(Instruction, &a.soup.memory, &b.soup.memory);
    for (a.soup.memory) |instruction| try std.testing.expect(@intFromEnum(instruction) < 32);
    for (a.soup.owner) |owner| try std.testing.expectEqual(null, owner);
    for (a.creatures) |creature| try std.testing.expectEqual(null, creature);
    try std.testing.expectEqual(@as(usize, 16), a.free_slots.items.len);
    for (a.free_slots.items, 0..) |id, i| try std.testing.expectEqual(15 - i, id);
    try std.testing.expectEqual(@as(u16, 0), a.occupied_cells);
    try std.testing.expectEqual(@as(u64, 0), a.instructions_executed);
    try std.testing.expectEqual(@as(u64, 0), a.next_organism_id);
    try std.testing.expectEqual(@as(u64, 0), a.slice_remaining);
    try std.testing.expectEqual(@as(u16, 9), a.occupied_limit);
    try simulationTestPopulation(&a);
    try std.testing.expectEqualDeep(try simulationTestSnapshot(&a), try simulationTestSnapshot(&b));
}

test "simulation: inoculation initializes live fields and queues with ascending slots" {
    var sim: TestSimulation = undefined;
    sim.init();
    const original = sim.soup.memory;
    const a = try sim.inoculate(&.{ .inc_a, .inc_b }, 4);
    const b = try sim.inoculate(&.{.zero}, 15);
    try std.testing.expectEqual(@as(u16, 0), a);
    try std.testing.expectEqual(@as(u16, 1), b);
    try simulationTestNewborn(&sim.creatures[a].?, a, 0, .{ .start = 4, .len = 2 }, 0);
    try simulationTestNewborn(&sim.creatures[b].?, b, 1, .{ .start = 15, .len = 1 }, 0);
    for (sim.soup.memory, 0..) |instruction, i| {
        const expected = switch (i) {
            4 => Instruction.inc_a,
            5 => Instruction.inc_b,
            15 => Instruction.zero,
            else => original[i],
        };
        try std.testing.expectEqual(expected, instruction);
    }
    try std.testing.expectEqual(@as(u64, 2), sim.next_organism_id);
    try std.testing.expectEqual(@as(u16, 0), sim.scheduler.current_creature().?.slot_id);
    try simulationTestOrder(&sim, "slicer_node", &.{ 0, 1 });
    try simulationTestOrder(&sim, "reaper_node", &.{ 0, 1 });
    try simulationTestPopulation(&sim);
}

test "simulation: invalid and occupied inoculations are atomic" {
    var sim: TestSimulation = undefined;
    sim.init();
    _ = try sim.inoculate(&.{.zero}, 5);
    const before = try simulationTestSnapshot(&sim);
    const attempts = [_]struct { code: []const Instruction, address: u16 }{
        .{ .code = &.{}, .address = 0 },
        .{ .code = &.{.inc_a}, .address = 16 },
        .{ .code = &.{.inc_a}, .address = std.math.maxInt(u16) },
        .{ .code = &.{ .inc_a, .inc_b }, .address = 15 },
        // The first two cells are free: encountering the occupied last cell
        // must not leave a partially written inoculation or consume a slot.
        .{ .code = &.{ .inc_a, .inc_b, .nop_0 }, .address = 3 },
    };
    for (attempts) |attempt| {
        try std.testing.expectError(error.InoculationFailure, sim.inoculate(attempt.code, attempt.address));
        try std.testing.expectEqualDeep(before, try simulationTestSnapshot(&sim));
    }
    const too_long = [_]Instruction{.nop_0} ** 17;
    try std.testing.expectError(error.InoculationFailure, sim.inoculate(&too_long, 0));
    try std.testing.expectEqualDeep(before, try simulationTestSnapshot(&sim));
}

test "simulation: inoculation resource exhaustion is atomic and identity never wraps" {
    var sim: TestSimulation = undefined;
    sim.init();
    // A synthetic resource boundary isolates the slot check from soup fullness.
    sim.free_slots.items.len = 0;
    const no_slots = try simulationTestSnapshot(&sim);
    try std.testing.expectError(error.NoFreeSlots, sim.inoculate(&.{.zero}, 0));
    try std.testing.expectEqualDeep(no_slots, try simulationTestSnapshot(&sim));

    sim.init();
    sim.next_organism_id = std.math.maxInt(u64) - 1;
    const id = try sim.inoculate(&.{.zero}, 0);
    try std.testing.expectEqual(std.math.maxInt(u64) - 1, sim.creatures[id].?.organism_id);
    const exhausted = try simulationTestSnapshot(&sim);
    try std.testing.expectError(error.OrganismIdExhausted, sim.inoculate(&.{.zero}, 1));
    try std.testing.expectEqualDeep(exhausted, try simulationTestSnapshot(&sim));
    try simulationTestPopulation(&sim);
}

test "simulation: released slots are reused first with new identity and clean nodes" {
    var sim: TestSimulation = undefined;
    sim.init();
    const a = try sim.inoculate(&.{.inc_a}, 0);
    const b = try sim.inoculate(&.{.inc_b}, 1);
    const creature = &sim.creatures[a].?;
    creature.cpu.ax = 99;
    creature.cpu.fl = 1;
    creature.cpu.stack[0] = 77;
    creature.cpu.sp = 1;
    creature.errors = 5;
    creature.instructions_executed = 7;
    creature.instructions_copied = 3;
    creature.parent_genotype = .{ .size = 1, .code = .{ 'a', 'b', 'c' } };
    try sim.kill(creature);
    const reused = try sim.inoculate(&.{.zero}, 2);
    const fresh = try sim.inoculate(&.{.zero}, 3);
    try std.testing.expectEqual(a, reused);
    try std.testing.expectEqual(@as(u16, 2), fresh);
    try simulationTestNewborn(&sim.creatures[reused].?, reused, 2, .{ .start = 2, .len = 1 }, 0);
    try simulationTestOrder(&sim, "slicer_node", &.{ b, reused, fresh });
    try simulationTestOrder(&sim, "reaper_node", &.{ b, reused, fresh });
    try simulationTestPopulation(&sim);
}

test "simulation: mal reserves first fit without clearing code and rewards exactly once" {
    var sim: TestSimulation = undefined;
    sim.init();
    const a = try sim.inoculate(&.{ .mal, .inc_a }, 4);
    _ = try sim.inoculate(&.{.nop_0}, 8);
    _ = try sim.inoculate(&.{.nop_0}, 10);
    const mother = &sim.creatures[a].?;
    mother.cpu.cx = 3;
    mother.cpu.fl = 1;
    const memory = sim.soup.memory;
    try std.testing.expect(try sim.step());
    try std.testing.expectEqualDeep(@as(?Allocation, .{ .start = 0, .len = 3 }), mother.daughter_alloc);
    try std.testing.expectEqual(@as(u16, 0), mother.cpu.ax);
    try std.testing.expectEqual(@as(u8, 0), mother.cpu.fl);
    try std.testing.expectEqual(@as(u32, 0), mother.errors);
    try std.testing.expectEqual(@as(u16, 7), sim.occupied_cells);
    try std.testing.expectEqual(@as(u64, 1), sim.instructions_executed);
    try std.testing.expectEqual(@as(u64, 1), mother.instructions_executed);
    try std.testing.expectEqual(@as(u16, 5), mother.cpu.ip);
    try std.testing.expectEqualSlices(Instruction, &memory, &sim.soup.memory);
    try simulationTestOrder(&sim, "reaper_node", &.{ 1, 0, 2 });
    try simulationTestPopulation(&sim);
}

test "simulation: rejected mal requests preserve lifecycle and record one error" {
    const Case = enum { zero, oversized, duplicate, full, fragmented };
    inline for (std.meta.tags(Case)) |case| {
        var sim: TestSimulation = undefined;
        sim.init();
        const a = try sim.inoculate(&.{.nop_0}, 0);
        var size: u16 = 2;
        switch (case) {
            .zero => size = 0,
            .oversized => size = 17,
            .duplicate => sim.mal_request(2, &sim.creatures[a].?),
            .full => {
                _ = try sim.inoculate(&(@as([15]Instruction, @splat(.nop_0))), 1);
            },
            .fragmented => {
                for (1..8) |i| _ = try sim.inoculate(&.{.nop_0}, @intCast(i * 2));
            },
        }
        const mother = &sim.creatures[a].?;
        mother.cpu.ax = 123;
        const before = try simulationTestSnapshot(&sim);
        sim.mal_request(size, mother);
        var expected = before;
        expected.creatures[a].?.fl = 1;
        expected.creatures[a].?.errors += 1;
        try std.testing.expectEqualDeep(expected, try simulationTestSnapshot(&sim));
        try simulationTestPopulation(&sim);
    }
}

test "simulation: division creates a reset child at updated time and preserves mother slice" {
    var sim: TestSimulation = undefined;
    sim.init();
    const a = try sim.inoculate(&.{ .divide, .nop_0, .nop_0, .nop_0 }, 0);
    _ = try sim.inoculate(&.{.nop_0}, 10);
    const mother = &sim.creatures[a].?;
    sim.mal_request(3, mother);
    mother.cpu.ax = 42;
    mother.cpu.bx = 43;
    mother.cpu.cx = 44;
    mother.cpu.dx = 45;
    mother.cpu.fl = 1;
    mother.cpu.stack[0] = 7;
    mother.cpu.sp = 1;
    mother.errors = 4;
    mother.instructions_executed = 11;
    mother.instructions_copied = 3;
    const alloc = mother.daughter_alloc.?;
    const bytes = sim.soup.memory;
    const occupied = sim.occupied_cells;
    sim.instructions_executed = 40;
    sim.slice_remaining = 3;
    const identity = sim.next_organism_id;
    const child_slot = sim.free_slots.getLast();
    try std.testing.expect(try sim.step());
    try simulationTestNewborn(&sim.creatures[child_slot].?, child_slot, identity, alloc, 41);
    try std.testing.expectEqual(null, mother.daughter_alloc);
    try std.testing.expectEqual(@as(u64, 2), sim.slice_remaining);
    try std.testing.expectEqual(a, sim.scheduler.current_creature().?.slot_id);
    try std.testing.expectEqual(@as(u16, 1), mother.cpu.ip);
    try std.testing.expectEqual(@as(u8, 0), mother.cpu.fl);
    try std.testing.expectEqualDeep([4]u16{ 42, 43, 44, 45 }, [4]u16{ mother.cpu.ax, mother.cpu.bx, mother.cpu.cx, mother.cpu.dx });
    try std.testing.expectEqual(@as(u16, 1), mother.cpu.sp);
    try std.testing.expectEqual(@as(u16, 7), mother.cpu.stack[0]);
    try std.testing.expectEqual(@as(u32, 4), mother.errors);
    try std.testing.expectEqual(@as(u64, 12), mother.instructions_executed);
    try std.testing.expectEqual(@as(u64, 3), mother.instructions_copied);
    try std.testing.expectEqual(@as(u64, 41), sim.instructions_executed);
    try std.testing.expectEqual(identity + 1, sim.next_organism_id);
    try std.testing.expectEqual(occupied, sim.occupied_cells);
    try std.testing.expectEqualSlices(Instruction, &bytes, &sim.soup.memory);
    try simulationTestOrder(&sim, "slicer_node", &.{ child_slot, a, 1 });
    try simulationTestOrder(&sim, "reaper_node", &.{ 1, a, child_slot });
    try simulationTestPopulation(&sim);
    // The mother completes her existing slice before another creature runs.
    try std.testing.expectEqual(@as(u64, 2), try sim.run(2));
    try std.testing.expectEqual(@as(u16, 1), sim.scheduler.current_creature().?.slot_id);
    try std.testing.expectEqual(@as(u64, 0), sim.creatures[child_slot].?.instructions_executed);
    try std.testing.expect(try sim.step());
    try std.testing.expectEqual(child_slot, sim.scheduler.current_creature().?.slot_id);
}

test "simulation: rejected divisions are atomic apart from one VM error" {
    const Case = enum { missing, empty, outside, over_end, overlap, wrong_owner, no_slots, no_identity };
    inline for (std.meta.tags(Case)) |case| {
        var sim: TestSimulation = undefined;
        sim.init();
        const a = try sim.inoculate(&.{ .nop_0, .nop_0 }, 0);
        const mother = &sim.creatures[a].?;
        sim.mal_request(3, mother);
        switch (case) {
            .missing => mother.daughter_alloc = null,
            .empty => mother.daughter_alloc = .{ .start = 2, .len = 0 },
            .outside => mother.daughter_alloc = .{ .start = 16, .len = 1 },
            .over_end => mother.daughter_alloc = .{ .start = 15, .len = 2 },
            .overlap => mother.daughter_alloc = .{ .start = 1, .len = 3 },
            .wrong_owner => sim.soup.owner[4] = 7,
            .no_slots => sim.free_slots.items.len = 0,
            .no_identity => sim.next_organism_id = std.math.maxInt(u64),
        }
        const before = try simulationTestSnapshot(&sim);
        sim.divide(mother);
        var expected = before;
        expected.creatures[a].?.fl = 1;
        expected.creatures[a].?.errors = 1;
        try std.testing.expectEqualDeep(expected, try simulationTestSnapshot(&sim));
    }
}

test "simulation: death frees both allocations preserves code and handles current budget" {
    inline for (.{ false, true }) |kill_current| {
        var sim: TestSimulation = undefined;
        sim.init();
        const a = try sim.inoculate(&.{ .inc_a, .inc_b }, 0);
        const b = try sim.inoculate(&.{.zero}, 8);
        const victim = if (kill_current) a else b;
        sim.mal_request(3, &sim.creatures[victim].?);
        const memory = sim.soup.memory;
        sim.slice_remaining = 7;
        const time = sim.instructions_executed;
        const next_identity = sim.next_organism_id;
        try sim.kill(&sim.creatures[victim].?);
        try std.testing.expectEqualSlices(Instruction, &memory, &sim.soup.memory);
        try std.testing.expectEqual(@as(u16, if (kill_current) 1 else 2), sim.occupied_cells);
        try std.testing.expectEqual(@as(u64, if (kill_current) 0 else 7), sim.slice_remaining);
        try std.testing.expectEqual(time, sim.instructions_executed);
        try std.testing.expectEqual(next_identity, sim.next_organism_id);
        try std.testing.expectEqual(victim, sim.free_slots.getLast());
        const survivor = if (kill_current) b else a;
        try simulationTestOrder(&sim, "slicer_node", &.{survivor});
        try simulationTestOrder(&sim, "reaper_node", &.{survivor});
        try std.testing.expectEqual(survivor, sim.scheduler.current_creature().?.slot_id);
        try simulationTestPopulation(&sim);
    }
}

test "simulation: invalid deaths validate all memory before changing state" {
    const Case = enum { empty_mother, outside_mother, over_end_mother, empty_daughter, outside_daughter, over_end_daughter, overlap, foreign_mother, foreign_daughter };
    inline for (std.meta.tags(Case)) |case| {
        var sim: TestSimulation = undefined;
        sim.init();
        const a = try sim.inoculate(&.{ .nop_0, .nop_0 }, 0);
        const victim = &sim.creatures[a].?;
        sim.mal_request(3, victim);
        switch (case) {
            .empty_mother => victim.mother_alloc.len = 0,
            .outside_mother => victim.mother_alloc = .{ .start = 16, .len = 1 },
            .over_end_mother => victim.mother_alloc = .{ .start = 15, .len = 2 },
            .empty_daughter => victim.daughter_alloc.?.len = 0,
            .outside_daughter => victim.daughter_alloc = .{ .start = 16, .len = 1 },
            .over_end_daughter => victim.daughter_alloc = .{ .start = 15, .len = 2 },
            .overlap => victim.daughter_alloc = .{ .start = 1, .len = 2 },
            .foreign_mother => sim.soup.owner[1] = 7,
            .foreign_daughter => sim.soup.owner[4] = 7,
        }
        const before = try simulationTestSnapshot(&sim);
        const expected_error = switch (case) {
            .foreign_mother, .foreign_daughter => error.PermissionError,
            else => error.InvalidAllocation,
        };
        try std.testing.expectError(expected_error, sim.kill(victim));
        try std.testing.expectEqualDeep(before, try simulationTestSnapshot(&sim));
    }
}

test "simulation: death rejects detached inactive and out of range creature pointers" {
    var sim: TestSimulation = undefined;
    sim.init();
    const id = try sim.inoculate(&.{.zero}, 0);
    // Construct a detached value without copying an unused CPU stack.
    var detached: @TypeOf(sim.creatures[id].?) = .{
        .slot_id = id,
        .organism_id = 0,
        .cpu = .{},
        .mother_alloc = .{ .start = 0, .len = 1 },
        .daughter_alloc = null,
        .parent_genotype = null,
        .origin_time = 0,
    };
    const before = try simulationTestSnapshot(&sim);
    try std.testing.expectError(error.PermissionError, sim.kill(&detached));
    try std.testing.expectEqualDeep(before, try simulationTestSnapshot(&sim));
    detached.slot_id = 1;
    try std.testing.expectError(error.InvalidAllocation, sim.kill(&detached));
    try std.testing.expectEqualDeep(before, try simulationTestSnapshot(&sim));
    detached.slot_id = 16;
    try std.testing.expectError(error.InvalidAllocation, sim.kill(&detached));
    try std.testing.expectEqualDeep(before, try simulationTestSnapshot(&sim));
}

test "simulation: CPU faults and lifecycle failures count once and next success clears flag" {
    var sim: TestSimulation = undefined;
    sim.init();
    _ = try sim.inoculate(&.{.nop_0}, 8);
    _ = try sim.inoculate(&.{.nop_0}, 10);
    const id = try sim.inoculate(&.{ .pop_ax, .inc_a, .mal, .divide }, 0);
    sim.scheduler.advance();
    sim.scheduler.advance();
    sim.slice_remaining = 4;
    sim.instructions_executed = 10;
    const creature = &sim.creatures[id].?;
    creature.cpu.ax = 17;
    try std.testing.expect(try sim.step());
    try std.testing.expectEqual(@as(u16, 17), creature.cpu.ax);
    try std.testing.expectEqual(@as(u16, 0), creature.cpu.sp);
    try std.testing.expectEqual(@as(u8, 1), creature.cpu.fl);
    try std.testing.expectEqual(@as(u32, 1), creature.errors);
    try std.testing.expectEqual(@as(u16, 1), creature.cpu.ip);
    try std.testing.expectEqual(@as(u64, 1), creature.instructions_executed);
    try std.testing.expectEqual(@as(u64, 11), sim.instructions_executed);
    try simulationTestOrder(&sim, "reaper_node", &.{ 0, 2, 1 });
    try std.testing.expect(try sim.step());
    try std.testing.expectEqual(@as(u16, 18), creature.cpu.ax);
    try std.testing.expectEqual(@as(u8, 0), creature.cpu.fl);
    try std.testing.expectEqual(@as(u32, 1), creature.errors);
    try std.testing.expectEqual(@as(u16, 2), creature.cpu.ip);
    // cx is zero: CPU requests mal, then the simulation rejects it once.
    try std.testing.expect(try sim.step());
    try std.testing.expectEqual(@as(u32, 2), creature.errors);
    try std.testing.expectEqual(@as(u8, 1), creature.cpu.fl);
    try std.testing.expectEqual(@as(u16, 3), creature.cpu.ip);
    try std.testing.expectEqual(null, creature.daughter_alloc);
    try simulationTestOrder(&sim, "reaper_node", &.{ 2, 0, 1 });
    // Missing daughter is rejected by the CPU, without a second lifecycle error.
    try std.testing.expect(try sim.step());
    try std.testing.expectEqual(@as(u32, 3), creature.errors);
    try std.testing.expectEqual(@as(u8, 1), creature.cpu.fl);
    try std.testing.expectEqual(@as(u16, 4), creature.cpu.ip);
    try std.testing.expectEqual(@as(u64, 4), creature.instructions_executed);
    try std.testing.expectEqual(@as(u64, 14), sim.instructions_executed);
    try simulationTestPopulation(&sim);
}

test "simulation: simulation rejected divide advances and records exactly one error" {
    var sim: TestSimulation = undefined;
    sim.init();
    const id = try sim.inoculate(&.{ .divide, .inc_a }, 0);
    const creature = &sim.creatures[id].?;
    // Non-null means CPU forwards this to the simulation for validation.
    creature.daughter_alloc = .{ .start = 15, .len = 2 };
    var expected = try simulationTestSnapshot(&sim);
    expected.time = 1;
    expected.remaining = 1;
    expected.creatures[id].?.ip = 1;
    expected.creatures[id].?.fl = 1;
    expected.creatures[id].?.errors = 1;
    expected.creatures[id].?.executed = 1;
    try std.testing.expect(try sim.step());
    try std.testing.expectEqualDeep(expected, try simulationTestSnapshot(&sim));
}

test "simulation: successful addressing dispatches exactly one hard instruction reward" {
    var sim: TestSimulation = undefined;
    sim.init();
    @memset(&sim.soup.memory, .inc_a);
    const id = try sim.inoculate(&.{ .adrf, .nop_0, .inc_a }, 0);
    _ = try sim.inoculate(&.{.nop_0}, 8);
    _ = try sim.inoculate(&.{.nop_0}, 10);
    sim.soup.memory[4] = .nop_1;
    sim.creatures[id].?.cpu.fl = 1;
    const memory = sim.soup.memory;
    try std.testing.expect(try sim.step());
    const creature = &sim.creatures[id].?;
    try std.testing.expectEqual(@as(u16, 5), creature.cpu.ax);
    try std.testing.expectEqual(@as(u16, 1), creature.cpu.cx);
    try std.testing.expectEqual(@as(u16, 2), creature.cpu.ip);
    try std.testing.expectEqual(@as(u8, 0), creature.cpu.fl);
    try std.testing.expectEqual(@as(u32, 0), creature.errors);
    try std.testing.expectEqual(@as(u64, 1), creature.instructions_executed);
    try std.testing.expectEqual(@as(u64, 1), sim.instructions_executed);
    try std.testing.expectEqualSlices(Instruction, &memory, &sim.soup.memory);
    try simulationTestOrder(&sim, "reaper_node", &.{ 1, 0, 2 });
    try simulationTestPopulation(&sim);
}

test "simulation: permitted copies count once and denied copies preserve code and registers" {
    var sim: TestSimulation = undefined;
    sim.init();
    const id = try sim.inoculate(&.{ .mov_iab, .mov_iab, .inc_a }, 0);
    _ = try sim.inoculate(&.{.zero}, 10);
    const creature = &sim.creatures[id].?;
    creature.cpu.ax = 2;
    creature.cpu.bx = 10;
    try std.testing.expect(try sim.step());
    try std.testing.expectEqual(Instruction.zero, sim.soup.memory[2]);
    try std.testing.expectEqual(@as(u64, 1), creature.instructions_copied);
    try std.testing.expectEqual(@as(u16, 2), creature.cpu.ax);
    try std.testing.expectEqual(@as(u16, 10), creature.cpu.bx);
    try std.testing.expectEqual(@as(u8, 0), creature.cpu.fl);
    creature.cpu.ax = 10;
    creature.cpu.bx = 0;
    const bytes = sim.soup.memory;
    try std.testing.expect(try sim.step());
    try std.testing.expectEqualSlices(Instruction, &bytes, &sim.soup.memory);
    try std.testing.expectEqual(@as(u64, 1), creature.instructions_copied);
    try std.testing.expectEqual(@as(u64, 2), creature.instructions_executed);
    try std.testing.expectEqual(@as(u64, 2), sim.instructions_executed);
    try std.testing.expectEqual(@as(u16, 10), creature.cpu.ax);
    try std.testing.expectEqual(@as(u16, 0), creature.cpu.bx);
    try std.testing.expectEqual(@as(u16, 2), creature.cpu.ip);
    try std.testing.expectEqual(@as(u8, 1), creature.cpu.fl);
    try std.testing.expectEqual(@as(u32, 1), creature.errors);
    try simulationTestPopulation(&sim);
}

test "simulation: slice budgets floor fractional powers and saturate huge powers" {
    const cases = .{
        .{ .len = 9, .power = 0.5, .budget = 3 },
        .{ .len = 2, .power = 0.5, .budget = 1 },
        .{ .len = 2, .power = 0.0, .budget = 1 },
        .{ .len = 2, .power = 64.0, .budget = std.math.maxInt(u64) },
        .{ .len = 2, .power = 1024.0, .budget = std.math.maxInt(u64) },
    };
    inline for (cases) |case| {
        const config = comptime blk: {
            var config = simulation_test_config;
            config.slicer_power = case.power;
            config.reaper_threshold = 0.9;
            break :blk config;
        };
        var sim: Simulation(config) = undefined;
        sim.init();
        _ = try sim.inoculate(&(@as([case.len]Instruction, @splat(.nop_0))), 0);
        try std.testing.expect(try sim.step());
        try std.testing.expectEqual(@as(u64, case.budget - 1), sim.slice_remaining);
        try std.testing.expectEqual(@as(u64, 1), sim.instructions_executed);
        try simulationTestPopulation(&sim);
    }
}

test "simulation: round robin executes full length based slices" {
    var sim: TestSimulation = undefined;
    sim.init();
    _ = try sim.inoculate(&.{ .nop_0, .nop_0 }, 0);
    _ = try sim.inoculate(&.{ .nop_0, .nop_0, .nop_0 }, 8);
    @memset(&sim.soup.memory, .nop_0);
    const order = [_]u16{ 0, 0, 1, 1, 1, 0, 0, 1, 1, 1 };
    for (order) |id| {
        try std.testing.expectEqual(id, sim.scheduler.current_creature().?.slot_id);
        try std.testing.expect(try sim.step());
    }
    try std.testing.expectEqual(@as(u64, 4), sim.creatures[0].?.instructions_executed);
    try std.testing.expectEqual(@as(u64, 6), sim.creatures[1].?.instructions_executed);
    try std.testing.expectEqual(@as(u64, 10), sim.instructions_executed);
    try std.testing.expectEqual(@as(u64, 0), sim.slice_remaining);
    try std.testing.expectEqual(@as(u16, 0), sim.scheduler.current_creature().?.slot_id);
    try simulationTestPopulation(&sim);
}

test "simulation: occupancy equal to threshold does not reap at a slice boundary" {
    const config = comptime blk: {
        var config = simulation_test_config;
        config.reaper_threshold = 0.5;
        break :blk config;
    };
    var sim: Simulation(config) = undefined;
    sim.init();
    _ = try sim.inoculate(&.{ .nop_0, .nop_0 }, 0);
    _ = try sim.inoculate(&(@as([6]Instruction, @splat(.nop_0))), 8);
    try std.testing.expectEqual(@as(u64, 2), try sim.run(2));
    try std.testing.expectEqual(@as(u16, 8), sim.occupied_cells);
    try std.testing.expectEqual(@as(usize, 14), sim.free_slots.items.len);
    try std.testing.expectEqual(@as(u16, 1), sim.scheduler.current_creature().?.slot_id);
    try simulationTestPopulation(&sim);
}

test "simulation: reaping waits for boundary removes multiple victims and repairs next cursor" {
    const config = comptime blk: {
        var config = simulation_test_config;
        config.reaper_threshold = 0.5;
        break :blk config;
    };
    var sim: Simulation(config) = undefined;
    sim.init();
    _ = try sim.inoculate(&.{.nop_0}, 0);
    _ = try sim.inoculate(&.{.nop_0}, 1);
    _ = try sim.inoculate(&.{ .nop_0, .nop_0 }, 2);
    _ = try sim.inoculate(&(@as([8]Instruction, @splat(.nop_0))), 4);
    for (0..3) |_| sim.scheduler.advance();
    sim.slice_remaining = 2;
    const memory = sim.soup.memory;
    try std.testing.expect(try sim.step());
    try std.testing.expectEqual(@as(u16, 12), sim.occupied_cells);
    try std.testing.expectEqual(@as(u64, 1), sim.slice_remaining);
    try simulationTestOrder(&sim, "reaper_node", &.{ 0, 1, 2, 3 });
    try std.testing.expect(try sim.step());
    try std.testing.expectEqual(@as(u16, 8), sim.occupied_cells);
    try std.testing.expectEqual(@as(u64, 0), sim.slice_remaining);
    try std.testing.expectEqual(@as(u16, 3), sim.scheduler.current_creature().?.slot_id);
    try std.testing.expectEqual(@as(u64, 2), sim.creatures[3].?.instructions_executed);
    try std.testing.expectEqualSlices(Instruction, &memory, &sim.soup.memory);
    try std.testing.expectEqualSlices(u16, &.{ 0, 1, 2 }, sim.free_slots.items[sim.free_slots.items.len - 3 ..]);
    try simulationTestOrder(&sim, "slicer_node", &.{3});
    try simulationTestOrder(&sim, "reaper_node", &.{3});
    try simulationTestPopulation(&sim);
}

test "simulation: singleton extinction empties queues and counts the final instruction" {
    const config = comptime blk: {
        var config = simulation_test_config;
        config.reaper_threshold = 0.5;
        config.slicer_power = 0;
        break :blk config;
    };
    var sim: Simulation(config) = undefined;
    sim.init();
    _ = try sim.inoculate(&(@as([9]Instruction, @splat(.nop_0))), 0);
    const memory = sim.soup.memory;
    try std.testing.expectEqual(@as(u64, 1), try sim.run(20));
    try std.testing.expectEqual(@as(u64, 1), sim.instructions_executed);
    try std.testing.expectEqual(@as(u16, 0), sim.occupied_cells);
    try std.testing.expectEqual(@as(u64, 0), sim.slice_remaining);
    try std.testing.expectEqualSlices(Instruction, &memory, &sim.soup.memory);
    try simulationTestPopulation(&sim);
    const extinct = try simulationTestSnapshot(&sim);
    try std.testing.expect(!try sim.step());
    try std.testing.expectEqual(@as(u64, 0), try sim.run(20));
    try std.testing.expectEqualDeep(extinct, try simulationTestSnapshot(&sim));
}

test "simulation: empty and zero budget runs do not change state" {
    var sim: TestSimulation = undefined;
    sim.init();
    const empty = try simulationTestSnapshot(&sim);
    try std.testing.expect(!try sim.step());
    try std.testing.expectEqual(@as(u64, 0), try sim.run(100));
    try std.testing.expectEqual(@as(u64, 0), try sim.run(0));
    try std.testing.expectEqualDeep(empty, try simulationTestSnapshot(&sim));
    _ = try sim.inoculate(&.{.inc_a}, 0);
    sim.slice_remaining = 5;
    const live = try simulationTestSnapshot(&sim);
    try std.testing.expectEqual(@as(u64, 0), try sim.run(0));
    try std.testing.expectEqualDeep(live, try simulationTestSnapshot(&sim));
}

test "simulation: global time exhaustion is atomic and bounded run propagates it" {
    var sim: TestSimulation = undefined;
    sim.init();
    _ = try sim.inoculate(&.{ .inc_a, .nop_0 }, 0);
    sim.instructions_executed = global_max_instructions - 1;
    try std.testing.expectError(error.InstructionLimitReached, sim.run(2));
    try std.testing.expectEqual(global_max_instructions, sim.instructions_executed);
    try std.testing.expectEqual(@as(u64, 1), sim.creatures[0].?.instructions_executed);
    try std.testing.expectEqual(@as(u16, 1), sim.creatures[0].?.cpu.ax);
    try std.testing.expectEqual(@as(u16, 1), sim.creatures[0].?.cpu.ip);
    const at_limit = try simulationTestSnapshot(&sim);
    try std.testing.expectError(error.InstructionLimitReached, sim.step());
    try std.testing.expectEqualDeep(at_limit, try simulationTestSnapshot(&sim));
    try std.testing.expectError(error.InstructionLimitReached, sim.run(1));
    try std.testing.expectEqualDeep(at_limit, try simulationTestSnapshot(&sim));
    try std.testing.expectEqual(@as(u64, 0), try sim.run(0));
    try std.testing.expectEqualDeep(at_limit, try simulationTestSnapshot(&sim));
}

test "simulation: split run budgets preserve partial slices births and reaping boundaries" {
    const Scenario = enum { partial_slice, birth, reap_boundary };
    inline for (std.meta.tags(Scenario)) |scenario| {
        const config = comptime blk: {
            var config = simulation_test_config;
            config.reaper_threshold = 0.5;
            break :blk config;
        };
        var a: Simulation(config) = undefined;
        var b: Simulation(config) = undefined;
        a.init();
        b.init();
        // These are independent objects initialized in their final locations.
        for ([_]*Simulation(config){ &a, &b }) |sim| {
            @memset(&sim.soup.memory, .nop_0);
            switch (scenario) {
                .partial_slice => {
                    _ = try sim.inoculate(&.{ .inc_a, .inc_b, .nop_0 }, 0);
                    _ = try sim.inoculate(&.{ .inc_a, .inc_b }, 8);
                },
                .birth => {
                    const id = try sim.inoculate(&.{ .divide, .inc_a, .inc_b, .nop_0 }, 0);
                    sim.mal_request(2, &sim.creatures[id].?);
                },
                .reap_boundary => {
                    _ = try sim.inoculate(&.{ .nop_0, .nop_0 }, 0);
                    _ = try sim.inoculate(&(@as([7]Instruction, @splat(.nop_0))), 8);
                },
            }
        }
        const first: u64 = 1;
        const second: u64 = switch (scenario) {
            .partial_slice => 6,
            .birth => 2,
            .reap_boundary => 1,
        };
        try std.testing.expectEqual(first + second, try a.run(first + second));
        try std.testing.expectEqual(first, try b.run(first));
        try std.testing.expectEqual(second, try b.run(second));
        try std.testing.expectEqualDeep(try simulationTestSnapshot(&a), try simulationTestSnapshot(&b));
        // Continue both after the interrupted boundary as well.
        try std.testing.expectEqual(@as(u64, 3), try a.run(3));
        try std.testing.expectEqual(@as(u64, 3), try b.run(3));
        try std.testing.expectEqualDeep(try simulationTestSnapshot(&a), try simulationTestSnapshot(&b));
        try simulationTestPopulation(&a);
        try simulationTestPopulation(&b);
    }
}

test "simulation: ancestor self examination and two generations reproduce without mutations" {
    const genome = @import("ancestor.zig").ancestor_genome;
    const config = .{
        .soup_size = @as(u16, 4096),
        .stack_depth = @as(u16, 10),
        .search_limit = @as(u16, 300),
        .rng_seed = @as(u64, 12345),
        .reaper_threshold = @as(f32, 0.9),
        .slicer_power = @as(f32, 1),
        .cosmic_rate = @as(u32, 0),
        .copy_error_rate = @as(u32, 0),
        .flaw_rate = @as(f32, 0),
        .display_enabled = false,
        .lineage_enabled = false,
        .snapshot_interval = @as(u64, 0),
    };
    var sim: Simulation(config) = undefined;
    sim.init();
    @memset(&sim.soup.memory, .inc_a);
    const ancestor = try sim.inoculate(&genome, 0);
    var first_child: ?u16 = null;
    var saw_beginning = false;
    var saw_base = false;
    var saw_end = false;
    var saw_size = false;
    var saw_grandchild = false;
    while (sim.instructions_executed < 20_000) {
        const parent = sim.scheduler.current_creature() orelse return error.TestExpectedEqual;
        const parent_slot = parent.slot_id;
        const ip = parent.cpu.ip;
        const next_identity = sim.next_organism_id;
        const next_slot = sim.free_slots.getLast();
        const daughter_alloc = parent.daughter_alloc;
        const remaining = sim.slice_remaining;
        try std.testing.expect(try sim.step());
        if (parent_slot == ancestor) {
            switch (ip) {
                9 => {
                    try std.testing.expectEqual(@as(u16, 4), parent.cpu.ax);
                    saw_beginning = true;
                },
                14 => {
                    try std.testing.expectEqual(@as(u16, 0), parent.cpu.ax);
                    saw_base = true;
                },
                16 => {
                    try std.testing.expectEqual(@as(u16, 79), parent.cpu.ax);
                    saw_end = true;
                },
                22 => {
                    try std.testing.expectEqual(@as(u16, 80), parent.cpu.cx);
                    saw_size = true;
                },
                else => {},
            }
        }
        if (sim.next_organism_id != next_identity) {
            try std.testing.expectEqual(next_identity + 1, sim.next_organism_id);
            const allocation = daughter_alloc orelse return error.TestExpectedEqual;
            try simulationTestNewborn(&sim.creatures[next_slot].?, next_slot, next_identity, allocation, sim.instructions_executed);
            try std.testing.expectEqual(@as(u16, 80), allocation.len);
            try std.testing.expectEqualSlices(Instruction, &genome, sim.soup.memory[allocation.start .. @as(usize, allocation.start) + allocation.len]);
            try std.testing.expectEqual(null, parent.daughter_alloc);
            try std.testing.expectEqual(@as(u8, 0), parent.cpu.fl);
            try std.testing.expectEqual(@as(u32, 0), parent.errors);
            try std.testing.expectEqual(&parent.slicer_node, sim.creatures[next_slot].?.slicer_node.next);
            try std.testing.expectEqual(&sim.creatures[next_slot].?.reaper_node, sim.scheduler.reaper.last);
            if (remaining > 1) {
                try std.testing.expectEqual(remaining - 1, sim.slice_remaining);
                try std.testing.expectEqual(parent_slot, sim.scheduler.current_creature().?.slot_id);
            }
            try simulationTestPopulation(&sim);
            if (first_child == null) {
                try std.testing.expectEqual(ancestor, parent_slot);
                first_child = next_slot;
            } else if (parent_slot == first_child.?) {
                saw_grandchild = true;
                break;
            }
        }
    }
    if (!saw_grandchild) {
        std.debug.print("ancestor failed to produce a granddaughter within 20000 instructions (time={d}, first_child={any})\n", .{ sim.instructions_executed, first_child });
    }
    try std.testing.expect(saw_beginning and saw_base and saw_end and saw_size);
    try std.testing.expect(saw_grandchild);
    try std.testing.expectEqualSlices(Instruction, &genome, sim.soup.memory[0..80]);
}

test "simulation: accumulated errors saturate while fault processing continues" {
    var sim: TestSimulation = undefined;
    sim.init();
    const id = try sim.inoculate(&.{ .pop_ax, .inc_a }, 0);
    const creature = &sim.creatures[id].?;
    creature.errors = std.math.maxInt(u32);
    try std.testing.expect(try sim.step());
    try std.testing.expectEqual(std.math.maxInt(u32), creature.errors);
    try std.testing.expectEqual(@as(u8, 1), creature.cpu.fl);
    try std.testing.expectEqual(@as(u16, 1), creature.cpu.ip);
    try std.testing.expectEqual(@as(u64, 1), sim.instructions_executed);
}

test "simulation: execution counter saturates while instruction and global time advance" {
    var sim: TestSimulation = undefined;
    sim.init();
    const id = try sim.inoculate(&.{ .inc_a, .nop_0 }, 0);
    const creature = &sim.creatures[id].?;
    creature.instructions_executed = std.math.maxInt(u64);
    try std.testing.expect(try sim.step());
    try std.testing.expectEqual(std.math.maxInt(u64), creature.instructions_executed);
    try std.testing.expectEqual(@as(u64, 1), sim.instructions_executed);
    try std.testing.expectEqual(@as(u16, 1), creature.cpu.ax);
    try std.testing.expectEqual(@as(u16, 1), creature.cpu.ip);
    try std.testing.expectEqual(@as(u8, 0), creature.cpu.fl);
}

test "simulation: copy counter saturates while permitted copying and global time advance" {
    var sim: TestSimulation = undefined;
    sim.init();
    const id = try sim.inoculate(&.{ .mov_iab, .inc_a }, 0);
    const creature = &sim.creatures[id].?;
    creature.cpu.ax = 1;
    creature.cpu.bx = 0;
    creature.instructions_copied = std.math.maxInt(u64);
    try std.testing.expect(try sim.step());
    try std.testing.expectEqual(std.math.maxInt(u64), creature.instructions_copied);
    try std.testing.expectEqual(Instruction.mov_iab, sim.soup.memory[1]);
    try std.testing.expectEqual(@as(u64, 1), sim.instructions_executed);
    try std.testing.expectEqual(@as(u64, 1), creature.instructions_executed);
    try std.testing.expectEqual(@as(u16, 1), creature.cpu.ip);
    try std.testing.expectEqual(@as(u16, 1), creature.cpu.ax);
    try std.testing.expectEqual(@as(u16, 0), creature.cpu.bx);
    try std.testing.expectEqual(@as(u8, 0), creature.cpu.fl);
}
