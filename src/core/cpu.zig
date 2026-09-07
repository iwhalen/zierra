const std = @import("std");
const testing = std.testing;
const creature_module = @import("creature.zig");
const Creature = creature_module.Creature;
const CreatureId = creature_module.CreatureId;
const instruction_module = @import("instruction.zig");
const Instruction = instruction_module.Instruction;
const decode = instruction_module.decode;
const soup_module = @import("soup.zig");
const Soup = soup_module.Soup;
const Allocation = soup_module.Allocation;

pub const StackError = error{ StackOverflow, StackUnderflow };
pub const ExecutionError = error{NullInstructionError};

// Tracks if the execution result requires any extra work to be done
// by the simulation.
pub const ExecResult = union(enum) {
    // True if no extra work is needed from the simulation.
    none: bool,
    // Memory allocation request for new creature.
    divide: struct { daughter_alloc: Allocation },
    // Creature request for memory.
    mal_request: u16,
    // True if an instruction generated an error flag.
    error_condition: bool,
    // True if a creature successful executed a hard instruction (adr/mal).
    hard_instruction_success: bool,
};

pub fn CPU(comptime stack_depth: u16) type {
    if (comptime stack_depth <= 0) {
        @compileError("Stack depth must be positive.");
    }

    if (comptime stack_depth >= std.math.maxInt(u16)) {
        @compileError("Stack depth must fit in u16.");
    }

    return struct {
        const Self = @This();

        // Address registers.
        ax: u16 = 0x000,
        bx: u16 = 0x000,

        // Numerical registers.
        cx: u16 = 0x000,
        dx: u16 = 0x000,

        // Flags
        fl: u8 = 0x00,

        // Stack pointer
        sp: u8 = 0x00,

        stack: [stack_depth]?u16 = .{null} ** stack_depth,

        // Instruction pointer
        ip: u16 = 0x000,

        pub fn push(self: *Self, value: u16) StackError!void {
            if (self.sp == self.stack.len) {
                self.fl = 1;
                return StackError.StackOverflow;
            }

            self.stack[self.sp] = value;
            self.sp += 1;
            self.fl = 0;
        }

        pub fn pop(self: *Self) StackError!?u16 {
            if (self.sp == 0) {
                self.fl = 1;
                return StackError.StackUnderflow;
            }

            self.sp -= 1;
            self.fl = 0;
            return self.stack[self.sp];
        }

        pub fn step(self: *Self, soup: anytype, creature: anytype) !ExecResult {
            const read: ?Instruction = soup.read(self.ip);
            const instruction: Instruction = undefined;

            if (read == null) {
                return ExecutionError.NullInstructionError;
            } else {
                instruction = read;
            }

            const result = self.execute(instruction, soup, creature.id);

            if (self.ip == soup.len - 1) {
                self.ip = 0;
            } else {
                self.ip += 1;
            }

            creature.instructions_executed += 1;

            return result;
        }

        pub fn execute(self: *Self, instruction: Instruction, soup: anytype, creature_id: CreatureId) !ExecResult {
            
        }
    };
}

test "stack overflow" {
    var cpu = CPU(5){};

    for (0..5) |i| {
        try cpu.push(@intCast(i));
    }

    try testing.expectError(StackError.StackOverflow, cpu.push(0x000));
    try testing.expectEqual(1, cpu.fl);
}

test "stack underflow" {
    var cpu = CPU(5){};

    try cpu.push(1);
    _ = try cpu.pop();

    try testing.expectError(StackError.StackUnderflow, cpu.pop());
    try testing.expectEqual(1, cpu.fl);
}

test "push pop roundtrip" {
    var cpu = CPU(5){};

    try cpu.push(1);
    try cpu.push(2);

    try testing.expectEqual(2, cpu.pop());
    try testing.expectEqual(1, cpu.pop());
    try testing.expectEqual(0, cpu.fl);
}
