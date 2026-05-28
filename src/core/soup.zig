const testing = @import("std").testing;
const CreatureId = @import("creature.zig").CreatureId;

const Allocation = struct {
    start: u16, // Starting address in soup
    len: u16, // Number of cells allocated
};

pub fn Soup(comptime size: u16) type {
    return struct {
        memory: [size]u8,
        owner: [size]?CreatureId,
        pub const capacity = size;
    };
}

test "test constructor" {
    const soup = Soup(1234);
    try testing.expectEqual(1234, soup.capacity);
}
