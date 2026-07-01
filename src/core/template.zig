const testing = @import("std").testing;

const Instruction = @import("instruction.zig").Instruction;
const is_nop = @import("instruction.zig").is_nop;
const complement = @import("instruction.zig").complement;
const Soup = @import("soup.zig").Soup;

pub fn search_forward(soup: anytype, start: u16, comptime limit: u16) ?u16 {
    var pattern_start: ?u16 = null;
    var pattern_end: ?u16 = null;
    var pattern_search_count: u16 = 0;
    var pattern_length: u16 = 0;
    var idx: u16 = 0;

    while (pattern_search_count < limit) {
        idx = (pattern_search_count + start) % soup.len;

        if (is_nop(soup.read(idx))) {
            if (pattern_start == null) {
                pattern_start = idx;
            } else {
                pattern_end = idx;
            }
            pattern_length += 1;
        } else if (pattern_start != null) {
            break; // We found the end of the pattern
        }

        pattern_search_count += 1;
    }

    if (pattern_start == null or pattern_end == null) {
        return null;
    }

    if (pattern_length >= limit / 2) {
        return null;
    }

    var search_addr = pattern_end.? + 1;
    var search_count: u16 = 0;
    var offset: u16 = 0;

    while (search_count < limit) {
        offset = 0;

        while (offset < pattern_length) {
            if (soup.read((pattern_start.? + offset) % soup.len) != complement(soup.read((search_addr + offset) % soup.len))) {
                break;
            }

            offset += 1;
        }

        if (offset == pattern_length) {
            return search_addr;
        }

        search_count += 1;
        search_addr = (search_addr + 1) % soup.len;
    }

    return null;
}

// pub fn search_backward(comptime soup_size: u16, soup: *const Soup(soup_size), start: u16, comptime limit: u16) ?u16 {}

// pub fn search_bidirectional(comptime soup_size: u16, soup: *const Soup(soup_size), start: u16, comptime limit: u16) ?u16 {}

test "search forward" {
    // Simplest case, we find a pattern.
    const soup_size = 7;
    var soup_simple = Soup(soup_size){};
    soup_simple.memory = .{
        null,
        Instruction.nop_0,
        Instruction.nop_1,
        null,
        null,
        Instruction.nop_1,
        Instruction.nop_0,
    };

    try testing.expectEqual(5, search_forward(&soup_simple, 0, 100));

    // Pattern outside limit.
    try testing.expectEqual(null, search_forward(&soup_simple, 0, 3));

    // Pattern not found.
    soup_simple.memory = .{
        null,
        Instruction.nop_0,
        Instruction.nop_1,
        null,
        null,
        Instruction.adrb,
        Instruction.nop_0,
    };

    try testing.expectEqual(null, search_forward(&soup_simple, 0, 100));
}

test "search forward wrap around" {
    // Simplest case, we find a pattern.
    const soup_size = 7;
    var soup_simple = Soup(soup_size){};
    soup_simple.memory = .{
        null,
        Instruction.nop_0,
        Instruction.nop_1,
        null,
        null,
        Instruction.nop_1,
        Instruction.nop_0,
    };

    try testing.expectEqual(1, search_forward(&soup_simple, 5, 100));

    // // Pattern outside limit.
    try testing.expectEqual(null, search_forward(&soup_simple, 3, 3));
}

test "search backward" {}

test "search backward wrap around" {}

test "search bidirectional" {}

test "search bidirectional wrap around" {}
