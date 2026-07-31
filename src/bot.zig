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

test "runBot accepts valid config and does not panic" {
    const alloc = std.testing.allocator;
    const config = util.Config{ .telegram_token = "test_token_12345" };
    try runBot(alloc, config);
}

test "runBot accepts config with non-default values" {
    const alloc = std.testing.allocator;
    const config = util.Config{
        .telegram_token = "another_token",
        .max_concurrent_fetches = 16,
        .max_concurrent_messages = 64,
        .health_port = 9090,
    };
    try runBot(alloc, config);
}

test "runBot accepts config with minimum fields only" {
    const alloc = std.testing.allocator;
    const config = util.Config{ .telegram_token = "tok" };
    try runBot(alloc, config);
}
