const std = @import("std");

const CPU = @import("../core/cpu.zig").CPU;
const Creature = @import("../core/creature.zig").Creature;
const Instruction = @import("../core/instruction.zig").Instruction;
const soup_module = @import("../core/soup.zig");
const Soup = soup_module.Soup;
const SoupError = soup_module.SoupError;
const Scheduler = @import("./scheduler.zig").Scheduler;
const wrap_increment = @import("../core/template.zig").wrap_increment;

pub const SimulationError = error{
    NoFreeSlots,
    OrganismIdExhausted,
    InoculationFailure,
};

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
            if (creature.daughter_alloc == null) {
                creature.cpu.fl = 1;
                self.scheduler.on_error(creature);
                return;
            }

            if (creature.daughter_alloc.?.len == 0 or creature.daughter_alloc.?.start >= self.soup.len or creature.daughter_alloc.?.len > self.soup.len - creature.daughter_alloc.?.start) {
                creature.cpu.fl = 1;
                self.scheduler.on_error(creature);
                return;
            }

            //
            // Check if mother and daughter allocations overlap.
            // Cast to u32 to avoid complicated logic with wrapped ranges.
            //
            const mother_start = @as(u32, creature.mother_alloc.start);
            const mother_end = @as(u32, creature.mother_alloc.start + creature.mother_alloc.len);

            const daughter_start = @as(u32, creature.daughter_alloc.?.start);
            const daughter_end = @as(u32, creature.daughter_alloc.?.start + creature.daughter_alloc.?.len);

            if (mother_start < daughter_end and daughter_start < mother_end) {
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
    };
}

//
// AI generated unit tests.
//
