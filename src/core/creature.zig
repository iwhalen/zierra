const std = @import("std");

const CreatureId = u8;

const GenotypeId = struct {
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
