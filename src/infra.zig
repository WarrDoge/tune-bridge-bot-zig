const std = @import("std");
const util = @import("util.zig");

// ============================================================
// TTL CACHE (thread-safe via mutex, lazy + periodic eviction)
// ============================================================

pub const CacheEntry = struct {
    value: []u8,
    expires_at: i64,
};

pub const TTLCache = struct {
    map: std.StringHashMap(CacheEntry),
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    ttl_ms: i64,
    max_capacity: usize,
    set_count: usize,

    pub fn init(allocator: std.mem.Allocator, ttl_ms: i64) TTLCache {
        return TTLCache{
            .map = std.StringHashMap(CacheEntry).init(allocator),
            .mutex = std.Thread.Mutex{},
            .allocator = allocator,
            .ttl_ms = ttl_ms,
            .max_capacity = 10_000,
            .set_count = 0,
        };
    }

    pub fn deinit(self: *TTLCache) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.value);
        }
        self.map.deinit();
    }

    pub fn get(self: *TTLCache, key: []const u8) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const entry = self.map.get(key) orelse return null;
        const now = std.time.milliTimestamp();
        if (now > entry.expires_at) {
            // Lazy eviction
            _ = self.map.remove(key);
            self.allocator.free(entry.value);
            return null;
        }
        return entry.value;
    }

    pub fn set(self: *TTLCache, key: []const u8, value: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Periodic sweep every 100 sets
        self.set_count += 1;
        if (self.set_count % 100 == 0) {
            self.sweepLocked();
        }

        // Evict oldest if at capacity
        if (self.map.count() >= self.max_capacity) {
            // Find and remove oldest entry
            var oldest_key: ?[]const u8 = null;
            var oldest_time: i64 = std.math.maxInt(i64);
            var it = self.map.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.expires_at < oldest_time) {
                    oldest_time = entry.value_ptr.expires_at;
                    oldest_key = entry.key_ptr.*;
                }
            }
            if (oldest_key) |k| {
                if (self.map.fetchRemove(k)) |kv| {
                    self.allocator.free(kv.key);
                    self.allocator.free(kv.value.value);
                }
            }
        }

        const key_owned = try self.allocator.dupe(u8, key);
        const val_owned = try self.allocator.dupe(u8, value);
        const now = std.time.milliTimestamp();

        // Remove old entry if exists
        if (self.map.get(key_owned)) |old| {
            self.allocator.free(old.value);
        }
        _ = self.map.remove(key_owned);
        self.map.put(key_owned, CacheEntry{ .value = val_owned, .expires_at = now + self.ttl_ms }) catch {
            self.allocator.free(key_owned);
            self.allocator.free(val_owned);
            return;
        };
    }

    fn sweepLocked(self: *TTLCache) void {
        const now = std.time.milliTimestamp();
        var keys_to_remove = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (keys_to_remove.items) |k| self.allocator.free(k);
            keys_to_remove.deinit();
        }

        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (now > entry.value_ptr.expires_at) {
                keys_to_remove.append(entry.key_ptr.*) catch {};
            }
        }

        for (keys_to_remove.items) |k| {
            if (self.map.fetchRemove(k)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value.value);
            }
        }
    }
};

// ============================================================
// CIRCUIT BREAKER
// ============================================================

pub const CircuitState = enum {
    Closed,
    Open,
    HalfOpen,
};

pub const CircuitBreaker = struct {
    state: CircuitState,
    failures: u32,
    max_fails: u32,
    timeout_ms: u64,
    opened_at: i64,
    name: []const u8,
    mutex: std.Thread.Mutex,

    pub fn init(name: []const u8, max_fails: u32, timeout_ms: u64) CircuitBreaker {
        return CircuitBreaker{
            .state = .Closed,
            .failures = 0,
            .max_fails = max_fails,
            .timeout_ms = timeout_ms,
            .opened_at = 0,
            .name = name,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn execute(self: *CircuitBreaker, operation: *const fn () anyerror![]const u8) anyerror![]const u8 {
        const should_try = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            switch (self.state) {
                .Closed => break :blk true,
                .HalfOpen => break :blk true,
                .Open => {
                    const now = std.time.milliTimestamp();
                    if (now - self.opened_at >= @as(i64, @intCast(self.timeout_ms))) {
                        self.state = .HalfOpen;
                        std.log.info("circuit breaker {s} HALF-OPEN", .{self.name});
                        break :blk true;
                    } else {
                        break :blk false;
                    }
                },
            }
        };

        if (!should_try) {
            return error.CircuitOpen;
        }

        const result = operation() catch |err| {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.failures += 1;
            if (self.failures >= self.max_fails) {
                self.state = .Open;
                self.opened_at = std.time.milliTimestamp();
                std.log.warn("circuit breaker {s} OPEN after {d} failures", .{ self.name, self.failures });
            }
            return err;
        };

        self.mutex.lock();
        defer self.mutex.unlock();
        self.failures = 0;
        if (self.state == .HalfOpen) {
            std.log.info("circuit breaker {s} CLOSED (recovered)", .{self.name});
        }
        self.state = .Closed;
        return result;
    }
};

// ============================================================
// HTTP CLIENT (with retry)
// ============================================================

pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    timeout_ms: u64,
    retry_attempts: u32,
    retry_min_delay_ms: u64,
    retry_max_delay_ms: u64,

    pub fn init(allocator: std.mem.Allocator, timeout_ms: u64, retry_attempts: u32, retry_min_delay_ms: u64, retry_max_delay_ms: u64) HttpClient {
        return HttpClient{
            .allocator = allocator,
            .timeout_ms = timeout_ms,
            .retry_attempts = retry_attempts,
            .retry_min_delay_ms = retry_min_delay_ms,
            .retry_max_delay_ms = retry_max_delay_ms,
        };
    }

    pub fn fetchText(self: *HttpClient, url: []const u8) ![]const u8 {
        var last_err: anyerror = error.RequestFailed;

        for (0..self.retry_attempts) |attempt| {
            const result = self.fetchOnce(url);
            if (result) |body| {
                return body;
            } else |err| {
                last_err = err;
                if (attempt < self.retry_attempts - 1) {
                    const delay_ms = self.retry_min_delay_ms +
                        @mod(std.crypto.random.int(u64), self.retry_max_delay_ms - self.retry_min_delay_ms + 1);
                    std.time.sleep(delay_ms * std.time.ns_per_ms);
                }
            }
        }

        return last_err;
    }

    fn fetchOnce(self: *HttpClient, url: []const u8) ![]const u8 {
        const uri = try std.Uri.parse(url);

        // Use std.http.Client — Zig 0.14 API
        var client: std.http.Client = .{ .allocator = self.allocator };
        defer client.deinit();

        // Set redirect limit
        client.redirect_maximum = 10;

        var headers = std.http.Headers.init(self.allocator);
        defer headers.deinit();
        try headers.append("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");
        try headers.append("Accept-Language", "en-US,en;q=0.9,uk;q=0.8,ru;q=0.7");
        try headers.append("Accept", "text/html,application/json;q=0.9,*/*;q=0.8");

        var req = try client.request(.GET, uri, headers, .{});
        defer req.deinit();

        // Set timeout
        req.deadline = std.time.nanoTimestamp() + self.timeout_ms * std.time.ns_per_ms;

        try req.send(.{});
        try req.wait();

        if (req.response.status != .ok and req.response.status != .found and req.response.status != .redirect) {
            return error.HttpStatus;
        }

        const body = try req.reader().readAllAlloc(self.allocator, 1024 * 1024); // 1MB max
        return body;
    }
};

test "TTLCache basic" {
    var cache = TTLCache.init(std.testing.allocator, 60_000);
    defer cache.deinit();

    try cache.set("key1", "value1");
    try std.testing.expectEqualStrings("value1", cache.get("key1").?);
    try std.testing.expect(cache.get("nonexistent") == null);
}

test "TTLCache expiry" {
    var cache = TTLCache.init(std.testing.allocator, 1);
    defer cache.deinit();

    try cache.set("key2", "value2");
    std.time.sleep(2 * std.time.ns_per_ms);
    try std.testing.expect(cache.get("key2") == null);
}

test "CircuitBreaker basic" {
    var cb = CircuitBreaker.init("test", 3, 50);

    // Initial state is Closed
    try std.testing.expectEqual(CircuitState.Closed, cb.state);

    // 3 failures -> Open
    for (0..3) |_| {
        const r = cb.execute(struct {
            fn op() anyerror![]const u8 {
                return error.Fail;
            }
        }.op);
        try std.testing.expect(r == error.Fail);
    }
    try std.testing.expectEqual(CircuitState.Open, cb.state);

    // Open rejects immediately
    const r = cb.execute(struct {
        fn op() anyerror![]const u8 {
            return "ok";
        }
    }.op);
    try std.testing.expect(r == error.CircuitOpen);

    // Wait for timeout
    std.time.sleep(60 * std.time.ns_per_ms);
    try std.testing.expectEqual(CircuitState.HalfOpen, cb.state);

    // HalfOpen allows probe; success -> Closed
    const r2 = cb.execute(struct {
        fn op() anyerror![]const u8 {
            return "ok";
        }
    }.op);
    try std.testing.expect(r2 != error.CircuitOpen);
    try std.testing.expectEqual(CircuitState.Closed, cb.state);
}

test "CircuitBreaker success resets failures" {
    var cb = CircuitBreaker.init("reset-test", 3, 50);

    // 2 failures
    for (0..2) |_| {
        _ = cb.execute(struct {
            fn op() anyerror![]const u8 {
                return error.Fail;
            }
        }.op);
    }
    try std.testing.expectEqual(@as(u32, 2), cb.failures);

    // Success resets counter
    const r = cb.execute(struct {
        fn op() anyerror![]const u8 {
            return "ok";
        }
    }.op);
    try std.testing.expectEqualStrings("ok", r catch unreachable);
    try std.testing.expectEqual(@as(u32, 0), cb.failures);
    try std.testing.expectEqual(CircuitState.Closed, cb.state);
}

test "TTLCache set overwrite" {
    var cache = TTLCache.init(std.testing.allocator, 60_000);
    defer cache.deinit();

    try cache.set("key", "value1");
    try cache.set("key", "value2");
    try std.testing.expectEqualStrings("value2", cache.get("key").?);
}

test "TTLCache capacity eviction" {
    var cache = TTLCache.init(std.testing.allocator, 60_000);
    cache.max_capacity = 3;
    defer cache.deinit();

    try cache.set("k1", "v1");
    try cache.set("k2", "v2");
    try cache.set("k3", "v3");
    // Should still fit 3
    try std.testing.expect(cache.get("k1") != null);
    try std.testing.expect(cache.get("k2") != null);
    try std.testing.expect(cache.get("k3") != null);

    // k4 should evict one
    try cache.set("k4", "v4");
    try std.testing.expect(cache.get("k4") != null);
    // At most 3 entries remain
    var count: usize = 0;
    var it = cache.map.iterator();
    while (it.next()) |_| count += 1;
    try std.testing.expect(count <= 3);
}

test "HttpClient init" {
    const client = HttpClient.init(std.testing.allocator, 5000, 2, 100, 300);
    try std.testing.expectEqual(@as(u64, 5000), client.timeout_ms);
    try std.testing.expectEqual(@as(u32, 2), client.retry_attempts);
    try std.testing.expectEqual(@as(u64, 100), client.retry_min_delay_ms);
    try std.testing.expectEqual(@as(u64, 300), client.retry_max_delay_ms);
}
