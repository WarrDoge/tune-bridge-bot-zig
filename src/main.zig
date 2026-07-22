const std = @import("std");
const builtin = @import("builtin");

const util = @import("util.zig");
const infra = @import("infra.zig");
const orchest = @import("orchestrator.zig");
const platform_mod = @import("platform.zig");
const bot_mod = @import("bot.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = util.Config.fromEnv(allocator) catch |err| {
        const msg = switch (err) {
            error.MissingToken => "TELEGRAM_BOT_TOKEN environment variable required",
            error.EmptyToken => "TELEGRAM_BOT_TOKEN must not be empty",
            else => "Configuration error",
        };
        std.log.err("Configuration error: {s}", .{msg});
        std.process.exit(1);
    };

    std.log.info("Music Link Converter Bot starting...", .{});
    std.log.info("No API keys required - using web scraping!", .{});

    // Start health server in a thread
    const health_port = config.health_port;
    _ = try std.Thread.spawn(.{}, struct {
        fn run(port: u16) void {
            healthServer(port) catch {};
        }
    }.run, .{health_port});

    // Start the bot
    try bot_mod.runBot(allocator, config);
}

fn healthServer(port: u16) !void {
    const addr = try std.net.Address.parseIp("0.0.0.0", port);
    var listener = try addr.listen(.{ .reuse_address = true });
    std.log.info("Health server listening on 0.0.0.0:{d}", .{port});
    defer listener.deinit();

    while (true) {
        const conn = try listener.accept();
        _ = try std.Thread.spawn(.{}, struct {
            fn handle(conn2: std.net.Server.Connection) void {
                defer conn2.stream.close();
                var buf: [1024]u8 = undefined;
                const n = conn2.stream.read(&buf) catch return;
                const request = buf[0..n];
                const response: []const u8 = if (std.mem.startsWith(u8, request, "GET /ready"))
                    "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nREADY"
                else
                    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nOK";
                conn2.stream.writeAll(response) catch {};
            }
        }.handle, .{conn});
    }
}
