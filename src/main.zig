const std = @import("std");
const zierra = @import("zierra");

pub fn main(init: std.process.Init) !void {
    std.debug.print("Printing config...");
    zierra.print_config();

    const simulation = zierra.Simulation(zierra.config).init();

    _ = simulation;

    // Prints to stderr, ignoring potential errors.
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
    try zierra.bufferedPrint(init.io);
}
