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

// Zero means empty; null means no terminating cell was found in one traversal.
pub fn pattern_length_at(soup: anytype, start: u16) ?u16 {
    const length = count_nops_at(soup, start, soup.len);
    return if (length == soup.len) null else length;
}

fn candidate_overlaps_operand(candidate_start: u16, pattern_start: u16, pattern_length: u16, soup_len: u16) bool {
    const instruction_addr = wrap_decrement(pattern_start, 1, soup_len);
    var offset: u16 = 0;

    while (offset < pattern_length) : (offset += 1) {
        const candidate_addr = wrap_increment(candidate_start, offset, soup_len);
        if (forward_distance(instruction_addr, candidate_addr, soup_len) <= pattern_length) {
            return true;
        }
    }

    return false;
}

fn matches_complement_at(soup: anytype, pattern_start: u16, pattern_length: u16, candidate_start: u16) bool {
    if (candidate_overlaps_operand(candidate_start, pattern_start, pattern_length, soup.len)) return false;

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
    const pattern_length = pattern_length_at(soup, start) orelse return null;
    if (pattern_length == 0 or limit == 0) return null;

    const match_start = search_forward_match(soup, start, pattern_length, limit) orelse return null;

    return wrap_increment(match_start, pattern_length, soup.len);
}

fn search_forward_match(soup: anytype, start: u16, pattern_length: u16, limit: u16) ?u16 {
    var search_addr = wrap_increment(start, pattern_length, soup.len);
    var search_count: u16 = 0;
    const rounds = @min(limit, soup.len);

    while (search_count < rounds) {
        if (matches_complement_at(soup, start, pattern_length, search_addr)) {
            return search_addr;
        }

        search_count += 1;
        search_addr = wrap_increment(search_addr, 1, soup.len);
    }

    return null;
}

pub fn search_backward(soup: anytype, start: u16, limit: u16) ?u16 {
    const pattern_length = pattern_length_at(soup, start) orelse return null;
    if (pattern_length == 0 or limit == 0) return null;

    const match_start = search_backward_match(soup, start, pattern_length, limit) orelse return null;

    return wrap_increment(match_start, pattern_length, soup.len);
}

fn search_backward_match(soup: anytype, start: u16, pattern_length: u16, limit: u16) ?u16 {
    const instruction_addr = wrap_decrement(start, 1, soup.len);
    var search_addr = wrap_decrement(instruction_addr, pattern_length, soup.len);
    var search_count: u16 = 0;
    const rounds = @min(limit, soup.len);

    while (search_count < rounds) {
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

// Check paired candidates by round; forward wins a match in the same round.
pub fn search_bidirectional(soup: anytype, start: u16, limit: u16) ?u16 {
    const pattern_length = pattern_length_at(soup, start) orelse return null;
    if (pattern_length == 0 or limit == 0) return null;

    const instruction_addr = wrap_decrement(start, 1, soup.len);
    var forward_addr = wrap_increment(start, pattern_length, soup.len);
    var backward_addr = wrap_decrement(instruction_addr, pattern_length, soup.len);
    var search_count: u16 = 0;
    const rounds = @min(limit, soup.len);

    while (search_count < rounds) : (search_count += 1) {
        if (matches_complement_at(soup, start, pattern_length, forward_addr)) {
            return wrap_increment(forward_addr, pattern_length, soup.len);
        }
        if (matches_complement_at(soup, start, pattern_length, backward_addr)) {
            return wrap_increment(backward_addr, pattern_length, soup.len);
        }

        forward_addr = wrap_increment(forward_addr, 1, soup.len);
        backward_addr = wrap_decrement(backward_addr, 1, soup.len);
    }

    return null;
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
    try testing.expectEqual(1, wrap_increment(1, 0, 60000));
    try testing.expectEqual(1, wrap_increment(11, 0, 10));
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
        Instruction.inc_a,
        Instruction.nop_0,
        Instruction.nop_1,
        Instruction.inc_a,
        Instruction.inc_a,
        Instruction.nop_1,
        Instruction.nop_0,
    };

    try testing.expectEqual(0, search_forward(&soup_simple, 1, 100));

    // Pattern outside limit.
    try testing.expectEqual(null, search_forward(&soup_simple, 1, 2));
    try testing.expectEqual(0, search_forward(&soup_simple, 1, 3));

    // Pattern not found.
    soup_simple.memory = .{
        Instruction.inc_a,
        Instruction.nop_0,
        Instruction.nop_1,
        Instruction.inc_a,
        Instruction.inc_a,
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
        Instruction.inc_a,
        Instruction.nop_0,
        Instruction.nop_1,
        Instruction.inc_a,
        Instruction.inc_a,
        Instruction.nop_1,
        Instruction.nop_0,
    };

    try testing.expectEqual(3, search_forward(&soup_simple, 5, 100));

    // No operand at this address.
    try testing.expectEqual(null, search_forward(&soup_simple, 3, 3));

    // Pattern not found.
    soup_simple.memory = .{
        Instruction.inc_a,
        Instruction.mov_ab,
        Instruction.nop_1,
        Instruction.inc_a,
        Instruction.inc_a,
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
        Instruction.inc_a,
        Instruction.inc_a,
        Instruction.inc_a,
        Instruction.inc_a,
        Instruction.inc_a,
        Instruction.adrb,
        Instruction.nop_0,
        Instruction.nop_0,
        Instruction.nop_0,
        Instruction.nop_0,
        Instruction.inc_a,
    };

    try testing.expectEqual(4, search_backward(&soup_simple, 10, 100));

    // Pattern outside limit.
    try testing.expectEqual(null, search_backward(&soup_simple, 10, 5));
    try testing.expectEqual(4, search_backward(&soup_simple, 10, 6));

    // Pattern not found.
    soup_simple.memory = .{
        Instruction.inc_a,
        Instruction.nop_1,
        Instruction.nop_1,
        Instruction.nop_1,
        Instruction.inc_a,
        Instruction.inc_a,
        Instruction.inc_a,
        Instruction.inc_a,
        Instruction.inc_a,
        Instruction.adrb,
        Instruction.nop_0,
        Instruction.nop_0,
        Instruction.nop_0,
        Instruction.nop_0,
        Instruction.inc_a,
    };

    try testing.expectEqual(null, search_backward(&soup_simple, 10, 100));
}

test "search backward wrap around" {
    var soup_simple = Soup(7){};
    soup_simple.memory = .{
        Instruction.nop_1,
        Instruction.inc_a,
        Instruction.adrb,
        Instruction.nop_0,
        Instruction.nop_0,
        Instruction.inc_a,
        Instruction.nop_1,
    };

    try testing.expectEqual(1, search_backward(&soup_simple, 3, 100));
}

test "search bidirectional" {
    var soup_simple = Soup(13){};
    soup_simple.memory = .{
        Instruction.inc_a,
        Instruction.nop_0,
        Instruction.nop_1,
        Instruction.inc_a,
        Instruction.inc_a,
        Instruction.nop_1,
        Instruction.nop_0,
        Instruction.inc_a,
        Instruction.inc_a,
        Instruction.nop_1,
        Instruction.nop_0,
        Instruction.inc_a,
        Instruction.inc_a,
    };

    try testing.expectEqual(3, search_bidirectional(soup_simple, 5, 100));
    try testing.expectEqual(7, search_bidirectional(soup_simple, 1, 100));
}

test "pattern length distinguishes empty valid and invalid operands" {
    var soup = Soup(5){};
    soup.memory = .{ Instruction.jmp, Instruction.nop_0, Instruction.nop_1, Instruction.inc_a, Instruction.inc_a };

    try testing.expectEqual(@as(?u16, 0), pattern_length_at(&soup, 3));
    try testing.expectEqual(@as(?u16, 0), pattern_length_at(&soup, 4));
    try testing.expectEqual(@as(?u16, 2), pattern_length_at(&soup, 1));
    soup.memory = .{Instruction.nop_0} ** 5;
    try testing.expectEqual(@as(?u16, null), pattern_length_at(&soup, 1));
}

test "searches reject empty operands" {
    var soup = Soup(7){};
    soup.memory = .{ Instruction.jmp, Instruction.nop_0, Instruction.nop_1, Instruction.inc_a, Instruction.nop_1, Instruction.nop_0, Instruction.inc_a };

    for ([_]u16{ 0, 3, 6 }) |start| {
        try testing.expectEqual(@as(?u16, 0), pattern_length_at(&soup, start));
        try testing.expectEqual(@as(?u16, null), search_forward(&soup, start, 100));
        try testing.expectEqual(@as(?u16, null), search_backward(&soup, start, 100));
        try testing.expectEqual(@as(?u16, null), search_bidirectional(&soup, start, 100));
    }
}

test "searches with zero budget return no match" {
    var soup = Soup(5){};
    soup.memory = .{ Instruction.jmp, Instruction.nop_0, Instruction.inc_a, Instruction.nop_1, Instruction.inc_a };

    try testing.expectEqual(@as(?u16, null), search_forward(&soup, 1, 0));
    try testing.expectEqual(@as(?u16, null), search_backward(&soup, 1, 0));
    try testing.expectEqual(@as(?u16, null), search_bidirectional(&soup, 1, 0));
}

test "extraction preserves long wrapped operands" {
    var soup = Soup(7){};
    soup.memory = .{ Instruction.nop_1, Instruction.nop_0, Instruction.inc_a, Instruction.jmp, Instruction.nop_0, Instruction.nop_1, Instruction.nop_0 };

    try testing.expectEqual(@as(?u16, 5), pattern_length_at(&soup, 4));
}

test "short budgets count candidates rather than operand cells" {
    var soup = Soup(7){};
    soup.memory = .{ Instruction.jmp, Instruction.nop_0, Instruction.inc_a, Instruction.nop_1, Instruction.inc_a, Instruction.inc_a, Instruction.nop_1 };

    // The first forward candidate is the instruction terminating the operand.
    try testing.expectEqual(@as(?u16, null), search_forward(&soup, 1, 1));
    try testing.expectEqual(@as(?u16, 4), search_forward(&soup, 1, 2));
    try testing.expectEqual(@as(?u16, 0), search_backward(&soup, 1, 1));
    try testing.expectEqual(@as(?u16, 0), search_bidirectional(&soup, 1, 1));
}

test "bidirectional search selects the earliest round and prefers forward ties" {
    var soup = Soup(9){};
    soup.memory = .{Instruction.inc_a} ** 9;
    soup.memory[4] = Instruction.jmp;
    soup.memory[5] = Instruction.nop_0;
    soup.memory[7] = Instruction.nop_1;
    soup.memory[2] = Instruction.nop_1;

    // Both directions match in the second round, after the initial candidates.
    try testing.expectEqual(@as(?u16, null), search_bidirectional(&soup, 5, 1));
    try testing.expectEqual(@as(?u16, 8), search_bidirectional(&soup, 5, 2));

    // Move the backward match one round later; forward still wins.
    soup.memory[2] = Instruction.inc_a;
    soup.memory[1] = Instruction.nop_1;
    try testing.expectEqual(@as(?u16, 8), search_bidirectional(&soup, 5, 3));

    // Move it to the first round; backward now wins.
    soup.memory[1] = Instruction.inc_a;
    soup.memory[3] = Instruction.nop_1;
    try testing.expectEqual(@as(?u16, 4), search_bidirectional(&soup, 5, 3));
}

test "bidirectional forward tie priority survives address wrapping" {
    var soup = Soup(9){};
    soup.memory = .{Instruction.inc_a} ** 9;
    soup.memory[7] = Instruction.jmp;
    soup.memory[8] = Instruction.nop_0;
    soup.memory[1] = Instruction.nop_1;
    soup.memory[5] = Instruction.nop_1;

    try testing.expectEqual(@as(?u16, 2), search_bidirectional(&soup, 8, 2));
    try testing.expectEqual(@as(?u16, 6), search_backward(&soup, 8, 2));
}

test "candidate overlap includes the instruction and wrapped operand" {
    // Operand cells 5, 6, 0 follow the instruction at 4. Only candidate 1
    // occupies three cells entirely outside that protected range.
    try testing.expect(!candidate_overlaps_operand(1, 5, 3, 7));
    for ([_]u16{ 0, 2, 3, 4, 5, 6 }) |candidate| {
        try testing.expect(candidate_overlaps_operand(candidate, 5, 3, 7));
    }

    // Synthetic input: the complementary sequence at 0 spans the protected
    // instruction address 1. Reject it even when that address contains a NOP.
    var soup = Soup(7){};
    soup.memory = .{ Instruction.nop_1, Instruction.nop_1, Instruction.nop_0, Instruction.nop_0, Instruction.inc_a, Instruction.inc_a, Instruction.jmp };
    try testing.expectEqual(@as(?u16, null), search_forward(&soup, 2, 4));
    try testing.expectEqual(@as(?u16, null), search_backward(&soup, 2, 100));
    try testing.expectEqual(@as(?u16, null), search_bidirectional(&soup, 2, 100));
}

const CountingSoup = struct {
    comptime len: u16 = 7,
    memory: [7]Instruction = .{Instruction.inc_a} ** 7,
    reads: usize = 0,

    pub fn read(self: *@This(), address: u16) Instruction {
        self.reads += 1;
        return self.memory[address];
    }
};

test "all NOP extraction reads exactly one traversal" {
    var soup = CountingSoup{ .memory = .{Instruction.nop_0} ** 7 };

    try testing.expectEqual(@as(?u16, null), pattern_length_at(&soup, 5));
    try testing.expectEqual(@as(usize, 7), soup.reads);
    inline for (.{ search_forward, search_backward, search_bidirectional }) |search_fn| {
        try testing.expectEqual(@as(?u16, null), search_fn(&soup, 5, 100));
    }
}

test "search budgets beyond one traversal do not repeat candidates" {
    inline for (.{ search_forward, search_backward, search_bidirectional }) |search_fn| {
        var soup = CountingSoup{};
        soup.memory[0] = Instruction.jmp;
        soup.memory[1] = Instruction.nop_0;

        try testing.expectEqual(@as(?u16, null), search_fn(&soup, 1, soup.len));
        const single_traversal_reads = soup.reads;
        soup.reads = 0;
        try testing.expectEqual(@as(?u16, null), search_fn(&soup, 1, 65535));
        try testing.expectEqual(single_traversal_reads, soup.reads);
    }
}
