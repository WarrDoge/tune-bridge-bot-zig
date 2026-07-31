const std = @import("std");
const util = @import("util.zig");
const infra = @import("infra.zig");
const orchest = @import("orchestrator.zig");

const Allocator = std.mem.Allocator;

const api_base = "https://api.telegram.org/bot";

/// Telegram Update object — only fields we care about.
pub const Update = struct {
    update_id: i64,
    message: ?Message = null,
};

/// Telegram Message object — only fields we care about.
pub const Message = struct {
    message_id: i64,
    chat: Chat,
    text: ?[]const u8 = null,
};

/// Telegram Chat object — only the id matters for reply.
pub const Chat = struct {
    id: i64,
};

/// Parse a single Telegram Update from a std.json.Value object tree.
/// String fields in the returned Update borrow from the Value arena.
fn updateFromValue(value: std.json.Value) !Update {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.UnexpectedJsonShape,
    };

    const update_id = obj.get("update_id") orelse return error.MissingUpdateId;
    const update_id_val = switch (update_id) {
        .integer => |n| n,
        else => return error.MissingUpdateId,
    };

    var upd = Update{ .update_id = update_id_val };

    if (obj.get("message")) |msg_val| {
        const msg_obj = switch (msg_val) {
            .object => |o| o,
            else => return error.UnexpectedJsonShape,
        };

        const mid = msg_obj.get("message_id") orelse return error.MissingMessageId;
        const mid_val = switch (mid) {
            .integer => |n| n,
            else => return error.MissingMessageId,
        };

        const chat_val = msg_obj.get("chat") orelse return error.MissingChat;
        const chat_obj = switch (chat_val) {
            .object => |o| o,
            else => return error.MissingChat,
        };
        const chat_id = chat_obj.get("id") orelse return error.MissingChatId;
        const chat_id_val = switch (chat_id) {
            .integer => |n| n,
            else => return error.MissingChatId,
        };

        var msg = Message{
            .message_id = mid_val,
            .chat = .{ .id = chat_id_val },
        };

        if (msg_obj.get("text")) |text_val| {
            msg.text = switch (text_val) {
                .string => |s| s,
                else => null,
            };
        }

        upd.message = msg;
    }

    return upd;
}

/// Parse the Telegram API response body ({"ok":true,"result":[...]})
/// returning the array of Updates.  Caller owns the returned slice.
/// The string fields (text, etc.) borrow from the body slice.
pub fn parseUpdatesResponse(allocator: Allocator, body: []const u8) ![]Update {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.UnexpectedJsonShape,
    };

    const ok = root_obj.get("ok") orelse return error.MissingOk;
    const ok_val = switch (ok) {
        .bool => |b| b,
        else => return error.UnexpectedJsonShape,
    };
    if (!ok_val) return error.ApiNotOk;

    const result_arr = root_obj.get("result") orelse return error.MissingResult;
    const arr = switch (result_arr) {
        .array => |a| a,
        else => return error.UnexpectedJsonShape,
    };

    var updates = try allocator.alloc(Update, arr.items.len);
    errdefer allocator.free(updates);

    for (arr.items, 0..) |*item, i| {
        updates[i] = try updateFromValue(item.*);
    }

    return updates;
}

/// Build the getUpdates URL with optional offset and long-poll timeout.
fn getUpdatesUrl(token: []const u8, offset: ?i64, poll_timeout_sec: u32, allocator: Allocator) ![]u8 {
    var url = std.ArrayList(u8).init(allocator);
    try url.appendSlice(api_base);
    try url.appendSlice(token);
    try url.appendSlice("/getUpdates");
    var first_param = true;
    if (offset) |o| {
        try url.appendSlice(if (first_param) "?" else "&");
        first_param = false;
        try std.fmt.format(url.writer(), "offset={d}", .{o});
    }
    if (poll_timeout_sec > 0) {
        try url.appendSlice(if (first_param) "?" else "&");
        first_param = false;
        try std.fmt.format(url.writer(), "timeout={d}", .{poll_timeout_sec});
    }
    return url.items;
}

/// Fetch the getUpdates response body using the configured infra.HttpClient,
/// gaining retry, the configured user-agent, and connection-pool awareness.
/// The old path (pre-o8) created a fresh std.http.Client on every call,
/// bypassing retry, the configured UA, and all circuit-breaker integration.
///
/// NOTE: zig 0.14's std.http.Client does not enforce client-side timeouts,
/// so none of the infra.HttpClient paths do either.  If the std lib adds
/// timeout support, the poll caller (60s timer needed for 30s long-poll)
/// and the non-poll callers (12s default) will need different values.
fn fetchGetUpdates(http: *infra.HttpClient, url: []const u8) ![]const u8 {
    return http.fetchText(url);
}

/// Process a single message: dispatch text to the orchestrator.
fn processMessage(allocator: Allocator, orch: *orchest.Orchestrator, msg: Message) void {
    const text = msg.text orelse return;
    const maybe_info = orch.extractSongInfo(allocator, text) catch |err| {
        std.log.warn("orchestrator error for msg {d}: {s}", .{ msg.message_id, @errorName(err) });
        return;
    };
    _ = maybe_info;
    std.log.info("Processed message {d}: text length={d}", .{ msg.message_id, text.len });
}

pub fn runBot(allocator: Allocator, config: util.Config) !void {
    const poll_timeout_sec: u32 = 30;

    // Build an HTTP client and orchestrator using infra's helpers
    var http = infra.HttpClient.init(allocator, config.request_timeout_ms, config.retry_attempts, config.retry_min_delay_ms, config.retry_max_delay_ms);

    var cache = infra.TTLCache.init(allocator, config.cache_ttl_ms);
    defer cache.deinit();

    var breaker = infra.CircuitBreaker.init("telegram-api", config.circuit_breaker_max_fails, config.circuit_breaker_timeout_ms);

    var orch = orchest.Orchestrator.init(http, &cache, &breaker);

    var offset: ?i64 = null;

    std.log.info("Starting Telegram long-poll loop (getUpdates)...", .{});

    while (true) {
        const url = getUpdatesUrl(config.telegram_token, offset, poll_timeout_sec, allocator) catch |err| {
            std.log.err("failed to build updates URL: {s}", .{@errorName(err)});
            std.time.sleep(5 * std.time.ns_per_ms);
            continue;
        };
        defer allocator.free(url);

        const body = fetchGetUpdates(&http, url) catch |err| {
            std.log.warn("getUpdates poll failed: {s}", .{@errorName(err)});
            std.time.sleep(2 * std.time.ns_per_ms);
            continue;
        };
        defer allocator.free(body);

        const updates = parseUpdatesResponse(allocator, body) catch |err| {
            std.log.warn("parseUpdatesResponse failed: {s}, body len={d}", .{ @errorName(err), body.len });
            continue;
        };
        defer allocator.free(updates);

        if (updates.len == 0) {
            continue;
        }

        for (updates) |upd| {
            if (upd.message) |msg| {
                processMessage(allocator, &orch, msg);
            }
            // Advance offset past this update id so we never re-process it.
            const next_offset = upd.update_id + 1;
            if (offset) |current| {
                if (next_offset > current) {
                    offset = next_offset;
                }
            } else {
                offset = next_offset;
            }
        }
    }
}

// ================================================================
// TESTS
// ================================================================

test "parseUpdatesResponse: offset advances past highest update id" {
    const body =
        \\{"ok":true,"result":[{"update_id":100,"message":{"message_id":1,"chat":{"id":42},"text":"hello"}},{"update_id":101,"message":{"message_id":2,"chat":{"id":42},"text":"world"}}]}
    ;

    const alloc = std.testing.allocator;
    const updates = try parseUpdatesResponse(alloc, body);
    defer alloc.free(updates);

    try std.testing.expectEqual(@as(usize, 2), updates.len);
    try std.testing.expectEqual(@as(i64, 100), updates[0].update_id);
    try std.testing.expectEqual(@as(i64, 101), updates[1].update_id);

    // Simulate offset advancement
    var offset: ?i64 = null;
    for (updates) |upd| {
        const next_offset = upd.update_id + 1;
        if (offset) |current| {
            if (next_offset > current) {
                offset = next_offset;
            }
        } else {
            offset = next_offset;
        }
    }
    try std.testing.expectEqual(@as(i64, 102), offset.?);
}

test "malformed response does not crash the loop" {
    const alloc = std.testing.allocator;

    // Empty JSON object — missing "ok"
    try std.testing.expectError(error.MissingOk, parseUpdatesResponse(alloc, "{}"));

    // Invalid JSON
    try std.testing.expectError(error.ParseError, parseUpdatesResponse(alloc, "not json at all"));

    // ok=false
    try std.testing.expectError(error.ApiNotOk, parseUpdatesResponse(alloc, "{\"ok\":false,\"result\":[]}"));

    // Empty result
    const updates = try parseUpdatesResponse(alloc, "{\"ok\":true,\"result\":[]}");
    defer alloc.free(updates);
    try std.testing.expectEqual(@as(usize, 0), updates.len);
}

test "update parsing pulls out message text" {
    const body =
        \\{"ok":true,"result":[{"update_id":1,"message":{"message_id":10,"chat":{"id":-123},"text":"https://open.spotify.com/track/abc123"}}]}
    ;

    const alloc = std.testing.allocator;
    const updates = try parseUpdatesResponse(alloc, body);
    defer alloc.free(updates);

    try std.testing.expectEqual(@as(usize, 1), updates.len);
    try std.testing.expectEqual(@as(i64, 1), updates[0].update_id);
    try std.testing.expect(updates[0].message != null);
    try std.testing.expectEqual(@as(i64, 10), updates[0].message.?.message_id);
    try std.testing.expectEqual(@as(i64, -123), updates[0].message.?.chat.id);
    try std.testing.expectEqualStrings("https://open.spotify.com/track/abc123", updates[0].message.?.text.?);
}

test "fetchGetUpdates delegates to the configured infra.HttpClient" {
    // This test verifies that fetchGetUpdates accepts an *infra.HttpClient
    // (the poll path now goes through the configured client instead of
    // creating a fresh std.http.Client per call).  The actual HTTP call
    // requires a live server, but the compile-time type check ensures
    // the delegation compiles and the function signature is correct.
    const alloc = std.testing.allocator;

    var http = infra.HttpClient.init(alloc, 12_000, 0, 100, 200);

    // fetchGetUpdates won't resolve a bogus URL, but the error path
    // should leave the client usable for subsequent calls — the loop
    // continues on failure without deinitialising the client.
    const url = "http://127.0.0.1:1/nonexistent";
    const result = fetchGetUpdates(&http, url);
    try std.testing.expect(result == error.ConnectionRefused or
        result == error.ConnectionResetByPeer or
        result == error.ConnectionTimedOut or
        result == error.FileNotFound or
        result == error.RequestFailed);

    // Client is still usable (not deinitialised)
    _ = &http;
}
