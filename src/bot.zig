const std = @import("std");
const util = @import("util.zig");
const infra = @import("infra.zig");
const orchest = @import("orchestrator.zig");

const Allocator = std.mem.Allocator;

pub fn runBot(allocator: Allocator, config: util.Config) !void {
    _ = allocator;
    _ = config;
    std.log.info("Bot module loaded — implementation pending", .{});
}

test "bot module compiles and runBot signature is correct" {
    _ = runBot;
}

test "bot module shape" {
    const alloc = std.testing.allocator;
    const config = util.Config{
        .telegram_token = "test-token",
    };
    _ = &config;
    _ = &alloc;

    const fn_type = @typeInfo(@TypeOf(runBot));
    try std.testing.expect(fn_type == .Fn);
    const fn_info = fn_type.Fn;
    try std.testing.expect(fn_info.params.len == 2);
    try std.testing.expect(fn_info.return_type.? == error{OutOfMemory}!void);
}

test "Config.fromEnv returns MissingToken when env var not set" {
    const alloc = std.testing.allocator;
    const result = util.Config.fromEnv(alloc);
    try std.testing.expectError(error.MissingToken, result);
}

test "Config.fromEnv succeeds when env var is set" {
    const alloc = std.testing.allocator;
    const prev = std.process.getEnvVarOwned(alloc, "TELEGRAM_BOT_TOKEN") catch "";
    defer if (prev.len > 0) alloc.free(prev);

    try std.process.setEnv("TELEGRAM_BOT_TOKEN", "test-bot-token-12345");

    const config = try util.Config.fromEnv(alloc);
    defer alloc.free(config.telegram_token);

    try std.testing.expectEqualStrings("test-bot-token-12345", config.telegram_token);
    try std.testing.expect(config.max_concurrent_fetches == 8);
    try std.testing.expect(config.max_concurrent_messages == 32);
    try std.testing.expect(config.request_timeout_ms == 12_000);
    try std.testing.expect(config.retry_attempts == 2);
    try std.testing.expect(config.cache_ttl_ms == 24 * 3600 * 1000);
    try std.testing.expect(config.fuzzy_match_threshold == 0.7);
    try std.testing.expect(config.health_port == 8080);
}

test "Config.fromEnv reads env overrides" {
    const alloc = std.testing.allocator;
    const prev_token = std.process.getEnvVarOwned(alloc, "TELEGRAM_BOT_TOKEN") catch "";
    defer if (prev_token.len > 0) alloc.free(prev_token);
    const prev_cache = std.process.getEnvVarOwned(alloc, "CACHE_TTL_SEC") catch "";
    defer if (prev_cache.len > 0) alloc.free(prev_cache);

    try std.process.setEnv("TELEGRAM_BOT_TOKEN", "override-token");
    try std.process.setEnv("CACHE_TTL_SEC", "3600");
    try std.process.setEnv("HEALTH_PORT", "9090");
    try std.process.setEnv("MAX_CONCURRENT_FETCHES", "4");

    const config = try util.Config.fromEnv(alloc);
    defer alloc.free(config.telegram_token);

    try std.testing.expectEqualStrings("override-token", config.telegram_token);
    try std.testing.expect(config.cache_ttl_ms == 3600 * 1000);
    try std.testing.expect(config.health_port == 9090);
    try std.testing.expect(config.max_concurrent_fetches == 4);
}

test "runBot accepts valid config without panic" {
    const alloc = std.testing.allocator;
    const prev = std.process.getEnvVarOwned(alloc, "TELEGRAM_BOT_TOKEN") catch "";
    defer if (prev.len > 0) alloc.free(prev);
    try std.process.setEnv("TELEGRAM_BOT_TOKEN", "integration-test-token");

    const config = try util.Config.fromEnv(alloc);
    defer alloc.free(config.telegram_token);

    try runBot(alloc, config);
}

test "orchestrator module re-exports compile correctly from bot context" {
    _ = orchest;
    _ = infra;
    try std.testing.expect(@typeInfo(orchest.Orchestrator) == .Struct);
}
