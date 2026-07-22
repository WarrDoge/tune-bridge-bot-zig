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
