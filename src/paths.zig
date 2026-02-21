const std = @import("std");

pub const APP_NAME = "zagent";
pub const CONFIG_SUBDIR = ".config";
pub const LOGS_DIR_NAME = "logs";
pub const TRANSCRIPTS_DIR_NAME = "transcripts";
pub const CONTEXTS_DIR_NAME = "contexts";
pub const DEBUG_LOG_NAME = "debug.log";
pub const SETTINGS_FILENAME = "settings.json";
pub const PROVIDER_ENV_FILENAME = "provider.env";
pub const PROVIDER_ENV_LEGACY_FILENAME = "providers.env";
pub const HISTORY_FILENAME = "history";
pub const SELECTED_MODEL_FILENAME = "config.json";

pub fn getConfigDir(allocator: std.mem.Allocator) ![]u8 {
    const home = std.posix.getenv("HOME") orelse "/tmp";
    return std.fs.path.join(allocator, &.{ home, CONFIG_SUBDIR, APP_NAME });
}

pub fn getLogPath(allocator: std.mem.Allocator) ![]u8 {
    const config_dir = try getConfigDir(allocator);
    defer allocator.free(config_dir);
    return std.fs.path.join(allocator, &.{ config_dir, LOGS_DIR_NAME, DEBUG_LOG_NAME });
}

pub fn getTranscriptsDir(allocator: std.mem.Allocator, config_dir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ config_dir, TRANSCRIPTS_DIR_NAME });
}

pub fn getContextsDir(allocator: std.mem.Allocator, config_dir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ config_dir, CONTEXTS_DIR_NAME });
}
