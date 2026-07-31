const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

// ============================================================
// CONFIG
// ============================================================

pub const Config = struct {
    telegram_token: []const u8,
    max_concurrent_fetches: usize = 8,
    max_concurrent_messages: usize = 32,
    request_timeout_ms: u64 = 12_000,
    retry_attempts: u32 = 2,
    retry_min_delay_ms: u64 = 150,
    retry_max_delay_ms: u64 = 350,
    cache_ttl_ms: i64 = 24 * 3600 * 1000,
    negative_cache_ttl_ms: i64 = 5 * 60 * 1000,
    fuzzy_match_threshold: f64 = 0.7,
    circuit_breaker_max_fails: u32 = 5,
    circuit_breaker_timeout_ms: u64 = 60_000,
    text_mirror_url: []const u8 = "https://r.jina.ai/",
    health_port: u16 = 8080,

    pub fn fromEnv(allocator: Allocator) !Config {
        const token = std.process.getEnvVarOwned(allocator, "TELEGRAM_BOT_TOKEN") catch |err| {
            if (err == error.EnvironmentVariableNotFound) {
                return error.MissingToken;
            }
            return err;
        };
        if (token.len == 0) return error.EmptyToken;

        var cfg = Config{ .telegram_token = token };
        cfg.cache_ttl_ms = @as(i64, @intCast(envParseInt("CACHE_TTL_SEC", 24 * 3600) * 1000));
        cfg.negative_cache_ttl_ms = @as(i64, @intCast(envParseInt("NEGATIVE_CACHE_TTL_SEC", 5 * 60) * 1000));
        cfg.max_concurrent_fetches = envParseInt("MAX_CONCURRENT_FETCHES", 8);
        cfg.max_concurrent_messages = envParseInt("MAX_CONCURRENT_MESSAGES", 32);
        cfg.request_timeout_ms = envParseInt("REQUEST_TIMEOUT_SEC", 12) * 1000;
        cfg.retry_attempts = @intCast(envParseInt("RETRY_ATTEMPTS", 2));
        cfg.retry_min_delay_ms = envParseInt("RETRY_MIN_DELAY_MS", 150);
        cfg.retry_max_delay_ms = envParseInt("RETRY_MAX_DELAY_MS", 350);
        cfg.circuit_breaker_max_fails = @intCast(envParseInt("CIRCUIT_BREAKER_MAX_FAILS", 5));
        cfg.circuit_breaker_timeout_ms = envParseInt("CIRCUIT_BREAKER_TIMEOUT_SEC", 60) * 1000;
        cfg.fuzzy_match_threshold = envParseFloat("FUZZY_MATCH_THRESHOLD", 0.7);
        cfg.health_port = @intCast(envParseInt("HEALTH_PORT", 8080));
        if (std.process.getEnvVarOwned(allocator, "TEXT_MIRROR_URL")) |url| {
            cfg.text_mirror_url = url;
        } else |_| {}
        return cfg;
    }
};

fn envParseInt(key: []const u8, default: u64) u64 {
    const v = std.process.getEnvVarOwned(std.heap.page_allocator, key) catch return default;
    defer std.heap.page_allocator.free(v);
    return std.fmt.parseInt(u64, std.mem.trim(u8, v, " \t\r\n"), 10) catch default;
}

fn envParseFloat(key: []const u8, default: f64) f64 {
    const v = std.process.getEnvVarOwned(std.heap.page_allocator, key) catch return default;
    defer std.heap.page_allocator.free(v);
    return std.fmt.parseFloat(f64, std.mem.trim(u8, v, " \t\r\n")) catch default;
}

// ============================================================
// DATA TYPES
// ============================================================

pub const SongInfo = struct {
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    platform: []const u8,
    original_url: []const u8,
};

pub const MusicLinks = struct {
    spotify: []const u8 = "",
    youtube_music: []const u8 = "",
    apple_music: []const u8 = "",
};

// ============================================================
// REGEX-LIKE PATTERN MATCHING (simple string search)
// ============================================================

/// Extract the first URL from text, stripping trailing punctuation
pub fn firstUrl(text: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, text, "https://") orelse
        std.mem.indexOf(u8, text, "http://") orelse return null;
    // Find whitespace or end after start
    var end = start;
    while (end < text.len and !std.ascii.isWhitespace(text[end])) : (end += 1) {}
    const url = text[start..end];
    // Strip trailing punctuation
    const stripped = std.mem.trimRight(u8, url, ".,);!?]}>\"'");
    return stripped;
}

/// Parse URL to get hostname (lowercase, simplified)
pub fn extractHost(url_str: []const u8) ?[]const u8 {
    const scheme_end = std.mem.indexOf(u8, url_str, "://") orelse return null;
    const after_scheme = url_str[scheme_end + 3 ..];
    const host_end = std.mem.indexOfAny(u8, after_scheme, "/:?") orelse after_scheme.len;
    return after_scheme[0..host_end];
}

/// Check if text contains the substring (case-insensitive)
pub fn containsCi(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    const h_lower = std.ascii.lowerString(haystack, std.heap.page_allocator);
    defer std.heap.page_allocator.free(h_lower);
    const n_lower = std.ascii.lowerString(needle, std.heap.page_allocator);
    defer std.heap.page_allocator.free(n_lower);
    return std.mem.indexOf(u8, h_lower, n_lower) != null;
}

/// Convert to lowercase string (caller owns memory)
pub fn toLower(allocator: Allocator, s: []const u8) []u8 {
    const result = allocator.alloc(u8, s.len) catch return &.{};
    for (result, 0..) |*c, i| {
        c.* = std.ascii.toLower(s[i]);
    }
    return result;
}

/// Normalize string for fuzzy matching: lowercase, strip paren blocks, replace punctuation
pub fn normalizeForMatch(allocator: Allocator, s: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    // Lowercase
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '(' or c == '[') {
            // Skip paren block
            const close = if (c == '(')
                std.mem.indexOfScalar(u8, s[i..], ')')
            else
                std.mem.indexOfScalar(u8, s[i..], ']');
            if (close) |pos| {
                i += pos;
            }
            continue;
        }
        // Replace various punctuation with space
        switch (c) {
            '-', '\u{2014}', '\u{2013}', '\u{00B7}', '.', ',', '!', '?', '/', '\'', '"' => {
                try result.append(' ');
            },
            '&' => {
                try result.appendSlice(" and ");
            },
            else => {
                try result.append(std.ascii.toLower(c));
            },
        }
    }
    // Collapse whitespace
    var out = std.ArrayList(u8).init(allocator);
    var in_space = false;
    for (result.items) |c| {
        if (std.ascii.isWhitespace(c)) {
            if (!in_space) {
                try out.append(' ');
                in_space = true;
            }
        } else {
            try out.append(c);
            in_space = false;
        }
    }
    return out.items;
}

/// Normalize query: strip parens, feat, platform names, etc.
pub fn normalizeQuery(allocator: Allocator, artist: []const u8, title: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    const normalized_artist = try normalizeForMatch(allocator, artist);
    defer allocator.free(normalized_artist);
    const normalized_title = try normalizeForMatch(allocator, title);
    defer allocator.free(normalized_title);

    // Rejoin with space
    if (normalized_artist.len > 0) {
        try result.appendSlice(normalized_artist);
        try result.append(' ');
    }
    try result.appendSlice(normalized_title);
    return result.items;
}

/// Escape text for Telegram MarkdownV2
pub fn md2(allocator: Allocator, s: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    for (s) |c| {
        switch (c) {
            '_', '*', '[', ']', '(', ')', '~', '`',
            '>', '#', '+', '-', '=', '|', '{', '}',
            '.', '!' => {
                try result.appendSlice("\\\\");
                try result.append(c);
            },
            else => try result.append(c),
        }
    }
    return result.items;
}

/// Clean YouTube-specific info from title and artist
pub fn cleanYoutubeInfo(allocator: Allocator, title: []const u8, artist: []const u8) !struct { title: []u8, artist: []u8 } {
    var artist_clean = std.ArrayList(u8).init(allocator);
    // Strip " - Topic" suffix
    if (std.mem.endsWith(u8, artist, " - Topic")) {
        try artist_clean.appendSlice(artist[0 .. artist.len - " - Topic".len]);
    } else if (blk: {
        // Check if artist (lowercased) ends with "vevo"
        var lower_artist: [128]u8 = undefined;
        const n = @min(artist.len, lower_artist.len);
        @memcpy(lower_artist[0..n], artist[0..n]);
        const lowered = std.ascii.lowerString(lower_artist[0..n], artist[0..n]);
        break :blk std.mem.endsWith(u8, lowered, "vevo");
    }) {
        // skip VEVO
        try artist_clean.appendSlice(artist[0 .. artist.len - 4]);
    } else if (std.mem.endsWith(u8, artist, "Official")) {
        try artist_clean.appendSlice(artist[0 .. artist.len - "Official".len]);
    } else {
        try artist_clean.appendSlice(artist);
    }

    // Strip title prefix "ArtistName - "
    var title_clean = std.ArrayList(u8).init(allocator);
    const prefix = try std.fmt.allocPrint(allocator, "{s} - ", .{std.mem.trim(u8, artist_clean.items, " ") });
    defer allocator.free(prefix);
    if (std.ascii.startsWithIgnoreCase(title, prefix)) {
        try title_clean.appendSlice(title[prefix.len..]);
    } else {
        try title_clean.appendSlice(title);
    }

    return .{
        .title = try title_clean.toOwnedSlice(),
        .artist = try artist_clean.toOwnedSlice(),
    };
}

/// Check if a string looks like an album name
pub fn isAlbumish(s: []const u8) bool {
    if (s.len == 0) return false;
    const l = std.ascii.lowerString(s, std.heap.page_allocator);
    defer std.heap.page_allocator.free(l);
    const hints = [_][]const u8{ "original soundtrack", "soundtrack", "ost", "score", "music from", "season ", " vol.", " volume ", ":" };
    for (hints) |h| {
        if (std.mem.indexOf(u8, l, h) != null) return true;
    }
    return false;
}

/// Check if a string looks like an artist list (has commas, &, feat, etc.)
pub fn looksLikeArtistList(s: []const u8) bool {
    if (s.len == 0) return false;
    const l = std.ascii.lowerString(s, std.heap.page_allocator);
    defer std.heap.page_allocator.free(l);
    const has_sep = std.mem.indexOfAny(u8, l, ",&") != null or
        std.mem.indexOf(u8, l, " and ") != null or
        std.mem.indexOf(u8, l, " feat") != null or
        std.mem.indexOf(u8, l, " featuring ") != null;
    if (!has_sep) return false;
    return std.mem.indexOfScalar(u8, l, ':') == null and
        std.mem.indexOfScalar(u8, l, '-') == null;
}

/// URL-encode a string
pub fn urlEncode(allocator: Allocator, s: []const u8) ![]u8 {
    return std.mem.replace(u8, s, " ", "%20", allocator);
    // For a proper encoding, would use std.unicode.utf8Encode etc.
    // But for search queries, just encoding spaces and simple chars works
}

/// Extract text between two markers (simple, no regex)
pub fn extractBetween(haystack: []const u8, start_marker: []const u8, end_marker: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, haystack, start_marker) orelse return null;
    const content_start = start + start_marker.len;
    const end = std.mem.indexOf(u8, haystack[content_start..], end_marker) orelse return null;
    return haystack[content_start .. content_start + end];
}

/// Extract content attribute from a meta tag by property value
pub fn extractMetaContent(haystack: []const u8, property: []const u8) ?[]const u8 {
    const search = std.fmt.allocPrint(std.heap.page_allocator, "property=\"{s}\"", .{property}) catch return null;
    defer std.heap.page_allocator.free(search);
    const start = std.mem.indexOf(u8, haystack, search) orelse return null;
    const after_prop = haystack[start..];
    // Find content="..."
    const content_marker = "content=\"";
    const content_start = std.mem.indexOf(u8, after_prop, content_marker) orelse return null;
    const value_start = content_start + content_marker.len;
    const end = std.mem.indexOfScalar(u8, after_prop[value_start..], '"') orelse return null;
    return after_prop[value_start .. value_start + end];
}

/// Free if allocated (safe no-op for empty strings)
pub fn freeIfAllocated(allocator: Allocator, s: []const u8) void {
    if (s.len > 0) allocator.free(s);
}

/// Simple Levenshtein distance
pub fn levenshtein(a: []const u8, b: []const u8) usize {
    const na = a.len;
    const nb = b.len;
    if (na == 0) return nb;
    if (nb == 0) return na;
    var prev: []usize = std.heap.page_allocator.alloc(usize, nb + 1) catch return nb;
    defer std.heap.page_allocator.free(prev);
    var curr: []usize = std.heap.page_allocator.alloc(usize, nb + 1) catch return nb;
    defer std.heap.page_allocator.free(curr);
    for (0..nb + 1) |j| prev[j] = j;
    for (0..na) |i| {
        curr[0] = i + 1;
        for (0..nb) |j| {
            const cost: usize = if (a[i] == b[j]) 0 else 1;
            curr[j + 1] = @min(@min(curr[j] + 1, prev[j + 1] + 1), prev[j] + cost);
        }
        std.mem.swap([]usize, &prev, &curr);
    }
    return prev[nb];
}

/// Calculate similarity score (0.0 to 1.0)
pub fn calculateSimilarity(s1: []const u8, s2: []const u8) f64 {
    const n1 = normalizeForMatch(std.heap.page_allocator, s1) catch return 0.0;
    defer std.heap.page_allocator.free(n1);
    const n2 = normalizeForMatch(std.heap.page_allocator, s2) catch return 0.0;
    defer std.heap.page_allocator.free(n2);
    if (n1.len == 0 and n2.len == 0) return 1.0;
    if (n1.len == 0 or n2.len == 0) return 0.0;
    const dist = levenshtein(n1, n2);
    const max_len = @max(n1.len, n2.len);
    return 1.0 - @as(f64, @floatFromInt(dist)) / @as(f64, @floatFromInt(max_len));
}

/// Split "Title - Artist" format using dash variants
pub fn splitByDash(s: []const u8) ?struct { left: []const u8, right: []const u8 } {
    // Try em dash, en dash, regular dash with spaces, " by "
    if (std.mem.indexOf(u8, s, " by ")) |pos| {
        return .{ .left = std.mem.trim(u8, s[0..pos], " "), .right = std.mem.trim(u8, s[pos + 4 ..], " ") };
    }
    const dashes = [_][]const u8{ "\u{2014}", "\u{2013}", " - ", " – " };
    for (dashes) |dash| {
        if (std.mem.indexOf(u8, s, dash)) |pos| {
            return .{ .left = std.mem.trim(u8, s[0..pos], " "), .right = std.mem.trim(u8, s[pos + dash.len ..], " ") };
        }
    }
    return null;
}

/// Extract title and artist from og:title (simplified version)
pub fn splitFromOgTitle(og_title: []const u8, og_desc: []const u8) struct { title: []const u8, artist: []const u8 } {
    _ = og_desc; // simplified — we skip the hint-based reversal for now
    // Strip " | Spotify" suffix
    const t = if (std.mem.endsWith(u8, og_title, " | Spotify"))
        og_title[0 .. og_title.len - " | Spotify".len]
    else
        og_title;
    const stripped = std.mem.trim(u8, t, " ");

    // Try "Title by Artist"
    if (std.mem.indexOf(u8, stripped, " by ")) |pos| {
        return .{ .title = std.mem.trim(u8, stripped[0..pos], " "), .artist = std.mem.trim(u8, stripped[pos + 4 ..], " ") };
    }
    // Try dash split
    if (splitByDash(stripped)) |parts| {
        return .{ .title = parts.left, .artist = parts.right };
    }
    return .{ .title = stripped, .artist = "" };
}

// ============================================================
// TESTS
// ============================================================

const testing = std.testing;

test "firstUrl basic" {
    try testing.expectEqualStrings("https://open.spotify.com/track/123", firstUrl("Check this https://open.spotify.com/track/123").?);
    try testing.expect(firstUrl("no url here") == null);
}

test "extractHost" {
    try testing.expectEqualStrings("open.spotify.com", extractHost("https://open.spotify.com/track/abc").?);
    try testing.expectEqualStrings("youtu.be", extractHost("https://youtu.be/dQw4w9WgXcQ").?);
    try testing.expectEqualStrings("music.youtube.com", extractHost("https://music.youtube.com/watch?v=abc").?);
}

test "normalizeForMatch" {
    const alloc = testing.allocator;
    {
        const n = try normalizeForMatch(alloc, "Bad Guy");
        defer alloc.free(n);
        try testing.expectEqualStrings("bad guy", n);
    }
    {
        const n = try normalizeForMatch(alloc, "Love-Story");
        defer alloc.free(n);
        try testing.expectEqualStrings("love story", n);
    }
    {
        const n = try normalizeForMatch(alloc, "Song (Remix)");
        defer alloc.free(n);
        try testing.expectEqualStrings("song", n);
    }
}

test "md2 escaping" {
    const alloc = testing.allocator;
    const e = try md2(alloc, "Hello_World");
    defer alloc.free(e);
    try testing.expectEqualStrings("Hello\\\\_World", e);
}

test "levenshtein" {
    try testing.expectEqual(@as(usize, 0), levenshtein("hello", "hello"));
    try testing.expectEqual(@as(usize, 1), levenshtein("hello", "hallo"));
    try testing.expectEqual(@as(usize, 3), levenshtein("kitten", "sitting"));
}

test "calculateSimilarity" {
    try testing.expect(calculateSimilarity("bad guy", "bad guy") > 0.99);
    try testing.expect(calculateSimilarity("Bad Guy", "bad guy") > 0.99);
    try testing.expect(calculateSimilarity("hello", "world") < 0.3);
}

test "isAlbumish" {
    try testing.expect(isAlbumish("Original Soundtrack"));
    try testing.expect(isAlbumish("Game OST"));
    try testing.expect(!isAlbumish("Bad Guy"));
}

test "looksLikeArtistList" {
    try testing.expect(looksLikeArtistList("Ed Sheeran, Justin Bieber"));
    try testing.expect(looksLikeArtistList("Simon & Garfunkel"));
    try testing.expect(!looksLikeArtistList("Billie Eilish"));
}

test "extractBetween" {
    const html = "<script id=\"__NEXT_DATA__\" type=\"application/json\">{\"key\":\"value\"}</script>";
    const extracted = extractBetween(html, ">{\"", "\"}</script>");
    try testing.expect(extracted != null);
    try testing.expectEqualStrings("key\":\"value", extracted.?);
}

test "splitByDash with by" {
    const r = splitByDash("Blinding Lights by The Weeknd");
    try testing.expect(r != null);
    try testing.expectEqualStrings("Blinding Lights", r.?.left);
    try testing.expectEqualStrings("The Weeknd", r.?.right);
}

test "splitByDash with em dash" {
    const r = splitByDash("Blinding Lights \u{2014} The Weeknd");
    try testing.expect(r != null);
    try testing.expectEqualStrings("Blinding Lights", r.?.left);
    try testing.expectEqualStrings("The Weeknd", r.?.right);
}
