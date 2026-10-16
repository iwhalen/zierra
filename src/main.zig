const std = @import("std");
const zierra = @import("zierra");

pub fn main(init: std.process.Init) !void {
    zierra.print_config();

    // Prints to stderr, ignoring potential errors.
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
    try zierra.bufferedPrint(init.io);
}
