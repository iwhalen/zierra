const std = @import("std");
const zierra = @import("zierra");

var simulation: zierra.Simulation(zierra.config) = undefined;

pub fn main(init: std.process.Init) !void {
    _ = init;

    std.debug.print("Printing config...", .{});
    zierra.print_config();

    simulation.init();
}
