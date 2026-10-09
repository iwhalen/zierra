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
const wrap_decrement = template_module.wrap_decrement;
const search_bidirectional = template_module.search_bidirectional;
const search_backward = template_module.search_backward;
const search_forward = template_module.search_forward;
const pattern_length_at = template_module.pattern_length_at;

pub const StackError = error{ StackOverflow, StackUnderflow };

// Tracks if the execution result requires any extra work to be done
// by the simulation.
pub const ExecResult = union(enum) {
    // True if no extra work is needed from the simulation.
    none,
    // Memory allocation request for new creature.
    divide: Allocation,
    // Creature request for memory.
    mal_request: u16,
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
        }

        pub fn pop(self: *Self) StackError!u16 {
            if (self.sp == 0) {
                self.fl = 1;
                return StackError.StackUnderflow;
            }

            self.sp -= 1;
            return self.stack[self.sp];
        }

        pub fn step(self: *Self, soup: anytype, creature: anytype) ExecResult {
            const result = self.execute(soup.read(self.ip), soup, creature);

            creature.instructions_executed += 1;

            return result;
        }

        pub fn execute(self: *Self, instruction: Instruction, soup: anytype, creature: anytype) ExecResult {
            self.fl = 0;

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
                Instruction.adr => return self.adr(soup),
                Instruction.adrb => return self.adrb(soup),
                Instruction.adrf => return self.adrf(soup),
                // Copy
                Instruction.mov_iab => return self.mov_iab(soup, creature),
                // Allocation
                Instruction.mal => return self.mal(soup),
                // Divide
                Instruction.divide => return self.divide(soup, creature),
            }
        }

        pub fn advance_ip(self: *Self, increment: u16, soup_len: u16) void {
            self.ip = wrap_increment(self.ip, increment, soup_len);
        }

        pub fn nop(self: *Self, soup_len: u16) ExecResult {
            self.advance_ip(1, soup_len);
            return .{ .none = {} };
        }

        pub fn or1(self: *Self, soup_len: u16) ExecResult {
            self.cx ^= 1;
            self.advance_ip(1, soup_len);
            return .{ .none = {} };
        }

        pub fn shl(self: *Self, soup_len: u16) ExecResult {
            self.cx <<= 1;
            self.advance_ip(1, soup_len);
            return .{ .none = {} };
        }

        pub fn zero(self: *Self, soup_len: u16) ExecResult {
            self.cx = 0;
            self.advance_ip(1, soup_len);
            return .{ .none = {} };
        }

        pub fn sub_ab(self: *Self, soup_len: u16) ExecResult {
            self.cx = self.ax -% self.bx;
            self.advance_ip(1, soup_len);
            return .{ .none = {} };
        }

        pub fn sub_ac(self: *Self, soup_len: u16) ExecResult {
            self.ax = self.ax -% self.cx;
            self.advance_ip(1, soup_len);
            return .{ .none = {} };
        }

        pub fn inc_a(self: *Self, soup_len: u16) ExecResult {
            self.ax +%= 1;
            self.advance_ip(1, soup_len);
            return .{ .none = {} };
        }

        pub fn inc_b(self: *Self, soup_len: u16) ExecResult {
            self.bx +%= 1;
            self.advance_ip(1, soup_len);
            return .{ .none = {} };
        }

        pub fn dec_c(self: *Self, soup_len: u16) ExecResult {
            self.cx -%= 1;
            self.advance_ip(1, soup_len);
            return .{ .none = {} };
        }

        pub fn inc_c(self: *Self, soup_len: u16) ExecResult {
            self.cx +%= 1;
            self.advance_ip(1, soup_len);
            return .{ .none = {} };
        }

        pub fn mov_cd(self: *Self, soup_len: u16) ExecResult {
            self.dx = self.cx;
            self.advance_ip(1, soup_len);
            return .{ .none = {} };
        }

        pub fn mov_ab(self: *Self, soup_len: u16) ExecResult {
            self.bx = self.ax;
            self.advance_ip(1, soup_len);
            return .{ .none = {} };
        }

        pub fn execute_push(self: *Self, soup_len: u16, value: u16) ExecResult {
            self.advance_ip(1, soup_len);

            self.push(value) catch {
                return .{ .error_condition = {} };
            };

            return .{ .none = {} };
        }

        pub fn execute_pop(self: *Self, soup_len: u16, destination: *u16) ExecResult {
            self.advance_ip(1, soup_len);

            const result = self.pop() catch {
                return .{ .error_condition = {} };
            };

            destination.* = result;
            return .{ .none = {} };
        }

        pub fn if_cz(self: *Self, soup: anytype) ExecResult {
            if (self.cx == 0) {
                self.advance_ip(1, soup.len);
                return .{ .none = {} };
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

            return .{ .none = {} };
        }

        pub fn execute_jump(self: *Self, soup: anytype, comptime search_fn: anytype) ExecResult {
            const search_start = wrap_increment(self.ip, 1, soup.len);
            const pattern_length = pattern_length_at(soup, search_start);

            // No NOPs were found, so we jump to the address in bx.
            if (pattern_length == 0) {
                self.ip = wrap_increment(self.bx, 0, soup.len);
                return .{ .none = {} };
            }

            // Invalid pattern found, skip the operand.
            if (pattern_length == null) {
                const operand_length = count_nops_at(soup, search_start, soup.len);
                self.ip = wrap_increment(search_start, operand_length, soup.len);
                self.fl = 1;
                return .{ .error_condition = {} };
            }

            const search_result = search_fn(soup, search_start, search_limit);

            // No matching template found, skip the operand.
            if (search_result == null) {
                self.ip = wrap_increment(search_start, pattern_length.?, soup.len);
                self.fl = 1;
                return .{ .error_condition = {} };
            }

            self.ip = search_result.?;
            return .{ .none = {} };
        }

        pub fn jmp(self: *Self, soup: anytype) ExecResult {
            return execute_jump(self, soup, search_bidirectional);
        }

        pub fn jmpb(self: *Self, soup: anytype) ExecResult {
            return execute_jump(self, soup, search_backward);
        }

        pub fn call(self: *Self, soup: anytype) ExecResult {
            const search_start = wrap_increment(self.ip, 1, soup.len);
            const pattern_length = pattern_length_at(soup, search_start);

            // Operand is invalid, continue on and set error condition.
            if (pattern_length == null) {
                self.advance_ip(1, soup.len);
                self.fl = 1;
                return .{ .error_condition = {} };
            }

            const return_address = wrap_increment(search_start, pattern_length.?, soup.len);

            // Operand is empty...
            if (pattern_length == 0) {

                // ... attempt to push return address.
                self.push(return_address) catch {
                    // Stack was too full to push return address.
                    self.ip = return_address;
                    self.fl = 1;
                    return .{ .error_condition = {} };
                };

                self.ip = return_address;
                return .{ .none = {} };
            }

            const search_result = search_bidirectional(soup, search_start, search_limit);

            // Search found nothing, continue and set error condition.
            if (search_result == null) {
                self.ip = return_address;
                self.fl = 1;
                return .{ .error_condition = {} };
            }

            self.push(return_address) catch {
                // Stack was too full to push return address.
                self.ip = return_address;
                self.fl = 1;
                return .{ .error_condition = {} };
            };

            self.ip = search_result.?;
            return .{ .none = {} };
        }

        pub fn ret(self: *Self, soup_len: u16) ExecResult {
            const address = self.pop() catch {
                self.advance_ip(1, soup_len);
                return .{ .error_condition = {} };
            };

            self.ip = wrap_increment(address, 0, soup_len);
            return .{ .none = {} };
        }

        pub fn store_address(self: *Self, soup: anytype, comptime search_fn: anytype) ExecResult {
            const search_start = wrap_increment(self.ip, 1, soup.len);
            const pattern_length = pattern_length_at(soup, search_start);

            // Operand is empty, continue on without setting error condition.
            if (pattern_length == 0) {
                self.advance_ip(1, soup.len);
                return .{ .none = {} };
            }

            // Operand is invalid, continue after template and set error.
            if (pattern_length == null) {
                const operand_length = count_nops_at(soup, search_start, soup.len);
                self.ip = wrap_increment(search_start, operand_length, soup.len);
                self.fl = 1;
                return .{ .error_condition = {} };
            }

            const search_result = search_fn(soup, search_start, search_limit);

            // No matching template found, skip the operand.
            if (search_result == null) {
                self.ip = wrap_increment(search_start, pattern_length.?, soup.len);
                self.fl = 1;
                return .{ .error_condition = {} };
            }

            self.ax = search_result.?;
            self.cx = pattern_length.?;

            self.ip = wrap_increment(search_start, pattern_length.?, soup.len);

            return .{ .hard_instruction_success = {} };
        }

        pub fn adr(self: *Self, soup: anytype) ExecResult {
            return self.store_address(soup, search_bidirectional);
        }

        pub fn adrb(self: *Self, soup: anytype) ExecResult {
            return self.store_address(soup, search_backward);
        }

        pub fn adrf(self: *Self, soup: anytype) ExecResult {
            return self.store_address(soup, search_forward);
        }

        pub fn mov_iab(self: *Self, soup: anytype, creature: anytype) ExecResult {
            const address_ax = wrap_increment(self.ax, 0, soup.len);
            const address_bx = wrap_increment(self.bx, 0, soup.len);
            const instruction = soup.read(address_bx);

            var copy_increment: u16 = 1;
            var return_value = ExecResult{ .none = {} };

            soup.write(address_ax, instruction, creature.id) catch {
                return_value = ExecResult{ .error_condition = {} };
                self.fl = 1;
                copy_increment = 0;
            };

            creature.instructions_copied += copy_increment;
            self.advance_ip(1, soup.len);

            return return_value;
        }

        pub fn mal(self: *Self, soup: anytype) ExecResult {
            self.advance_ip(1, soup.len);
            return ExecResult{ .mal_request = self.cx };
        }

        pub fn divide(self: *Self, soup: anytype, creature: anytype) ExecResult {
            self.advance_ip(1, soup.len);

            if (creature.daughter_alloc == null) {
                self.fl = 1;
                return .{ .error_condition = {} };
            }

            return ExecResult{ .divide = creature.daughter_alloc.? };
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
// AI generated unit tests.
//

fn test_creature(comptime stack_depth: u16, comptime search_limit: u16) Creature(CPU(stack_depth, search_limit)) {
    return .{
        .id = 1,
        .cpu = CPU(stack_depth, search_limit){},
        .mother_alloc = .{ .start = 0, .len = 1 },
        .daughter_alloc = null,
        .parent_genotype = null,
        .origin_time = 0,
    };
}

fn run_opcode(creature: anytype, soup: anytype, opcode: Instruction) ExecResult {
    soup.memory[creature.cpu.ip] = opcode;
    return creature.cpu.step(soup, creature);
}

test "both NOP opcodes advance once and clear the previous flag" {
    var soup = Soup(3){};
    var creature = test_creature(5, 3);
    creature.cpu = .{ .ip = 2, .fl = 1 };

    try testing.expect(run_opcode(&creature, &soup, .nop_0) == .none);
    try testing.expectEqual(@as(u16, 0), creature.cpu.ip);
    try testing.expectEqual(@as(u8, 0), creature.cpu.fl);
    try testing.expect(run_opcode(&creature, &soup, .nop_1) == .none);
    try testing.expectEqual(@as(u16, 1), creature.cpu.ip);
    try testing.expectEqual(@as(u16, 2), creature.instructions_executed);
}

test "bit operations change only cx and discard shifted high bits" {
    var soup = Soup(5){};
    var creature = test_creature(5, 5);
    creature.cpu = .{ .ax = 7, .bx = 8, .cx = 0x8001, .dx = 9 };

    try testing.expect(run_opcode(&creature, &soup, .or1) == .none);
    try testing.expectEqual(@as(u16, 0x8000), creature.cpu.cx);
    try testing.expect(run_opcode(&creature, &soup, .or1) == .none);
    try testing.expectEqual(@as(u16, 0x8001), creature.cpu.cx);
    try testing.expect(run_opcode(&creature, &soup, .shl) == .none);
    try testing.expectEqual(@as(u16, 2), creature.cpu.cx);
    try testing.expect(run_opcode(&creature, &soup, .zero) == .none);
    try testing.expectEqual(@as(u16, 0), creature.cpu.cx);
    try testing.expectEqual(@as(u16, 7), creature.cpu.ax);
    try testing.expectEqual(@as(u16, 8), creature.cpu.bx);
    try testing.expectEqual(@as(u16, 9), creature.cpu.dx);
    try testing.expectEqual(@as(u16, 4), creature.cpu.ip);
    try testing.expectEqual(@as(u16, 4), creature.instructions_executed);
}

test "subtractions place the result in the specified register" {
    var soup = Soup(4){};
    var creature = test_creature(5, 4);
    creature.cpu = .{ .ax = 9, .bx = 4, .cx = 99 };

    try testing.expect(run_opcode(&creature, &soup, .sub_ab) == .none);
    try testing.expectEqual(@as(u16, 5), creature.cpu.cx);
    try testing.expectEqual(@as(u16, 9), creature.cpu.ax);
    try testing.expect(run_opcode(&creature, &soup, .sub_ac) == .none);
    try testing.expectEqual(@as(u16, 4), creature.cpu.ax);
    try testing.expectEqual(@as(u16, 5), creature.cpu.cx);
    try testing.expectEqual(@as(u16, 4), creature.cpu.bx);
    try testing.expectEqual(@as(u16, 2), creature.cpu.ip);
    try testing.expectEqual(@as(u16, 2), creature.instructions_executed);
}

test "sub_ab wraps at 16 bits" {
    var soup = Soup(3){};
    var creature = test_creature(5, 3);
    creature.cpu = .{ .ax = 2, .bx = 5 };

    try testing.expect(run_opcode(&creature, &soup, .sub_ab) == .none);
    try testing.expectEqual(@as(u16, 0xfffd), creature.cpu.cx);
    try testing.expectEqual(@as(u16, 1), creature.cpu.ip);
}

test "sub_ac wraps at 16 bits" {
    var soup = Soup(3){};
    var creature = test_creature(5, 3);
    creature.cpu = .{ .ax = 0, .cx = 1 };

    try testing.expect(run_opcode(&creature, &soup, .sub_ac) == .none);
    try testing.expectEqual(@as(u16, 0xffff), creature.cpu.ax);
    try testing.expectEqual(@as(u16, 1), creature.cpu.cx);
    try testing.expectEqual(@as(u16, 1), creature.cpu.ip);
}

test "increments and decrement affect only their target registers" {
    var soup = Soup(5){};
    var creature = test_creature(5, 5);
    creature.cpu = .{ .ax = 2, .bx = 3, .cx = 1 };

    try testing.expect(run_opcode(&creature, &soup, .inc_a) == .none);
    try testing.expectEqual(@as(u16, 3), creature.cpu.ax);
    try testing.expect(run_opcode(&creature, &soup, .inc_b) == .none);
    try testing.expectEqual(@as(u16, 4), creature.cpu.bx);
    try testing.expect(run_opcode(&creature, &soup, .inc_c) == .none);
    try testing.expectEqual(@as(u16, 2), creature.cpu.cx);
    try testing.expect(run_opcode(&creature, &soup, .dec_c) == .none);
    try testing.expectEqual(@as(u16, 1), creature.cpu.cx);
    try testing.expectEqual(@as(u16, 3), creature.cpu.ax);
    try testing.expectEqual(@as(u16, 4), creature.cpu.bx);
    try testing.expectEqual(@as(u16, 4), creature.cpu.ip);
    try testing.expectEqual(@as(u16, 4), creature.instructions_executed);
}

test "inc_a wraps at 16 bits" {
    var soup = Soup(3){};
    var creature = test_creature(5, 3);
    creature.cpu.ax = 0xffff;
    try testing.expect(run_opcode(&creature, &soup, .inc_a) == .none);
    try testing.expectEqual(@as(u16, 0), creature.cpu.ax);
}

test "inc_b wraps at 16 bits" {
    var soup = Soup(3){};
    var creature = test_creature(5, 3);
    creature.cpu.bx = 0xffff;
    try testing.expect(run_opcode(&creature, &soup, .inc_b) == .none);
    try testing.expectEqual(@as(u16, 0), creature.cpu.bx);
}

test "inc_c wraps at 16 bits" {
    var soup = Soup(3){};
    var creature = test_creature(5, 3);
    creature.cpu.cx = 0xffff;
    try testing.expect(run_opcode(&creature, &soup, .inc_c) == .none);
    try testing.expectEqual(@as(u16, 0), creature.cpu.cx);
}

test "dec_c wraps at 16 bits" {
    var soup = Soup(3){};
    var creature = test_creature(5, 3);
    try testing.expect(run_opcode(&creature, &soup, .dec_c) == .none);
    try testing.expectEqual(@as(u16, 0xffff), creature.cpu.cx);
}

test "register moves copy values without changing their sources" {
    var soup = Soup(3){};
    var creature = test_creature(5, 3);
    creature.cpu = .{ .ax = 7, .bx = 22, .cx = 13, .dx = 44 };

    try testing.expect(run_opcode(&creature, &soup, .mov_cd) == .none);
    try testing.expect(run_opcode(&creature, &soup, .mov_ab) == .none);
    try testing.expectEqual(@as(u16, 7), creature.cpu.ax);
    try testing.expectEqual(@as(u16, 7), creature.cpu.bx);
    try testing.expectEqual(@as(u16, 13), creature.cpu.cx);
    try testing.expectEqual(@as(u16, 13), creature.cpu.dx);
    try testing.expectEqual(@as(u16, 2), creature.cpu.ip);
}

test "all push and pop opcodes preserve stack order" {
    var soup = Soup(9){};
    var creature = test_creature(4, 9);
    creature.cpu = .{ .ax = 11, .bx = 22, .cx = 33, .dx = 44 };

    inline for (.{ Instruction.push_ax, Instruction.push_bx, Instruction.push_cx, Instruction.push_dx }) |opcode| {
        try testing.expect(run_opcode(&creature, &soup, opcode) == .none);
    }
    try testing.expectEqual(@as(u16, 4), creature.cpu.sp);
    creature.cpu.ax = 0;
    creature.cpu.bx = 0;
    creature.cpu.cx = 0;
    creature.cpu.dx = 0;
    inline for (.{ Instruction.pop_dx, Instruction.pop_cx, Instruction.pop_bx, Instruction.pop_ax }) |opcode| {
        try testing.expect(run_opcode(&creature, &soup, opcode) == .none);
    }
    try testing.expectEqual(@as(u16, 11), creature.cpu.ax);
    try testing.expectEqual(@as(u16, 22), creature.cpu.bx);
    try testing.expectEqual(@as(u16, 33), creature.cpu.cx);
    try testing.expectEqual(@as(u16, 44), creature.cpu.dx);
    try testing.expectEqual(@as(u16, 0), creature.cpu.sp);
    try testing.expectEqual(@as(u16, 8), creature.cpu.ip);
    try testing.expectEqual(@as(u16, 8), creature.instructions_executed);
}

test "failed stack instructions advance and preserve stack and destination" {
    var soup = Soup(4){};
    var creature = test_creature(2, 4);
    creature.cpu = .{ .ax = 42, .sp = 2 };
    creature.cpu.stack[0] = 11;
    creature.cpu.stack[1] = 22;

    try testing.expect(run_opcode(&creature, &soup, .push_ax) == .error_condition);
    try testing.expectEqual(@as(u16, 1), creature.cpu.ip);
    try testing.expectEqual(@as(u16, 2), creature.cpu.sp);
    try testing.expectEqual(@as(u16, 11), creature.cpu.stack[0]);
    try testing.expectEqual(@as(u16, 22), creature.cpu.stack[1]);
    try testing.expectEqual(@as(u8, 1), creature.cpu.fl);

    creature.cpu.sp = 0;
    try testing.expect(run_opcode(&creature, &soup, .pop_ax) == .error_condition);
    try testing.expectEqual(@as(u16, 2), creature.cpu.ip);
    try testing.expectEqual(@as(u16, 0), creature.cpu.sp);
    try testing.expectEqual(@as(u16, 42), creature.cpu.ax);
    try testing.expectEqual(@as(u16, 11), creature.cpu.stack[0]);
    try testing.expectEqual(@as(u16, 22), creature.cpu.stack[1]);
    try testing.expectEqual(@as(u8, 1), creature.cpu.fl);
    try testing.expectEqual(@as(u16, 2), creature.instructions_executed);
}

test "if_cz executes the next opcode only when cx is zero" {
    var soup = Soup(5){};
    soup.memory[1] = .inc_a;
    var creature = test_creature(5, 5);

    try testing.expect(run_opcode(&creature, &soup, .if_cz) == .none);
    try testing.expectEqual(@as(u16, 1), creature.cpu.ip);
    try testing.expect(creature.cpu.step(&soup, &creature) == .none);
    try testing.expectEqual(@as(u16, 1), creature.cpu.ax);
    try testing.expectEqual(@as(u16, 2), creature.instructions_executed);

    creature.cpu = .{ .cx = 1 };
    creature.instructions_executed = 0;
    try testing.expect(run_opcode(&creature, &soup, .if_cz) == .none);
    try testing.expectEqual(@as(u16, 2), creature.cpu.ip);
    try testing.expectEqual(@as(u16, 0), creature.cpu.ax);
    try testing.expectEqual(@as(u16, 1), creature.instructions_executed);
}

test "if_cz skips a complete template without executing any skipped cell" {
    inline for (.{ Instruction.jmp, Instruction.jmpb, Instruction.call, Instruction.adr, Instruction.adrb, Instruction.adrf }) |skipped_opcode| {
        var soup = Soup(7){};
        soup.memory = .{ .inc_a, skipped_opcode, .nop_0, .nop_1, .inc_a, .inc_a, .inc_a };
        var creature = test_creature(5, 7);
        creature.cpu = .{ .ax = 23, .cx = 1, .fl = 1 };

        try testing.expect(run_opcode(&creature, &soup, .if_cz) == .none);
        try testing.expectEqual(@as(u16, 4), creature.cpu.ip);
        try testing.expectEqual(@as(u16, 23), creature.cpu.ax);
        try testing.expectEqual(@as(u16, 1), creature.cpu.cx);
        try testing.expectEqual(@as(u8, 0), creature.cpu.fl);
        try testing.expectEqual(@as(u16, 0), creature.cpu.sp);
        try testing.expectEqual(@as(u16, 1), creature.instructions_executed);
    }

    var soup = Soup(7){};
    soup.memory = .{ .nop_0, .nop_1, .inc_a, .inc_a, .inc_a, .inc_a, .jmp };
    var creature = test_creature(5, 7);
    creature.cpu = .{ .ip = 5, .cx = 1 };
    try testing.expect(run_opcode(&creature, &soup, .if_cz) == .none);
    try testing.expectEqual(@as(u16, 2), creature.cpu.ip);
    try testing.expectEqual(@as(u16, 1), creature.instructions_executed);
}

test "empty jumps use normalized bx and clear the error flag" {
    var soup = Soup(7){};
    soup.memory[0] = Instruction.inc_a;

    inline for (.{ 0, 1, 100 }) |budget| {
        inline for (.{ false, true }) |backward| {
            var creature = test_creature(5, budget);
            creature.cpu = .{ .ip = 6, .bx = 17, .fl = 1 };
            const result = run_opcode(&creature, &soup, if (backward) .jmpb else .jmp);

            try testing.expect(result == .none);
            try testing.expectEqual(@as(u16, 3), creature.cpu.ip);
            try testing.expectEqual(@as(u8, 0), creature.cpu.fl);
            try testing.expectEqual(@as(u16, 17), creature.cpu.bx);
            try testing.expectEqual(@as(u16, 1), creature.instructions_executed);
        }
    }
}

test "failed jumps skip a nonempty operand and set the error flag" {
    var soup = Soup(7){};
    soup.memory = .{ Instruction.jmp, Instruction.nop_0, Instruction.nop_0, Instruction.inc_a, Instruction.inc_b, Instruction.zero, Instruction.ret };

    inline for (.{ false, true }) |backward| {
        var creature = test_creature(5, 100);
        creature.cpu.bx = 5;
        const result = run_opcode(&creature, &soup, if (backward) .jmpb else .jmp);

        try testing.expect(result == .error_condition);
        try testing.expectEqual(@as(u16, 3), creature.cpu.ip);
        try testing.expectEqual(@as(u8, 1), creature.cpu.fl);
        try testing.expectEqual(@as(u16, 5), creature.cpu.bx);
        try testing.expectEqual(@as(u16, 1), creature.instructions_executed);
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
        var creature = test_creature(5, 3);
        creature.cpu = .{ .ip = 4, .bx = 42, .fl = 1 };
        const result = run_opcode(&creature, &soup, if (backward) .jmpb else .jmp);

        try testing.expect(result == .none);
        try testing.expectEqual(@as(u16, if (backward) 2 else 8), creature.cpu.ip);
        try testing.expectEqual(@as(u8, 0), creature.cpu.fl);
        try testing.expectEqual(@as(u16, 42), creature.cpu.bx);
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
        var creature = test_creature(5, 2);
        creature.cpu = .{ .ip = 7, .bx = 42, .fl = 1 };
        const result = run_opcode(&creature, &soup, if (backward) .jmpb else .jmp);

        try testing.expect(result == .none);
        try testing.expectEqual(@as(u16, if (backward) 6 else 2), creature.cpu.ip);
        try testing.expectEqual(@as(u8, 0), creature.cpu.fl);
        try testing.expectEqual(@as(u16, 42), creature.cpu.bx);
    }
}

test "template search respects the candidate round limit" {
    var soup = Soup(9){};
    soup.memory = .{Instruction.inc_a} ** 9;
    soup.memory[5] = .nop_0;
    soup.memory[7] = .nop_1;

    inline for (.{ Instruction.jmp, Instruction.adrf }) |opcode| {
        var too_short = test_creature(5, 1);
        too_short.cpu = .{ .ip = 4, .ax = 55, .cx = 99 };
        try testing.expect(run_opcode(&too_short, &soup, opcode) == .error_condition);
        try testing.expectEqual(@as(u16, 6), too_short.cpu.ip);
        try testing.expectEqual(@as(u16, 55), too_short.cpu.ax);
        try testing.expectEqual(@as(u16, 99), too_short.cpu.cx);
        try testing.expectEqual(@as(u8, 1), too_short.cpu.fl);

        var enough = test_creature(5, 2);
        enough.cpu.ip = 4;
        const result = run_opcode(&enough, &soup, opcode);
        try testing.expect(result == if (opcode == .jmp) ExecResult.none else ExecResult.hard_instruction_success);
        try testing.expectEqual(@as(u16, if (opcode == .jmp) 8 else 6), enough.cpu.ip);
        if (opcode == .adrf) {
            try testing.expectEqual(@as(u16, 8), enough.cpu.ax);
            try testing.expectEqual(@as(u16, 1), enough.cpu.cx);
        }
    }
}

test "failed jumps skip the full wrapped operand even with short budgets" {
    var soup = Soup(7){};
    soup.memory = .{ Instruction.nop_0, Instruction.inc_a, Instruction.inc_a, Instruction.inc_a, Instruction.inc_a, Instruction.jmp, Instruction.nop_0 };

    inline for (.{ 0, 1, 100 }) |budget| {
        inline for (.{ false, true }) |backward| {
            var creature = test_creature(5, budget);
            creature.cpu = .{ .ip = 5, .bx = 3 };
            const result = run_opcode(&creature, &soup, if (backward) .jmpb else .jmp);

            try testing.expect(result == .error_condition);
            try testing.expectEqual(@as(u16, 1), creature.cpu.ip);
            try testing.expectEqual(@as(u8, 1), creature.cpu.fl);
            try testing.expectEqual(@as(u16, 3), creature.cpu.bx);
        }
    }
}

test "invalid all NOP jump input reports an error after a bounded traversal" {
    // Synthetic helper input: an actual jump opcode would terminate the NOP run.
    var soup = Soup(7){};
    soup.memory = .{Instruction.nop_0} ** 7;

    inline for (.{ 0, 100 }) |budget| {
        inline for (.{ false, true }) |backward| {
            var creature = test_creature(5, budget);
            creature.cpu = .{ .ip = 5, .bx = 3 };
            const result = if (backward) creature.cpu.jmpb(&soup) else creature.cpu.jmp(&soup);

            try testing.expect(result == .error_condition);
            try testing.expectEqual(@as(u16, 6), creature.cpu.ip);
            try testing.expectEqual(@as(u8, 1), creature.cpu.fl);
            try testing.expectEqual(@as(u16, 3), creature.cpu.bx);
        }
    }
}

test "call finds a complementary template and ret uses its return address" {
    var soup = Soup(10){};
    soup.memory = .{Instruction.inc_a} ** 10;
    soup.memory[4] = .nop_0;
    soup.memory[7] = .nop_1;
    var creature = test_creature(5, 3);
    creature.cpu.ip = 3;

    try testing.expect(run_opcode(&creature, &soup, .call) == .none);
    try testing.expectEqual(@as(u16, 8), creature.cpu.ip);
    try testing.expectEqual(@as(u16, 1), creature.cpu.sp);
    try testing.expectEqual(@as(u16, 5), creature.cpu.stack[0]);
    try testing.expectEqual(@as(u16, 1), creature.instructions_executed);

    try testing.expect(run_opcode(&creature, &soup, .ret) == .none);
    try testing.expectEqual(@as(u16, 5), creature.cpu.ip);
    try testing.expectEqual(@as(u16, 0), creature.cpu.sp);
    try testing.expectEqual(@as(u16, 2), creature.instructions_executed);
}

test "empty call pushes the next address and ret normalizes a popped address" {
    var soup = Soup(10){};
    soup.memory = .{Instruction.inc_a} ** 10;
    var creature = test_creature(5, 0);
    creature.cpu.ip = 3;

    try testing.expect(run_opcode(&creature, &soup, .call) == .none);
    try testing.expectEqual(@as(u16, 4), creature.cpu.ip);
    try testing.expectEqual(@as(u16, 1), creature.cpu.sp);
    try testing.expectEqual(@as(u16, 4), creature.cpu.stack[0]);
    try testing.expectEqual(@as(u8, 0), creature.cpu.fl);

    creature.cpu.sp = 0;
    creature.cpu.ip = 1;
    try creature.cpu.push(27);
    try testing.expect(run_opcode(&creature, &soup, .ret) == .none);
    try testing.expectEqual(@as(u16, 7), creature.cpu.ip);
    try testing.expectEqual(@as(u16, 0), creature.cpu.sp);
}

test "failed call leaves the stack intact and continues after its operand" {
    var soup = Soup(7){};
    soup.memory = .{Instruction.inc_a} ** 7;
    soup.memory[1] = .nop_0;
    var creature = test_creature(5, 7);
    try creature.cpu.push(77);

    try testing.expect(run_opcode(&creature, &soup, .call) == .error_condition);
    try testing.expectEqual(@as(u16, 2), creature.cpu.ip);
    try testing.expectEqual(@as(u16, 1), creature.cpu.sp);
    try testing.expectEqual(@as(u16, 77), creature.cpu.stack[0]);
    try testing.expectEqual(@as(u8, 1), creature.cpu.fl);
    try testing.expectEqual(@as(u16, 1), creature.instructions_executed);
}

test "full stack prevents call from jumping even when a template matches" {
    var soup = Soup(10){};
    soup.memory = .{Instruction.inc_a} ** 10;
    soup.memory[4] = .nop_0;
    soup.memory[7] = .nop_1;
    var creature = test_creature(1, 3);
    creature.cpu.ip = 3;
    try creature.cpu.push(77);

    try testing.expect(run_opcode(&creature, &soup, .call) == .error_condition);
    try testing.expectEqual(@as(u16, 5), creature.cpu.ip);
    try testing.expectEqual(@as(u16, 1), creature.cpu.sp);
    try testing.expectEqual(@as(u16, 77), creature.cpu.stack[0]);
    try testing.expectEqual(@as(u8, 1), creature.cpu.fl);
}

test "ret on an empty stack reports an error and advances once" {
    var soup = Soup(3){};
    var creature = test_creature(5, 3);
    creature.cpu.ip = 2;

    try testing.expect(run_opcode(&creature, &soup, .ret) == .error_condition);
    try testing.expectEqual(@as(u16, 0), creature.cpu.ip);
    try testing.expectEqual(@as(u16, 0), creature.cpu.sp);
    try testing.expectEqual(@as(u8, 1), creature.cpu.fl);
    try testing.expectEqual(@as(u16, 1), creature.instructions_executed);
}

test "adr variants select their direction and store match end and operand length" {
    var soup = Soup(9){};
    soup.memory = .{Instruction.inc_a} ** 9;
    soup.memory[5] = .nop_0;
    soup.memory[7] = .nop_1;
    soup.memory[1] = .nop_1;

    inline for (.{ Instruction.adr, Instruction.adrb, Instruction.adrf }) |opcode| {
        var creature = test_creature(5, 3);
        creature.cpu = .{ .ip = 4, .ax = 55, .bx = 12, .cx = 99, .fl = 1 };
        const result = run_opcode(&creature, &soup, opcode);

        try testing.expect(result == .hard_instruction_success);
        try testing.expectEqual(@as(u16, if (opcode == .adrb) 2 else 8), creature.cpu.ax);
        try testing.expectEqual(@as(u16, 1), creature.cpu.cx);
        try testing.expectEqual(@as(u16, 6), creature.cpu.ip);
        try testing.expectEqual(@as(u16, 12), creature.cpu.bx);
        try testing.expectEqual(@as(u8, 0), creature.cpu.fl);
        try testing.expectEqual(@as(u16, 1), creature.instructions_executed);
    }
}

test "adr variants with no operand leave result registers unchanged" {
    var soup = Soup(7){};
    soup.memory = .{Instruction.inc_a} ** 7;

    inline for (.{ Instruction.adr, Instruction.adrb, Instruction.adrf }) |opcode| {
        var creature = test_creature(5, 0);
        creature.cpu = .{ .ip = 3, .ax = 55, .cx = 99, .fl = 1 };
        try testing.expect(run_opcode(&creature, &soup, opcode) == .none);
        try testing.expectEqual(@as(u16, 4), creature.cpu.ip);
        try testing.expectEqual(@as(u16, 55), creature.cpu.ax);
        try testing.expectEqual(@as(u16, 99), creature.cpu.cx);
        try testing.expectEqual(@as(u8, 0), creature.cpu.fl);
    }
}

test "failed adr search skips the operand without changing result registers" {
    var soup = Soup(7){};
    soup.memory = .{Instruction.inc_a} ** 7;
    soup.memory[1] = .nop_0;
    soup.memory[2] = .nop_0;

    inline for (.{ 0, 7 }) |budget| {
        inline for (.{ Instruction.adr, Instruction.adrb, Instruction.adrf }) |opcode| {
            var creature = test_creature(5, budget);
            creature.cpu = .{ .ax = 55, .cx = 99 };
            try testing.expect(run_opcode(&creature, &soup, opcode) == .error_condition);
            try testing.expectEqual(@as(u16, 3), creature.cpu.ip);
            try testing.expectEqual(@as(u16, 55), creature.cpu.ax);
            try testing.expectEqual(@as(u16, 99), creature.cpu.cx);
            try testing.expectEqual(@as(u8, 1), creature.cpu.fl);
            try testing.expectEqual(@as(u16, 1), creature.instructions_executed);
        }
    }
}

test "adrb recognizes a wrapped operand and stores the address after its match" {
    var soup = Soup(7){};
    soup.memory = .{Instruction.inc_a} ** 7;
    soup.memory[6] = .nop_0;
    soup.memory[0] = .nop_1;
    soup.memory[3] = .nop_1;
    soup.memory[4] = .nop_0;
    var creature = test_creature(5, 1);
    creature.cpu.ip = 5;

    try testing.expect(run_opcode(&creature, &soup, .adrb) == .hard_instruction_success);
    try testing.expectEqual(@as(u16, 1), creature.cpu.ip);
    try testing.expectEqual(@as(u16, 5), creature.cpu.ax);
    try testing.expectEqual(@as(u16, 2), creature.cpu.cx);
    try testing.expectEqual(@as(u16, 1), creature.instructions_executed);
}

test "mov_iab copies a normalized source into owned memory exactly once" {
    var soup = Soup(7){};
    soup.memory[2] = .inc_c;
    soup.memory[5] = .zero;
    soup.owner[0] = 1;
    soup.owner[5] = 1;
    var creature = test_creature(5, 7);
    creature.daughter_alloc = .{ .start = 5, .len = 1 };
    creature.cpu = .{ .ax = 12, .bx = 9, .fl = 1 };

    try testing.expect(run_opcode(&creature, &soup, .mov_iab) == .none);
    try testing.expectEqual(Instruction.inc_c, soup.memory[5]);
    try testing.expectEqual(@as(u16, 12), creature.cpu.ax);
    try testing.expectEqual(@as(u16, 9), creature.cpu.bx);
    try testing.expectEqual(@as(u16, 1), creature.cpu.ip);
    try testing.expectEqual(@as(u16, 1), creature.instructions_copied);
    try testing.expectEqual(@as(u16, 1), creature.instructions_executed);
    try testing.expectEqual(@as(u8, 0), creature.cpu.fl);
}

test "mov_iab rejects an unowned destination without counting a copy" {
    var soup = Soup(7){};
    soup.memory[2] = .inc_c;
    soup.memory[5] = .zero;
    soup.owner[0] = 1;
    soup.owner[5] = 2;
    var creature = test_creature(5, 7);
    creature.cpu = .{ .ax = 12, .bx = 9 };

    try testing.expect(run_opcode(&creature, &soup, .mov_iab) == .error_condition);
    try testing.expectEqual(Instruction.zero, soup.memory[5]);
    try testing.expectEqual(@as(u16, 12), creature.cpu.ax);
    try testing.expectEqual(@as(u16, 9), creature.cpu.bx);
    try testing.expectEqual(@as(u16, 1), creature.cpu.ip);
    try testing.expectEqual(@as(u16, 0), creature.instructions_copied);
    try testing.expectEqual(@as(u16, 1), creature.instructions_executed);
    try testing.expectEqual(@as(u8, 1), creature.cpu.fl);
}

test "mal requests the exact cx size and advances without allocating" {
    var soup = Soup(3){};
    var creature = test_creature(5, 3);
    creature.cpu = .{ .cx = 7, .fl = 1 };

    const first = run_opcode(&creature, &soup, .mal);
    try testing.expect(first == .mal_request);
    try testing.expectEqual(@as(u16, 7), first.mal_request);
    try testing.expectEqual(@as(u16, 1), creature.cpu.ip);
    try testing.expectEqual(@as(u8, 0), creature.cpu.fl);
    try testing.expectEqual(soup.len, soup.count_free_memory());

    creature.cpu.cx = 0;
    const second = run_opcode(&creature, &soup, .mal);
    try testing.expect(second == .mal_request);
    try testing.expectEqual(@as(u16, 0), second.mal_request);
    try testing.expectEqual(@as(u16, 2), creature.cpu.ip);
    try testing.expectEqual(@as(u16, 2), creature.instructions_executed);
}

test "divide reports the daughter allocation or an error when absent" {
    var soup = Soup(4){};
    soup.owner[0] = 1;
    soup.owner[2] = 1;
    soup.owner[3] = 1;
    var creature = test_creature(5, 4);
    creature.daughter_alloc = .{ .start = 2, .len = 2 };
    creature.cpu.fl = 1;

    const success = run_opcode(&creature, &soup, .divide);
    try testing.expect(success == .divide);
    try testing.expectEqual(@as(u16, 2), success.divide.start);
    try testing.expectEqual(@as(u16, 2), success.divide.len);
    try testing.expectEqual(@as(u16, 1), creature.cpu.ip);
    try testing.expectEqual(@as(u8, 0), creature.cpu.fl);
    try testing.expect(creature.daughter_alloc != null);
    try testing.expectEqual(@as(?CreatureId, 1), soup.owner[2]);
    try testing.expectEqual(@as(?CreatureId, 1), soup.owner[3]);

    creature.daughter_alloc = null;
    try testing.expect(run_opcode(&creature, &soup, .divide) == .error_condition);
    try testing.expectEqual(@as(u16, 2), creature.cpu.ip);
    try testing.expectEqual(@as(u8, 1), creature.cpu.fl);
    try testing.expectEqual(@as(u16, 2), creature.instructions_executed);
}
