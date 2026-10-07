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
const template_module = @import("template.zig");
const count_nops_at = template_module.count_nops_at;
const wrap_increment = template_module.wrap_increment;
const search_bidirectional = template_module.search_bidirectional;
const search_backward = template_module.search_backward;
const pattern_length_at = template_module.pattern_length_at;

pub const StackError = error{ StackOverflow, StackUnderflow };
pub const ExecutionError = error{NullInstructionError};

// Tracks if the execution result requires any extra work to be done
// by the simulation.
pub const ExecResult = union(enum) {
    // True if no extra work is needed from the simulation.
    none,
    // Memory allocation request for new creature.
    divide: Allocation,
    // Creature request for memory.
    mal_request,
    // True if an instruction generated an error flag.
    error_condition,
    // True if a creature successful executed a hard instruction (adr/mal).
    hard_instruction_success,
};

pub fn CPU(comptime stack_depth: u16, comptime search_limit: u16) type {
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
        sp: u16 = 0x00,

        stack: [stack_depth]u16 = undefined,

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

        pub fn pop(self: *Self) StackError!u16 {
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
            var instruction: Instruction = undefined;

            if (read == null) {
                return ExecutionError.NullInstructionError;
            } else {
                instruction = read;
            }

            const result = self.execute(instruction, soup, creature);

            creature.instructions_executed += 1;

            return result;
        }

        pub fn execute(self: *Self, instruction: Instruction, soup: anytype, creature: anytype) ExecResult {
            _ = creature;

            switch (instruction) {
                // Plain register operations and no ops
                Instruction.nop_0, Instruction.nop_1 => return self.nop(soup.len),
                Instruction.or1 => return self.or1(soup.len),
                Instruction.shl => return self.shl(soup.len),
                Instruction.zero => return self.zero(soup.len),
                Instruction.sub_ab => return self.sub_ab(soup.len),
                Instruction.sub_ac => return self.sub_ac(soup.len),
                Instruction.inc_a => return self.inc_a(soup.len),
                Instruction.inc_b => return self.inc_b(soup.len),
                Instruction.dec_c => return self.dec_c(soup.len),
                Instruction.inc_c => return self.inc_c(soup.len),
                Instruction.mov_cd => return self.mov_cd(soup.len),
                Instruction.mov_ab => return self.mov_ab(soup.len),
                // Stack operations
                Instruction.push_ax => return self.execute_push(soup.len, self.ax),
                Instruction.push_bx => return self.execute_push(soup.len, self.bx),
                Instruction.push_cx => return self.execute_push(soup.len, self.cx),
                Instruction.push_dx => return self.execute_push(soup.len, self.dx),
                Instruction.pop_ax => return self.execute_pop(soup.len, &self.ax),
                Instruction.pop_bx => return self.execute_pop(soup.len, &self.bx),
                Instruction.pop_cx => return self.execute_pop(soup.len, &self.cx),
                Instruction.pop_dx => return self.execute_pop(soup.len, &self.dx),
                // Conditional skip
                Instruction.if_cz => return self.if_cz(soup),
                // Jumps
                Instruction.jmp => return self.jmp(soup),
                Instruction.jmpb => return self.jmpb(soup),
                Instruction.call => return self.call(soup),
                Instruction.ret => return self.ret(soup.len),
                // Address to register
                // Copy
                // Allocation
                // Divide
            }
        }

        pub fn advance_ip(self: *Self, increment: u16, soup_len: u16) void {
            self.ip = wrap_increment(self.ip, increment, soup_len);
        }

        pub fn nop(self: *Self, soup_len: u16) ExecResult {
            self.advance_ip(1, soup_len);
            return ExecResult.none;
        }

        pub fn or1(self: *Self, soup_len: u16) ExecResult {
            self.cx ^= 1;
            self.advance_ip(1, soup_len);
            return ExecResult.none;
        }

        pub fn shl(self: *Self, soup_len: u16) ExecResult {
            self.cx <<= 1;
            self.advance_ip(1, soup_len);
            return ExecResult.none;
        }

        pub fn zero(self: *Self, soup_len: u16) ExecResult {
            self.cx = 0;
            self.advance_ip(1, soup_len);
            return ExecResult.none;
        }

        pub fn sub_ab(self: *Self, soup_len: u16) ExecResult {
            self.cx = self.ax - self.bx;
            self.advance_ip(1, soup_len);
            return ExecResult.none;
        }

        pub fn sub_ac(self: *Self, soup_len: u16) ExecResult {
            self.ax = self.ax - self.cx;
            self.advance_ip(1, soup_len);
            return ExecResult.none;
        }

        pub fn inc_a(self: *Self, soup_len: u16) ExecResult {
            self.ax += 1;
            self.advance_ip(1, soup_len);
            return ExecResult.none;
        }

        pub fn inc_b(self: *Self, soup_len: u16) ExecResult {
            self.bx += 1;
            self.advance_ip(1, soup_len);
            return ExecResult.none;
        }

        pub fn dec_c(self: *Self, soup_len: u16) ExecResult {
            self.cx -= 1;
            self.advance_ip(1, soup_len);
            return ExecResult.none;
        }

        pub fn inc_c(self: *Self, soup_len: u16) ExecResult {
            self.cx += 1;
            self.advance_ip(1, soup_len);
            return ExecResult.none;
        }

        pub fn mov_cd(self: *Self, soup_len: u16) ExecResult {
            self.dx = self.cx;
            self.advance_ip(1, soup_len);
            return ExecResult.none;
        }

        pub fn mov_ab(self: *Self, soup_len: u16) ExecResult {
            self.bx = self.ax;
            self.advance_ip(1, soup_len);
            return ExecResult.none;
        }

        pub fn execute_push(self: *Self, soup_len: u16, value: u16) ExecResult {
            self.advance_ip(1, soup_len);

            self.push(value) catch {
                return ExecResult.error_condition;
            };

            return ExecResult.none;
        }

        pub fn execute_pop(self: *Self, soup_len: u16, destination: *u16) ExecResult {
            self.advance_ip(1, soup_len);

            const result = self.pop() catch {
                return ExecResult.error_condition;
            };

            destination.* = result;
            return ExecResult.none;
        }

        pub fn if_cz(self: *Self, soup: anytype) ExecResult {
            if (self.cx == 0) {
                self.advance_ip(1, soup.len);
                return ExecResult.none;
            }

            const skip_address = wrap_increment(self.ip, 1, soup.len);
            const skip_instruction = soup.read(skip_address);

            switch (skip_instruction) {
                Instruction.jmp, Instruction.jmpb, Instruction.call, Instruction.adr, Instruction.adrb, Instruction.adrf => {
                    const template_start = wrap_increment(skip_address, 1, soup.len);
                    const template_length = count_nops_at(soup, template_start, soup.len);
                    self.ip = wrap_increment(template_start, template_length, soup.len);
                },
                else => {
                    self.ip = wrap_increment(skip_address, 1, soup.len);
                },
            }

            return ExecResult.none;
        }

        pub fn execute_jump(self: *Self, soup: anytype, comptime search_fn: anytype) ExecResult {
            self.fl = 0;

            const search_start = wrap_increment(self.ip, 1, soup.len);
            const pattern_length = pattern_length_at(soup, search_start);

            // No NOPs were found, so we jump to the address in bx.
            if (pattern_length == 0) {
                self.ip = wrap_increment(self.bx, 0, soup.len);
                return ExecResult.none;
            }

            // Invalid pattern found, skip the operand.
            if (pattern_length == null) {
                const operand_length = count_nops_at(soup, search_start, soup.len);
                self.ip = wrap_increment(search_start, operand_length, soup.len);
                self.fl = 1;
                return ExecResult.error_condition;
            }

            const search_result = search_fn(soup, search_start, search_limit);

            // No matching template found, skip the operand.
            if (search_result == null) {
                self.ip = wrap_increment(search_start, pattern_length.?, soup.len);
                self.fl = 1;
                return ExecResult.error_condition;
            }

            self.ip = search_result.?;
            return ExecResult.none;
        }

        pub fn jmp(self: *Self, soup: anytype) ExecResult {
            return execute_jump(self, soup, search_bidirectional);
        }

        pub fn jmpb(self: *Self, soup: anytype) ExecResult {
            return execute_jump(self, soup, search_backward);
        }
    };
}

test "stack overflow" {
    var cpu = CPU(5, 500){};

    for (0..5) |i| {
        try cpu.push(@intCast(i));
    }

    try testing.expectError(StackError.StackOverflow, cpu.push(0x000));
    try testing.expectEqual(1, cpu.fl);
}

test "stack underflow" {
    var cpu = CPU(5, 500){};

    try cpu.push(1);
    _ = try cpu.pop();

    try testing.expectError(StackError.StackUnderflow, cpu.pop());
    try testing.expectEqual(1, cpu.fl);
}

test "push pop roundtrip" {
    var cpu = CPU(5, 500){};

    try cpu.push(1);
    try cpu.push(2);

    try testing.expectEqual(2, cpu.pop());
    try testing.expectEqual(1, cpu.pop());
    try testing.expectEqual(0, cpu.fl);
}

test "advance ip uses wrapped address" {
    var cpu = CPU(5, 500){ .ip = 99 };

    cpu.advance_ip(2, 100);

    try testing.expectEqual(1, cpu.ip);
}

//
// Disgusting AI generated unit tests.
//

test "empty jumps use normalized bx and clear the error flag" {
    var soup = Soup(7){};
    soup.memory[0] = Instruction.inc_a;
    soup.memory[6] = Instruction.jmp;

    inline for (.{ 0, 1, 100 }) |budget| {
        inline for (.{ false, true }) |backward| {
            var cpu = CPU(5, budget){ .ip = 6, .bx = 17, .fl = 1 };
            const result = if (backward) cpu.jmpb(&soup) else cpu.jmp(&soup);

            try testing.expect(result == .none);
            try testing.expectEqual(@as(u16, 3), cpu.ip);
            try testing.expectEqual(@as(u8, 0), cpu.fl);
            try testing.expectEqual(@as(u16, 17), cpu.bx);
        }
    }
}

test "failed jumps skip a nonempty operand and set the error flag" {
    var soup = Soup(7){};
    soup.memory = .{ Instruction.jmp, Instruction.nop_0, Instruction.nop_0, Instruction.inc_a, Instruction.inc_b, Instruction.zero, Instruction.ret };

    inline for (.{ false, true }) |backward| {
        var cpu = CPU(5, 100){ .bx = 5 };
        const result = if (backward) cpu.jmpb(&soup) else cpu.jmp(&soup);

        try testing.expect(result == .error_condition);
        try testing.expectEqual(@as(u16, 3), cpu.ip);
        try testing.expectEqual(@as(u8, 1), cpu.fl);
        try testing.expectEqual(@as(u16, 5), cpu.bx);
    }
}

test "jump direction chooses the appropriate successful match" {
    var soup = Soup(9){};
    soup.memory = .{Instruction.inc_a} ** 9;
    soup.memory[4] = Instruction.jmp;
    soup.memory[5] = Instruction.nop_0;
    soup.memory[7] = Instruction.nop_1;
    soup.memory[1] = Instruction.nop_1;

    inline for (.{ false, true }) |backward| {
        var cpu = CPU(5, 3){ .ip = 4, .bx = 42, .fl = 1 };
        const result = if (backward) cpu.jmpb(&soup) else cpu.jmp(&soup);

        try testing.expect(result == .none);
        try testing.expectEqual(@as(u16, if (backward) 2 else 8), cpu.ip);
        try testing.expectEqual(@as(u8, 0), cpu.fl);
        try testing.expectEqual(@as(u16, 42), cpu.bx);
    }
}

test "successful jumps handle a wrapped forward target and equal round matches" {
    var soup = Soup(9){};
    soup.memory = .{Instruction.inc_a} ** 9;
    soup.memory[7] = Instruction.jmp;
    soup.memory[8] = Instruction.nop_0;
    soup.memory[1] = Instruction.nop_1;
    soup.memory[5] = Instruction.nop_1;

    inline for (.{ false, true }) |backward| {
        var cpu = CPU(5, 2){ .ip = 7, .bx = 42, .fl = 1 };
        const result = if (backward) cpu.jmpb(&soup) else cpu.jmp(&soup);

        try testing.expect(result == .none);
        try testing.expectEqual(@as(u16, if (backward) 6 else 2), cpu.ip);
        try testing.expectEqual(@as(u8, 0), cpu.fl);
        try testing.expectEqual(@as(u16, 42), cpu.bx);
    }
}

test "failed jumps skip the full wrapped operand even with short budgets" {
    var soup = Soup(7){};
    soup.memory = .{ Instruction.nop_0, Instruction.inc_a, Instruction.inc_a, Instruction.inc_a, Instruction.inc_a, Instruction.jmp, Instruction.nop_0 };

    inline for (.{ 0, 1, 100 }) |budget| {
        inline for (.{ false, true }) |backward| {
            var cpu = CPU(5, budget){ .ip = 5, .bx = 3 };
            const result = if (backward) cpu.jmpb(&soup) else cpu.jmp(&soup);

            try testing.expect(result == .error_condition);
            try testing.expectEqual(@as(u16, 1), cpu.ip);
            try testing.expectEqual(@as(u8, 1), cpu.fl);
            try testing.expectEqual(@as(u16, 3), cpu.bx);
        }
    }
}

test "invalid all NOP jump input reports an error after a bounded traversal" {
    // Synthetic helper input: an actual jump opcode would terminate the NOP run.
    var soup = Soup(7){};
    soup.memory = .{Instruction.nop_0} ** 7;

    inline for (.{ 0, 100 }) |budget| {
        inline for (.{ false, true }) |backward| {
            var cpu = CPU(5, budget){ .ip = 5, .bx = 3 };
            const result = if (backward) cpu.jmpb(&soup) else cpu.jmp(&soup);

            try testing.expect(result == .error_condition);
            try testing.expectEqual(@as(u16, 6), cpu.ip);
            try testing.expectEqual(@as(u8, 1), cpu.fl);
            try testing.expectEqual(@as(u16, 3), cpu.bx);
        }
    }
}
