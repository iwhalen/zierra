const testing = @import("std").testing;

const Instruction = @import("instruction.zig").Instruction;
const is_nop = @import("instruction.zig").is_nop;
const complement = @import("instruction.zig").complement;
const Soup = @import("soup.zig").Soup;

pub fn wrap_decrement(start: u16, decrement: u16, maximum: u16) u16 {
    const normalized_address = start % maximum;
    const step_size = decrement % maximum;

    if (normalized_address >= step_size) {
        return normalized_address - step_size;
    } else {
        return maximum - (step_size - normalized_address);
    }
}

pub fn wrap_increment(start: u16, increment: u16, maximum: u16) u16 {
    const normalized_address = start % maximum;
    const step_size = increment % maximum;
    const threshold = maximum - step_size;

    if (normalized_address < threshold) {
        return normalized_address + step_size;
    } else {
        return normalized_address - threshold;
    }
}

pub fn count_nops_at(soup: anytype, start: u16, limit: u16) u16 {
    var nops: u16 = 0;

    while (nops < limit) {
        if (!is_nop(soup.read(wrap_increment(start, nops, soup.len)))) {
            break;
        }

        nops += 1;
    }

    return nops;
}

pub fn pattern_length_at(soup: anytype, start: u16, limit: u16) ?u16 {
    const length = count_nops_at(soup, start, limit);

    if (length == 0) {
        return null;
    }

    if (length >= limit / 2) {
        return null;
    }

    return length;
}

fn matches_complement_at(soup: anytype, pattern_start: u16, pattern_length: u16, candidate_start: u16) bool {
    var offset: u16 = 0;

    while (offset < pattern_length) {
        const pattern_addr = wrap_increment(pattern_start, offset, soup.len);
        const candidate_addr = wrap_increment(candidate_start, offset, soup.len);

        if (soup.read(candidate_addr) != complement(soup.read(pattern_addr))) {
            return false;
        }

        offset += 1;
    }

    return true;
}

pub fn search_forward(soup: anytype, start: u16, limit: u16) ?u16 {
    const pattern_length = pattern_length_at(soup, start, limit) orelse return null;
    const match_start = search_forward_match(soup, start, pattern_length, limit) orelse return null;

    return wrap_increment(match_start, pattern_length, soup.len);
}

fn search_forward_match(soup: anytype, start: u16, pattern_length: u16, limit: u16) ?u16 {
    var search_addr = wrap_increment(start, pattern_length, soup.len);
    var search_count: u16 = 0;

    while (search_count < limit) {
        if (matches_complement_at(soup, start, pattern_length, search_addr)) {
            return search_addr;
        }

        search_count += 1;
        search_addr = wrap_increment(search_addr, 1, soup.len);
    }

    return null;
}

pub fn search_backward(soup: anytype, start: u16, limit: u16) ?u16 {
    const pattern_length = pattern_length_at(soup, start, limit) orelse return null;
    const match_start = search_backward_match(soup, start, pattern_length, limit) orelse return null;

    return wrap_increment(match_start, pattern_length, soup.len);
}

fn search_backward_match(soup: anytype, start: u16, pattern_length: u16, limit: u16) ?u16 {
    const instruction_addr = wrap_decrement(start, 1, soup.len);
    var search_addr = wrap_decrement(instruction_addr, pattern_length, soup.len);
    var search_count: u16 = 0;

    while (search_count < limit) {
        if (matches_complement_at(soup, start, pattern_length, search_addr)) {
            return search_addr;
        }

        search_count += 1;
        search_addr = wrap_decrement(search_addr, 1, soup.len);
    }

    return null;
}

fn forward_distance(from: u16, to: u16, maximum: u16) u16 {
    return if (to >= from) to - from else (maximum - from) + to;
}

fn backward_distance(from: u16, to: u16, maximum: u16) u16 {
    return if (from >= to) from - to else (maximum - to) + from;
}

pub fn search_bidirectional(soup: anytype, start: u16, limit: u16) ?u16 {
    const pattern_length = pattern_length_at(soup, start, limit) orelse return null;
    const forward_match = search_forward_match(soup, start, pattern_length, limit);
    const backward_match = search_backward_match(soup, start, pattern_length, limit);

    if (forward_match == null and backward_match == null) {
        return null;
    }

    if (forward_match == null) {
        return wrap_increment(backward_match.?, pattern_length, soup.len);
    }

    if (backward_match == null) {
        return wrap_increment(forward_match.?, pattern_length, soup.len);
    }

    const instruction_addr = wrap_decrement(start, 1, soup.len);
    const backward_match_end = wrap_increment(backward_match.?, pattern_length - 1, soup.len);

    if (forward_distance(instruction_addr, forward_match.?, soup.len) < backward_distance(instruction_addr, backward_match_end, soup.len)) {
        return wrap_increment(forward_match.?, pattern_length, soup.len);
    } else {
        return wrap_increment(backward_match.?, pattern_length, soup.len);
    }
}

test "wrap increment" {
    try testing.expectEqual(12, wrap_increment(10, 2, 100));
    try testing.expectEqual(1, wrap_increment(99, 2, 100));
    try testing.expectEqual(10, wrap_increment(10, 200, 100));
    try testing.expectEqual(12, wrap_increment(210, 2, 100));
    try testing.expectEqual(10000, wrap_increment(50000, 20000, 60000));
    try testing.expectEqual(1, wrap_increment(65535, 1, 65535));
    try testing.expectEqual(0, wrap_increment(50000, 15535, 65535));
    try testing.expectEqual(50000, wrap_increment(50000, 60000, 60000));
}

test "wrap decrement" {
    try testing.expectEqual(10, wrap_decrement(11, 1, 1000));
    try testing.expectEqual(98, wrap_decrement(0, 2, 100));
    try testing.expectEqual(7, wrap_decrement(1, 7, 13));
    try testing.expectEqual(49999, wrap_decrement(50000, 1, 60000));
    try testing.expectEqual(5536, wrap_decrement(5537, 1, 60000));
    try testing.expectEqual(0, wrap_decrement(65535, 65535, 65535));
    try testing.expectEqual(0, wrap_decrement(50000, 50000, 60000));
    try testing.expectEqual(10000, wrap_decrement(50000, 40000, 60000));
}

test "search forward" {
    // Simplest case, we find a pattern.
    var soup_simple = Soup(7){};
    soup_simple.memory = .{
        null,
        Instruction.nop_0,
        Instruction.nop_1,
        null,
        null,
        Instruction.nop_1,
        Instruction.nop_0,
    };

    try testing.expectEqual(0, search_forward(&soup_simple, 1, 100));

    // Pattern outside limit.
    try testing.expectEqual(null, search_forward(&soup_simple, 1, 3));

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

    try testing.expectEqual(null, search_forward(&soup_simple, 1, 100));
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

    try testing.expectEqual(3, search_forward(&soup_simple, 5, 100));

    // Pattern outside limit.
    try testing.expectEqual(null, search_forward(&soup_simple, 3, 3));

    // Pattern not found.
    soup_simple.memory = .{
        null,
        Instruction.mov_ab,
        Instruction.nop_1,
        null,
        null,
        Instruction.nop_1,
        Instruction.nop_0,
    };

    try testing.expectEqual(null, search_forward(&soup_simple, 5, 100));
}

test "search backward" {
    // Ancestor-like case: ADRB followed by 0000 finds prior 1111 and returns after it.
    var soup_simple = Soup(15){};
    soup_simple.memory = .{
        Instruction.nop_1,
        Instruction.nop_1,
        Instruction.nop_1,
        Instruction.nop_1,
        null,
        null,
        null,
        null,
        null,
        Instruction.adrb,
        Instruction.nop_0,
        Instruction.nop_0,
        Instruction.nop_0,
        Instruction.nop_0,
        null,
    };

    try testing.expectEqual(4, search_backward(&soup_simple, 10, 100));

    // Pattern outside limit.
    try testing.expectEqual(null, search_backward(&soup_simple, 10, 7));

    // Pattern not found.
    soup_simple.memory = .{
        null,
        Instruction.nop_1,
        Instruction.nop_1,
        Instruction.nop_1,
        null,
        null,
        null,
        null,
        null,
        Instruction.adrb,
        Instruction.nop_0,
        Instruction.nop_0,
        Instruction.nop_0,
        Instruction.nop_0,
        null,
    };

    try testing.expectEqual(null, search_backward(&soup_simple, 10, 100));
}

test "search backward wrap around" {
    var soup_simple = Soup(7){};
    soup_simple.memory = .{
        Instruction.nop_1,
        null,
        Instruction.adrb,
        Instruction.nop_0,
        Instruction.nop_0,
        null,
        Instruction.nop_1,
    };

    try testing.expectEqual(1, search_backward(&soup_simple, 3, 100));
}

test "search bidirectional" {
    var soup_simple = Soup(13){};
    soup_simple.memory = .{
        null,
        Instruction.nop_0,
        Instruction.nop_1,
        null,
        null,
        Instruction.nop_1,
        Instruction.nop_0,
        null,
        null,
        Instruction.nop_1,
        Instruction.nop_0,
        null,
        null,
    };

    try testing.expectEqual(3, search_bidirectional(soup_simple, 5, 100));
    try testing.expectEqual(11, search_bidirectional(soup_simple, 1, 100));
}
