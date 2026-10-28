const std = @import("std");
const Allocation = @import("soup.zig").Allocation;

pub fn Creature(comptime CpuType: type) type {
    return struct {
        // Reusable slot index for creature lookup and soup ownership.
        slot_id: u16,

        // Unique birth identity within a simulation; never reused after death.
        organism_id: u64,

        // Each creature has its own CPU.
        cpu: CpuType,

        mother_alloc: Allocation,
        daughter_alloc: ?Allocation,

        errors: u32 = 0,
        instructions_executed: u64 = 0,
        instructions_copied: u64 = 0,

        parent_genotype: ?GenotypeId,
        origin_time: u64,

        // Creatures know where they are in queues.
        slicer_node: std.DoublyLinkedList.Node = .{},
        reaper_node: std.DoublyLinkedList.Node = .{},
    };
}

pub const GenotypeId = struct {
    size: u16, // Genome length in instructions
    code: [3]u8, // 3-letter label, e.g., "aaa"

    pub fn format(self: GenotypeId, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d:0>4}{s}", .{ self.size, self.code[0..] });
    }
};

test "GenotypeId format method" {
    const id = GenotypeId{
        .size = 80,
        .code = [3]u8{ 'a', 'a', 'a' },
    };

    var buffer: [7]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buffer, "{f}", .{id});

    try std.testing.expectEqualStrings("0080aaa", formatted);
}
