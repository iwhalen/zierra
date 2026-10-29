const std = @import("std");
pub const config = @import("config.zig");
pub const Simulation = @import("sim/simulation.zig").Simulation;
pub const ancestor_genome = @import("sim/ancestor.zig").ancestor_genome;

test {
    _ = Simulation;
}

/// Prints each validated configuration value to stderr for debugging.
pub fn print_config() void {
    std.debug.print("soup_size = {d}\n", .{config.soup_size});
    std.debug.print("stack_depth = {d}\n", .{config.stack_depth});
    std.debug.print("search_limit = {d}\n", .{config.search_limit});
    std.debug.print("lineage_enabled = {}\n", .{config.lineage_enabled});
    std.debug.print("display_enabled = {}\n", .{config.display_enabled});
    std.debug.print("reaper_threshold = {d}\n", .{config.reaper_threshold});
    std.debug.print("cosmic_rate = {d}\n", .{config.cosmic_rate});
    std.debug.print("copy_error_rate = {d}\n", .{config.copy_error_rate});
    std.debug.print("flaw_rate = {d}\n", .{config.flaw_rate});
    std.debug.print("slicer_power = {d}\n", .{config.slicer_power});
    std.debug.print("snapshot_interval = {d}\n", .{config.snapshot_interval});
    std.debug.print("output_dir = {s}\n", .{config.output_dir});
    std.debug.print("rng_seed = {d}\n", .{config.rng_seed});
}
