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
