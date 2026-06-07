const std = @import("std");
const testing = std.testing;

pub const StackError = error{ StackOverflow, StackUnderflow };

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
