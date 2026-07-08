const std = @import("std");
const config = @import("config.zon");
const zierra = @import("zierra");

pub fn main() !void {
    // Prints to stderr, ignoring potential errors.
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
    try zierra.bufferedPrint();
}
