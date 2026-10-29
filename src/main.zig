const std = @import("std");
const zierra = @import("zierra");

var simulation: zierra.Simulation(zierra.config) = undefined;

pub fn main(init: std.process.Init) !void {
    _ = init;

    std.debug.print("Printing config...\n", .{});

    zierra.print_config();

    std.debug.print("Starting simulation...", .{});

    simulation.init();
    _ = try simulation.inoculate(&zierra.ancestor_genome, 0);
    _ = try simulation.run(20_000); // TEMP: Temporary max instructions in simulation run.

    std.debug.print("\nDone!\n", .{});
}
