const std = @import("std");
const testing = std.testing;

pub fn Scheduler(comptime CreatureType: type) type {
    return struct {
        const Self = @This();

        slicer: std.DoublyLinkedList = .{},
        slicer_current: ?*std.DoublyLinkedList.Node = null,

        reaper: std.DoublyLinkedList = .{},

        pub fn add_initial(self: *Self, creature: *CreatureType) void {
            self.slicer.append(&creature.slicer_node);
            self.reaper.append(&creature.reaper_node);

            if (self.slicer_current == null) {
                self.slicer_current = &creature.slicer_node;
            }
        }

        pub fn add_child(self: *Self, mother: *CreatureType, daughter: *CreatureType) void {
            self.slicer.insertBefore(&mother.slicer_node, &daughter.slicer_node);
            self.reaper.append(&daughter.reaper_node);
        }

        pub fn remove(self: *Self, creature: *CreatureType) void {
            const slicer_node = &creature.slicer_node;
            const slicer_next = slicer_node.next;

            self.slicer.remove(slicer_node);
            self.reaper.remove(&creature.reaper_node);

            if (slicer_node == self.slicer_current) {
                self.slicer_current = slicer_next orelse self.slicer.first;
            }
        }

        pub fn current_creature(self: *const Self) ?*CreatureType {
            const node = self.slicer_current orelse return null;
            return @fieldParentPtr("slicer_node", node);
        }

        pub fn advance(self: *Self) void {
            const current = self.slicer_current orelse return;

            if (current.next == null) {
                self.slicer_current = self.slicer.first;
            } else {
                self.slicer_current = current.next;
            }
        }

        pub fn next_victim(self: *const Self) ?*CreatureType {
            const node = self.reaper.first orelse return null;
            return @fieldParentPtr("reaper_node", node);
        }

        pub fn on_error(self: *Self, creature: *CreatureType) void {
            creature.errors +|= 1;
            const above_node = creature.reaper_node.prev orelse return;
            const above: *CreatureType = @fieldParentPtr("reaper_node", above_node);

            if (above.errors <= creature.errors) {
                self.reaper.remove(&creature.reaper_node);
                self.reaper.insertBefore(above_node, &creature.reaper_node);
            }
        }

        pub fn on_hard_success(self: *Self, creature: *CreatureType) void {
            const below_node = creature.reaper_node.next orelse return;
            const below: *CreatureType = @fieldParentPtr("reaper_node", below_node);

            if (below.errors >= creature.errors) {
                self.reaper.remove(&creature.reaper_node);
                self.reaper.insertAfter(below_node, &creature.reaper_node);
            }
        }
    };
}
//
// AI generated unit tests.
//

// These objects stay in their original stack slots while their nodes are linked.
const TestCreature = struct {
    slicer_node: std.DoublyLinkedList.Node = .{},
    reaper_node: std.DoublyLinkedList.Node = .{},
    errors: u32 = 0,
};

const TestScheduler = Scheduler(TestCreature);

fn expectQueue(
    comptime node_field: []const u8,
    queue: *const std.DoublyLinkedList,
    expected: []const *TestCreature,
) !void {
    if (expected.len == 0) {
        try testing.expectEqual(null, queue.first);
        try testing.expectEqual(null, queue.last);
        return;
    }

    try testing.expectEqual(&@field(expected[0].*, node_field), queue.first);
    try testing.expectEqual(&@field(expected[expected.len - 1].*, node_field), queue.last);

    // Bound traversal by the expected population so a cycle fails, not hangs.
    var forward = queue.first;
    var previous: ?*std.DoublyLinkedList.Node = null;
    for (expected) |creature| {
        const node = forward orelse return error.TestExpectedEqual;
        try testing.expectEqual(&@field(creature.*, node_field), node);
        try testing.expectEqual(previous, node.prev);
        previous = node;
        forward = node.next;
    }
    try testing.expectEqual(null, forward);

    var backward = queue.last;
    var next: ?*std.DoublyLinkedList.Node = null;
    var remaining = expected.len;
    while (remaining > 0) {
        remaining -= 1;
        const node = backward orelse return error.TestExpectedEqual;
        try testing.expectEqual(&@field(expected[remaining].*, node_field), node);
        try testing.expectEqual(next, node.next);
        next = node;
        backward = node.prev;
    }
    try testing.expectEqual(null, backward);
}

fn expectState(
    scheduler: *const TestScheduler,
    slicer: []const *TestCreature,
    reaper: []const *TestCreature,
    current: ?*TestCreature,
) !void {
    try expectQueue("slicer_node", &scheduler.slicer, slicer);
    try expectQueue("reaper_node", &scheduler.reaper, reaper);
    try testing.expectEqual(current, scheduler.current_creature());
    try testing.expectEqual(
        if (current) |creature| &creature.slicer_node else null,
        scheduler.slicer_current,
    );
    try testing.expectEqual(
        if (reaper.len > 0) reaper[0] else null,
        scheduler.next_victim(),
    );
}

test "empty scheduler queries and repeated advancement are harmless" {
    var scheduler: TestScheduler = .{};
    for (0..3) |_| {
        try expectState(&scheduler, &.{}, &.{}, null);
        scheduler.advance();
    }
    try expectState(&scheduler, &.{}, &.{}, null);
}

test "initial creatures append to both queues without resetting current" {
    var scheduler: TestScheduler = .{};
    var a: TestCreature = .{};
    var b: TestCreature = .{};
    var c: TestCreature = .{};

    scheduler.add_initial(&a);
    try expectState(&scheduler, &.{&a}, &.{&a}, &a);
    scheduler.add_initial(&b);
    try expectState(&scheduler, &.{ &a, &b }, &.{ &a, &b }, &a);
    scheduler.advance();
    scheduler.add_initial(&c);
    try expectState(&scheduler, &.{ &a, &b, &c }, &.{ &a, &b, &c }, &b);
}

test "singleton round robin keeps the same current creature" {
    var scheduler: TestScheduler = .{};
    var a: TestCreature = .{};
    scheduler.add_initial(&a);
    for (0..4) |_| {
        scheduler.advance();
        try expectState(&scheduler, &.{&a}, &.{&a}, &a);
    }
}

test "round robin repeats insertion order and preserves the reaper" {
    var scheduler: TestScheduler = .{};
    var a: TestCreature = .{};
    var b: TestCreature = .{};
    var c: TestCreature = .{};
    const order = [_]*TestCreature{ &a, &b, &c };
    for (order) |creature| scheduler.add_initial(creature);

    for (0..3) |_| {
        for (order) |creature| {
            try expectState(&scheduler, &order, &order, creature);
            scheduler.advance();
        }
    }
    try expectState(&scheduler, &order, &order, &a);
}

test "newborn runs after other creatures and immediately before its mother" {
    var scheduler: TestScheduler = .{};
    var mother: TestCreature = .{};
    var a: TestCreature = .{};
    var b: TestCreature = .{};
    var daughter: TestCreature = .{};
    for ([_]*TestCreature{ &mother, &a, &b }) |creature| scheduler.add_initial(creature);

    scheduler.add_child(&mother, &daughter);
    const slicer = [_]*TestCreature{ &daughter, &mother, &a, &b };
    const reaper = [_]*TestCreature{ &mother, &a, &b, &daughter };
    for ([_]*TestCreature{ &mother, &a, &b, &daughter, &mother }) |creature| {
        try expectState(&scheduler, &slicer, &reaper, creature);
        scheduler.advance();
    }
}

test "singleton mother keeps current at birth then yields to daughter" {
    var scheduler: TestScheduler = .{};
    var mother: TestCreature = .{};
    var daughter: TestCreature = .{};
    scheduler.add_initial(&mother);
    scheduler.add_child(&mother, &daughter);
    try expectState(&scheduler, &.{ &daughter, &mother }, &.{ &mother, &daughter }, &mother);
    scheduler.advance();
    try expectState(&scheduler, &.{ &daughter, &mother }, &.{ &mother, &daughter }, &daughter);
    scheduler.advance();
    try expectState(&scheduler, &.{ &daughter, &mother }, &.{ &mother, &daughter }, &mother);
}

test "birth inserts before mothers at the head middle and tail" {
    for (0..3) |mother_index| {
        var scheduler: TestScheduler = .{};
        var a: TestCreature = .{};
        var b: TestCreature = .{};
        var c: TestCreature = .{};
        var daughter: TestCreature = .{};
        const originals = [_]*TestCreature{ &a, &b, &c };
        for (originals) |creature| scheduler.add_initial(creature);
        for (0..mother_index) |_| scheduler.advance();

        scheduler.add_child(originals[mother_index], &daughter);
        const expected_orders = [_][4]*TestCreature{
            .{ &daughter, &a, &b, &c },
            .{ &a, &daughter, &b, &c },
            .{ &a, &b, &daughter, &c },
        };
        try expectState(&scheduler, &expected_orders[mother_index], &.{ &a, &b, &c, &daughter }, originals[mother_index]);
    }
}

test "repeated births preserve daughter birth order before the mother" {
    var scheduler: TestScheduler = .{};
    var mother: TestCreature = .{};
    var a: TestCreature = .{};
    var first: TestCreature = .{};
    var second: TestCreature = .{};
    scheduler.add_initial(&mother);
    scheduler.add_initial(&a);
    scheduler.add_child(&mother, &first);
    try expectState(&scheduler, &.{ &first, &mother, &a }, &.{ &mother, &a, &first }, &mother);
    scheduler.add_child(&mother, &second);
    const slicer = [_]*TestCreature{ &first, &second, &mother, &a };
    const reaper = [_]*TestCreature{ &mother, &a, &first, &second };
    for ([_]*TestCreature{ &mother, &a, &first, &second, &mother }) |creature| {
        try expectState(&scheduler, &slicer, &reaper, creature);
        scheduler.advance();
    }
}

test "removing current at head middle or tail selects its circular successor" {
    for (0..3) |removed_index| {
        var scheduler: TestScheduler = .{};
        var a: TestCreature = .{};
        var b: TestCreature = .{};
        var c: TestCreature = .{};
        const originals = [_]*TestCreature{ &a, &b, &c };
        for (originals) |creature| scheduler.add_initial(creature);
        for (0..removed_index) |_| scheduler.advance();

        scheduler.remove(originals[removed_index]);
        const expected_orders = [_][2]*TestCreature{ .{ &b, &c }, .{ &a, &c }, .{ &a, &b } };
        const successors = [_]*TestCreature{ &b, &c, &a };
        try expectState(&scheduler, &expected_orders[removed_index], &expected_orders[removed_index], successors[removed_index]);
        scheduler.advance();
        const following = [_]*TestCreature{ &c, &a, &b };
        try expectState(&scheduler, &expected_orders[removed_index], &expected_orders[removed_index], following[removed_index]);
    }
}

test "removing noncurrent head middle or tail preserves current" {
    for ([_]usize{ 0, 2, 3 }, 0..) |removed_index, case_index| {
        var scheduler: TestScheduler = .{};
        var a: TestCreature = .{};
        var b: TestCreature = .{};
        var c: TestCreature = .{};
        var d: TestCreature = .{};
        const originals = [_]*TestCreature{ &a, &b, &c, &d };
        for (originals) |creature| scheduler.add_initial(creature);
        scheduler.advance();

        scheduler.remove(originals[removed_index]);
        const expected_orders = [_][3]*TestCreature{ .{ &b, &c, &d }, .{ &a, &b, &d }, .{ &a, &b, &c } };
        try expectState(&scheduler, &expected_orders[case_index], &expected_orders[case_index], &b);
    }
}

test "singleton removal restores empty queries and advancement" {
    var scheduler: TestScheduler = .{};
    var a: TestCreature = .{};
    scheduler.add_initial(&a);
    scheduler.remove(&a);
    try expectState(&scheduler, &.{}, &.{}, null);
    scheduler.advance();
    try expectState(&scheduler, &.{}, &.{}, null);
}

test "removed nodes can be reinserted and an emptied scheduler can restart" {
    var scheduler: TestScheduler = .{};
    var a: TestCreature = .{};
    var b: TestCreature = .{};
    var c: TestCreature = .{};
    var fresh: TestCreature = .{};
    for ([_]*TestCreature{ &a, &b, &c }) |creature| scheduler.add_initial(creature);
    scheduler.remove(&b);
    try expectState(&scheduler, &.{ &a, &c }, &.{ &a, &c }, &a);
    scheduler.add_initial(&b);
    try expectState(&scheduler, &.{ &a, &c, &b }, &.{ &a, &c, &b }, &a);
    scheduler.remove(&a);
    try expectState(&scheduler, &.{ &c, &b }, &.{ &c, &b }, &c);
    scheduler.remove(&c);
    try expectState(&scheduler, &.{&b}, &.{&b}, &b);
    scheduler.remove(&b);
    try expectState(&scheduler, &.{}, &.{}, null);
    scheduler.add_initial(&fresh);
    try expectState(&scheduler, &.{&fresh}, &.{&fresh}, &fresh);
    scheduler.remove(&fresh);
    try expectState(&scheduler, &.{}, &.{}, null);
    scheduler.add_initial(&b);
    try expectState(&scheduler, &.{&b}, &.{&b}, &b);
}

test "error penalty compares updated count and moves at most one position" {
    // Relative to the target's updated count of 4: lower, equal, greater.
    for ([_]u32{ 3, 4, 5 }) |neighbor_errors| {
        var scheduler: TestScheduler = .{};
        var a: TestCreature = .{ .errors = 0 };
        var b: TestCreature = .{ .errors = neighbor_errors };
        var target: TestCreature = .{ .errors = 3 };
        var d: TestCreature = .{ .errors = 0 };
        const slicer = [_]*TestCreature{ &a, &b, &target, &d };
        for (slicer) |creature| scheduler.add_initial(creature);
        scheduler.advance();
        scheduler.advance();

        scheduler.on_error(&target);
        const reaper: [4]*TestCreature = if (neighbor_errors <= 4)
            .{ &a, &target, &b, &d }
        else
            .{ &a, &b, &target, &d };
        try expectState(&scheduler, &slicer, &reaper, &target);
        try testing.expectEqual(@as(u32, 4), target.errors);
        try testing.expectEqual(neighbor_errors, b.errors);
        try testing.expectEqual(@as(u32, 0), a.errors);
        try testing.expectEqual(@as(u32, 0), d.errors);
    }
}

test "errors at the reaper head still increment including a singleton" {
    var scheduler: TestScheduler = .{};
    var a: TestCreature = .{};
    var b: TestCreature = .{ .errors = 7 };
    scheduler.add_initial(&a);
    scheduler.on_error(&a);
    try testing.expectEqual(@as(u32, 1), a.errors);
    try expectState(&scheduler, &.{&a}, &.{&a}, &a);
    scheduler.add_initial(&b);
    scheduler.on_error(&a);
    try testing.expectEqual(@as(u32, 2), a.errors);
    try testing.expectEqual(@as(u32, 7), b.errors);
    try expectState(&scheduler, &.{ &a, &b }, &.{ &a, &b }, &a);
}

test "error counts saturate and still permit one-position movement" {
    var scheduler: TestScheduler = .{};
    const maximum = std.math.maxInt(u32);
    var a: TestCreature = .{};
    var b: TestCreature = .{ .errors = maximum };
    var target: TestCreature = .{ .errors = maximum - 1 };
    const slicer = [_]*TestCreature{ &a, &b, &target };
    for (slicer) |creature| scheduler.add_initial(creature);

    scheduler.on_error(&target);
    try testing.expectEqual(maximum, target.errors);
    try expectState(&scheduler, &slicer, &.{ &a, &target, &b }, &a);
    scheduler.on_error(&b);
    try testing.expectEqual(maximum, b.errors);
    try expectState(&scheduler, &slicer, &.{ &a, &b, &target }, &a);
    scheduler.on_error(&target);
    try testing.expectEqual(maximum, target.errors);
    try testing.expectEqual(maximum, b.errors);
    try testing.expectEqual(@as(u32, 0), a.errors);
    try expectState(&scheduler, &slicer, &.{ &a, &target, &b }, &a);
}

test "hard success preserves counts and moves at most one position" {
    // Relative to the target's count of 4: greater, equal, lower.
    for ([_]u32{ 5, 4, 3 }) |neighbor_errors| {
        var scheduler: TestScheduler = .{};
        var a: TestCreature = .{ .errors = 7 };
        var target: TestCreature = .{ .errors = 4 };
        var c: TestCreature = .{ .errors = neighbor_errors };
        var d: TestCreature = .{ .errors = 9 };
        const slicer = [_]*TestCreature{ &a, &target, &c, &d };
        for (slicer) |creature| scheduler.add_initial(creature);
        scheduler.advance();

        scheduler.on_hard_success(&target);
        const reaper: [4]*TestCreature = if (neighbor_errors >= 4)
            .{ &a, &c, &target, &d }
        else
            .{ &a, &target, &c, &d };
        try expectState(&scheduler, &slicer, &reaper, &target);
        try testing.expectEqual(@as(u32, 4), target.errors);
        try testing.expectEqual(neighbor_errors, c.errors);
        try testing.expectEqual(@as(u32, 7), a.errors);
        try testing.expectEqual(@as(u32, 9), d.errors);
    }
}

test "hard success can move the head and is harmless at tail or singleton" {
    var scheduler: TestScheduler = .{};
    var a: TestCreature = .{ .errors = 2 };
    var b: TestCreature = .{ .errors = 2 };
    scheduler.add_initial(&a);
    scheduler.on_hard_success(&a);
    try expectState(&scheduler, &.{&a}, &.{&a}, &a);
    scheduler.add_initial(&b);
    scheduler.on_hard_success(&b);
    try expectState(&scheduler, &.{ &a, &b }, &.{ &a, &b }, &a);
    scheduler.on_hard_success(&a);
    try expectState(&scheduler, &.{ &a, &b }, &.{ &b, &a }, &a);
    scheduler.on_hard_success(&a);
    try expectState(&scheduler, &.{ &a, &b }, &.{ &b, &a }, &a);
    try testing.expectEqual(@as(u32, 2), a.errors);
    try testing.expectEqual(@as(u32, 2), b.errors);
}

test "victim queries observe the head without consuming it" {
    var scheduler: TestScheduler = .{};
    var a: TestCreature = .{};
    var b: TestCreature = .{};
    scheduler.add_initial(&a);
    scheduler.add_initial(&b);
    for (0..3) |_| {
        try testing.expectEqual(&a, scheduler.next_victim());
        try expectState(&scheduler, &.{ &a, &b }, &.{ &a, &b }, &a);
    }
    scheduler.on_hard_success(&a);
    for (0..3) |_| {
        try testing.expectEqual(&b, scheduler.next_victim());
        try expectState(&scheduler, &.{ &a, &b }, &.{ &b, &a }, &a);
    }
}

test "birth penalty reward reaping and advancement preserve independent queues" {
    var scheduler: TestScheduler = .{};
    var mother: TestCreature = .{};
    var a: TestCreature = .{};
    var b: TestCreature = .{};
    var daughter: TestCreature = .{};
    for ([_]*TestCreature{ &mother, &a, &b }) |creature| scheduler.add_initial(creature);
    scheduler.add_child(&mother, &daughter);
    const slicer = [_]*TestCreature{ &daughter, &mother, &a, &b };
    try expectState(&scheduler, &slicer, &.{ &mother, &a, &b, &daughter }, &mother);

    scheduler.on_error(&daughter);
    try expectState(&scheduler, &slicer, &.{ &mother, &a, &daughter, &b }, &mother);
    scheduler.on_hard_success(&mother);
    try expectState(&scheduler, &slicer, &.{ &a, &mother, &daughter, &b }, &mother);
    scheduler.remove(scheduler.next_victim().?);
    try expectState(&scheduler, &.{ &daughter, &mother, &b }, &.{ &mother, &daughter, &b }, &mother);
    scheduler.advance();
    try expectState(&scheduler, &.{ &daughter, &mother, &b }, &.{ &mother, &daughter, &b }, &b);
    scheduler.advance();
    try expectState(&scheduler, &.{ &daughter, &mother, &b }, &.{ &mother, &daughter, &b }, &daughter);

    // Removing current at the physical head must select the mother, even though
    // their order in the reaper is different.
    scheduler.remove(&daughter);
    try expectState(&scheduler, &.{ &mother, &b }, &.{ &mother, &b }, &mother);
    scheduler.remove(scheduler.next_victim().?);
    try expectState(&scheduler, &.{&b}, &.{&b}, &b);
    scheduler.remove(scheduler.next_victim().?);
    try expectState(&scheduler, &.{}, &.{}, null);
    try testing.expectEqual(@as(u32, 1), daughter.errors);
    try testing.expectEqual(@as(u32, 0), mother.errors);
}
