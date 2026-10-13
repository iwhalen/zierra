const std = @import("std");

const config_raw = @import("config.zon");

const Config = struct {
    comptime soup_size: u16 = config_raw.soup_size,
    comptime stack_depth: u16 = config_raw.stack_depth,
    comptime search_limit: u16 = config_raw.search_limit,
    comptime lineage_enabled: bool = config_raw.lineage_enabled,
    comptime display_enabled: bool = config_raw.display_enabled,
    comptime reaper_threshold: f32 = config_raw.reaper_threshold,
    comptime cosmic_rate: u32 = config_raw.cosmic_rate,
    comptime copy_error_rate: u32 = config_raw.copy_error_rate,
    comptime flaw_rate: f32 = config_raw.flaw_rate,
    comptime slicer_power: f32 = config_raw.slicer_power,
    comptime snapshot_interval: u64 = config_raw.snapshot_interval,
    comptime output_dir: []const u8 = config_raw.output_dir,
    comptime rng_seed: u64 = config_raw.rng_seed,
};

fn validate() Config {
    const config = Config{};

    if (config.soup_size == 0) {
        @compileError("Soup size cannot be 0.");
    }

    if (config.stack_depth == 0) {
        @compileError("Stack depth cannot be 0.");
    }

    if (!std.math.isFinite(config.reaper_threshold) or config.reaper_threshold <= 0 or config.reaper_threshold >= 1) {
        @compileError("Reaper threshold must be finite and in the open interval (0, 1).");
    }

    if (!std.math.isFinite(config.flaw_rate) or config.flaw_rate < 0) {
        @compileError("Flaw rate must be finite and non-negative.");
    }

    if (!std.math.isFinite(config.slicer_power) or config.slicer_power < 0) {
        @compileError("Slicer power must be finite and non-negative.");
    }

    if (config.copy_error_rate > 0 and config.flaw_rate > 0) {
        const copy_interval: f64 = @floatFromInt(config.copy_error_rate);
        const flaw_multiplier: f64 = config.flaw_rate;
        const interval = @max(1, @ceil(copy_interval * flaw_multiplier));

        if (!std.math.isFinite(interval)) {
            @compileError("copy_error_rate * flaw_rate must be finite.");
        }

        if (interval > std.math.maxInt(u32)) {
            @compileError("copy_error_rate * flaw_rate must fit in u32.");
        }
    }
    return config;
}

const validated = validate();

pub const soup_size: u16 = validated.soup_size;
pub const stack_depth: u16 = validated.stack_depth;
pub const search_limit: u16 = validated.search_limit;
pub const lineage_enabled: bool = validated.lineage_enabled;
pub const display_enabled: bool = validated.display_enabled;
pub const reaper_threshold: f32 = validated.reaper_threshold;
pub const cosmic_rate: u32 = validated.cosmic_rate;
pub const copy_error_rate: u32 = validated.copy_error_rate;
pub const flaw_rate: f32 = validated.flaw_rate;
pub const slicer_power: f32 = validated.slicer_power;
pub const snapshot_interval: u64 = validated.snapshot_interval;
pub const output_dir: []const u8 = validated.output_dir;
pub const rng_seed: u64 = validated.rng_seed;
