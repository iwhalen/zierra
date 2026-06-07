const std = @import("std");
const testing = std.testing;

const CreatureId = @import("creature.zig").CreatureId;
const Instruction = @import("instruction.zig").Instruction;

pub const SoupError = error{
    PermissionError,
    NoFreeSoup,
    InvalidAllocation,
};

pub const Allocation = struct {
    start: u16,
    len: u16,
};

pub fn Soup(comptime size: u16) type {
    if (comptime size <= 0) {
        @compileError("Soup size must be positive.");
    }

    if (comptime size >= std.math.maxInt(u16)) {
        @compileError("Soup size must fit in u16.");
    }

    return struct {
        const Self = @This();

        memory: [size]?Instruction = .{null} ** size,
        owner: [size]?CreatureId = .{null} ** size,

        pub fn read(self: *const Self, address: u16) Instruction {
            return self.memory[address];
        }

        pub fn write(self: *Self, address: u16, instruction: Instruction, writer_id: CreatureId) SoupError!void {
            if (self.owner[address] == writer_id) {
                self.memory[address] = instruction;
            } else {
                return SoupError.PermissionError;
            }
        }

        pub fn allocate(self: *Self, request_size: u16, requester: CreatureId) SoupError!Allocation {
            var run_start: u16 = 0;
            var run_len: u16 = 0;

            // Find a contiguous "run" of unallocated memory.
            for (self.owner, 0..) |owner, i| {
                if (owner == null) {
                    if (run_len == 0) {
                        run_start = @intCast(i);
                    }

                    if (run_len == request_size) {

                        // Assign memory in the allocation range.
                        for (run_start..run_start + request_size) |j| {
                            self.owner[j] = requester;
                        }

                        return Allocation{ .start = run_start, .len = request_size };
                    }
                    run_len += 1;
                } else {
                    run_len = 0;
                }
            }
            return SoupError.NoFreeSoup;
        }

        pub fn free(self: *Self, allocation: Allocation) SoupError!void {
            if (allocation.start >= self.memory.len or allocation.len <= 0) {
                return SoupError.InvalidAllocation;
            }

            for (allocation.start..allocation.start + allocation.len) |i| {
                self.owner[i] = null;
            }
        }

        pub fn count_free_memory(self: *const Self) u16 {
            var count: u16 = 0;

            for (self.owner) |owner| {
                if (owner == null) count += 1;
            }

            return count;
        }

        pub fn inoculate(self: *Self, code: []const Instruction, address: u16, requester: CreatureId) SoupError!Allocation {
            if (code.len > self.memory.len) {
                return SoupError.InvalidAllocation;
            }

            if (self.count_free_memory() < code.len) {
                return SoupError.NoFreeSoup;
            }

            for (code, address..) |code_i, i| {
                if (self.owner[i] != null) {
                    return SoupError.PermissionError;
                }

                self.owner[i] = requester;
                try self.write(@intCast(i), code_i, requester);
            }

            return Allocation{
                .start = address,
                .len = @intCast(code.len),
            };
        }
    };
}

test "test constructor" {
    const soup = Soup(1234){};
    try testing.expectEqual(1234, soup.memory.len);
    try testing.expectEqual(1234, soup.owner.len);
    try testing.expectEqual(null, soup.memory[0]);
    try testing.expectEqual(null, soup.owner[0]);
}

test "allocation, free round trip" {
    var soup = Soup(5){};

    soup.memory[0] = Instruction.nop_0;
    soup.owner[0] = 0x123;

    const allocation = try soup.allocate(2, 0x777);

    try testing.expectEqual(1, allocation.start);
    try testing.expectEqual(2, allocation.len);

    try testing.expectEqualSlices(?Instruction, &[_]?Instruction{ Instruction.nop_0, null, null, null, null }, &soup.memory);
    try testing.expectEqualSlices(?CreatureId, &[_]?CreatureId{ 0x123, 0x777, 0x777, null, null }, &soup.owner);

    try soup.free(allocation);

    try testing.expectEqualSlices(?Instruction, &[_]?Instruction{ Instruction.nop_0, null, null, null, null }, &soup.memory);
    try testing.expectEqualSlices(?CreatureId, &[_]?CreatureId{ 0x123, null, null, null, null }, &soup.owner);
}

test "write permissions enforcement" {
    var soup = Soup(5){};
    soup.owner[0] = 0x123;
    try testing.expectError(SoupError.PermissionError, soup.write(0, Instruction.inc_a, 0x007));
}

test "count free memory" {
    var soup = Soup(5){};

    soup.owner[0] = 0x000;
    soup.owner[2] = 0x001;

    try testing.expectEqual(3, soup.count_free_memory());
}

test "inoculate" {
    const ancestor: [3]Instruction = .{ Instruction.nop_0, Instruction.divide, Instruction.jmp };
    var soup = Soup(5){};

    const allocation = try soup.inoculate(&ancestor, 1, 0x777);

    try testing.expectEqual(1, allocation.start);
    try testing.expectEqual(3, allocation.len);

    try testing.expectEqualSlices(?Instruction, &[_]?Instruction{ null, Instruction.nop_0, Instruction.divide, Instruction.jmp, null }, &soup.memory);
}
