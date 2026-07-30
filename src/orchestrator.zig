const std = @import("std");
const util = @import("util.zig");
const infra = @import("infra.zig");
const platform_mod = @import("platform.zig");

const Allocator = std.mem.Allocator;

pub const Orchestrator = struct {
    http: infra.HttpClient,
    cache: *infra.TTLCache,
    breaker: *infra.CircuitBreaker,

    pub fn init(http: infra.HttpClient, cache: *infra.TTLCache, breaker: *infra.CircuitBreaker) Orchestrator {
        return Orchestrator{ .http = http, .cache = cache, .breaker = breaker };
    }

    /// Convert youtube.com URL to music.youtube.com
    fn toYoutubeMusicUrl(url_str: []const u8, allocator: Allocator) ![]u8 {
        if (std.mem.containsAtLeast(u8, url_str, 1, "music.youtube.com")) {
            return try allocator.dupe(u8, url_str);
        }
        if (std.mem.startsWith(u8, url_str, "https://youtu.be/") or
            std.mem.startsWith(u8, url_str, "http://youtu.be/"))
        {
            const after = if (std.mem.startsWith(u8, url_str, "https://youtu.be/"))
                url_str["https://youtu.be/".len..]
            else
                url_str["http://youtu.be/".len..];
            const id_end = std.mem.indexOfAny(u8, after, "?&") orelse after.len;
            const vid = after[0..id_end];
            return try std.fmt.allocPrint(allocator, "https://music.youtube.com/watch?v={s}", .{vid});
        }
        if (std.mem.indexOf(u8, url_str, "?v=")) |pos| {
            const after = url_str[pos + 3 ..];
            const vid_end = std.mem.indexOfScalar(u8, after, '&') orelse after.len;
            const vid = after[0..vid_end];
            return try std.fmt.allocPrint(allocator, "https://music.youtube.com/watch?v={s}", .{vid});
        }
        return try allocator.dupe(u8, url_str);
    }

    /// Extract song info from a URL in text
    pub fn extractSongInfo(self: *Orchestrator, allocator: Allocator, text: []const u8) !?util.SongInfo {
        const text_trimmed = std.mem.trim(u8, text, " \t\r\n");
        const url_str = util.firstUrl(text_trimmed) orelse return null;
        const host = util.extractHost(url_str) orelse return null;

        if (std.mem.endsWith(u8, host, ".spotify.link") or
            std.mem.endsWith(u8, host, ".spotify.app.link") or
            std.mem.eql(u8, host, "spotify.link") or
            std.mem.eql(u8, host, "spotify.app.link"))
        {
            const resolved = try platform_mod.resolveSpotifyShortLink(self.http, url_str);
            defer util.freeIfAllocated(allocator, resolved);
            return try platform_mod.extractSpotifyInfo(self.http, self.cache, self.breaker, allocator, resolved);
        }
        if (std.mem.eql(u8, host, "open.spotify.com")) {
            return try platform_mod.extractSpotifyInfo(self.http, self.cache, self.breaker, allocator, url_str);
        }
        if (std.mem.eql(u8, host, "music.youtube.com")) {
            return try platform_mod.extractYoutubeInfo(self.http, self.cache, allocator, url_str);
        }
        if (std.mem.eql(u8, host, "youtube.com") or
            std.mem.eql(u8, host, "www.youtube.com") or
            std.mem.eql(u8, host, "m.youtube.com") or
            std.mem.eql(u8, host, "youtu.be"))
        {
            const music_url = try self.toYoutubeMusicUrl(url_str, allocator);
            defer allocator.free(music_url);
            return try platform_mod.extractYoutubeInfo(self.http, self.cache, allocator, music_url);
        }
        if (std.mem.eql(u8, host, "music.apple.com") or
            std.mem.eql(u8, host, "itunes.apple.com"))
        {
            return try platform_mod.extractAppleMusicInfo(self.http, self.cache, allocator, url_str);
        }
        return null;
    }

    /// Search for song on all platforms concurrently
    pub fn findOnAllPlatforms(self: *Orchestrator, allocator: Allocator, info: *const util.SongInfo) !util.MusicLinks {
        var links = util.MusicLinks{};

        // Synchronous search for each platform
        if (!std.mem.eql(u8, info.platform, "Spotify")) {
            links.spotify = platform_mod.searchSpotify(self.http, self.cache, allocator, info) catch "";
        } else {
            links.spotify = try allocator.dupe(u8, info.original_url);
        }

        if (!std.mem.eql(u8, info.platform, "YouTube Music") and
            !std.mem.eql(u8, info.platform, "YouTube"))
        {
            links.youtube_music = platform_mod.searchYoutube(self.http, self.cache, allocator, info) catch "";
        } else {
            links.youtube_music = try allocator.dupe(u8, info.original_url);
        }

        if (!std.mem.eql(u8, info.platform, "Apple Music")) {
            links.apple_music = platform_mod.searchAppleMusic(self.http, self.cache, allocator, info) catch "";
        } else {
            links.apple_music = try allocator.dupe(u8, info.original_url);
        }

        return links;
    }
};

test "toYoutubeMusicUrl" {
    const alloc = std.testing.allocator;
    {
        // Standard youtube.com URL
        const got = try Orchestrator.toYoutubeMusicUrl("https://www.youtube.com/watch?v=dQw4w9WgXcQ", alloc);
        defer alloc.free(got);
        try std.testing.expectEqualStrings("https://music.youtube.com/watch?v=dQw4w9WgXcQ", got);
    }
    {
        // Short youtu.be URL
        const got = try Orchestrator.toYoutubeMusicUrl("https://youtu.be/dQw4w9WgXcQ", alloc);
        defer alloc.free(got);
        try std.testing.expectEqualStrings("https://music.youtube.com/watch?v=dQw4w9WgXcQ", got);
    }
    {
        // Already a music.youtube.com URL — pass through unchanged
        const got = try Orchestrator.toYoutubeMusicUrl("https://music.youtube.com/watch?v=dQw4w9WgXcQ", alloc);
        defer alloc.free(got);
        try std.testing.expectEqualStrings("https://music.youtube.com/watch?v=dQw4w9WgXcQ", got);
    }
    {
        // youtu.be with query params (si=, t=)
        const got = try Orchestrator.toYoutubeMusicUrl("https://youtu.be/dQw4w9WgXcQ?si=abc123&t=30", alloc);
        defer alloc.free(got);
        try std.testing.expectEqualStrings("https://music.youtube.com/watch?v=dQw4w9WgXcQ", got);
    }
    {
        // URL with extra query params after ?v=
        const got = try Orchestrator.toYoutubeMusicUrl("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLabc&index=1", alloc);
        defer alloc.free(got);
        try std.testing.expectEqualStrings("https://music.youtube.com/watch?v=dQw4w9WgXcQ", got);
    }
    {
        // Non-YouTube URL — not converted, passed through
        const got = try Orchestrator.toYoutubeMusicUrl("https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT", alloc);
        defer alloc.free(got);
        try std.testing.expectEqualStrings("https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT", got);
    }
    {
        // m.youtube.com URL
        const got = try Orchestrator.toYoutubeMusicUrl("https://m.youtube.com/watch?v=dQw4w9WgXcQ", alloc);
        defer alloc.free(got);
        try std.testing.expectEqualStrings("https://music.youtube.com/watch?v=dQw4w9WgXcQ", got);
    }
    {
        // http (not https) youtu.be
        const got = try Orchestrator.toYoutubeMusicUrl("http://youtu.be/dQw4w9WgXcQ", alloc);
        defer alloc.free(got);
        try std.testing.expectEqualStrings("https://music.youtube.com/watch?v=dQw4w9WgXcQ", got);
    }
    {
        // Short URL with & instead of ? for first param (edge case in indexOfAny)
        const got = try Orchestrator.toYoutubeMusicUrl("https://youtu.be/dQw4w9WgXcQ&si=abc", alloc);
        defer alloc.free(got);
        try std.testing.expectEqualStrings("https://music.youtube.com/watch?v=dQw4w9WgXcQ", got);
    }
}

test "extractSongInfo — no URL returns null" {
    const alloc = std.testing.allocator;
    var cache = infra.TTLCache.init(alloc, 60_000);
    defer cache.deinit();
    var breaker = infra.CircuitBreaker.init("test", 5, 60_000);
    const http = infra.HttpClient.init(alloc, 1000, 0, 0, 0);
    var orch = Orchestrator.init(http, &cache, &breaker);

    try std.testing.expect((try orch.extractSongInfo(alloc, "just some text")) == null);
    try std.testing.expect((try orch.extractSongInfo(alloc, "")) == null);
}

test "extractSongInfo — unknown host returns null" {
    const alloc = std.testing.allocator;
    var cache = infra.TTLCache.init(alloc, 60_000);
    defer cache.deinit();
    var breaker = infra.CircuitBreaker.init("test", 5, 60_000);
    const http = infra.HttpClient.init(alloc, 1000, 0, 0, 0);
    var orch = Orchestrator.init(http, &cache, &breaker);

    try std.testing.expect((try orch.extractSongInfo(alloc, "https://example.com/foo")) == null);
    try std.testing.expect((try orch.extractSongInfo(alloc, "https://some-unknown-site.org/path")) == null);
}

test "extractSongInfo — spotify.link short URL routes to spotify branch" {
    const alloc = std.testing.allocator;
    var cache = infra.TTLCache.init(alloc, 60_000);
    defer cache.deinit();
    var breaker = infra.CircuitBreaker.init("test", 5, 60_000);
    const http = infra.HttpClient.init(alloc, 1000, 0, 0, 0);
    var orch = Orchestrator.init(http, &cache, &breaker);

    const result = orch.extractSongInfo(alloc, "https://spotify.link/abc123");
    try std.testing.expect(result != null);
    try std.testing.expectError(error.ConnectionRefused, result);
}

test "extractSongInfo — open.spotify.com routes to spotify branch" {
    const alloc = std.testing.allocator;
    var cache = infra.TTLCache.init(alloc, 60_000);
    defer cache.deinit();
    var breaker = infra.CircuitBreaker.init("test", 5, 60_000);
    const http = infra.HttpClient.init(alloc, 1000, 0, 0, 0);
    var orch = Orchestrator.init(http, &cache, &breaker);

    const result = orch.extractSongInfo(alloc, "https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT");
    try std.testing.expect(result != null);
    try std.testing.expectError(error.ConnectionRefused, result);
}

test "extractSongInfo — music.youtube.com routes to youtube branch" {
    const alloc = std.testing.allocator;
    var cache = infra.TTLCache.init(alloc, 60_000);
    defer cache.deinit();
    var breaker = infra.CircuitBreaker.init("test", 5, 60_000);
    const http = infra.HttpClient.init(alloc, 1000, 0, 0, 0);
    var orch = Orchestrator.init(http, &cache, &breaker);

    const result = orch.extractSongInfo(alloc, "https://music.youtube.com/watch?v=dQw4w9WgXcQ");
    try std.testing.expect(result != null);
    try std.testing.expectError(error.ConnectionRefused, result);
}

test "extractSongInfo — www.youtube.com routes through toYoutubeMusicUrl then youtube branch" {
    const alloc = std.testing.allocator;
    var cache = infra.TTLCache.init(alloc, 60_000);
    defer cache.deinit();
    var breaker = infra.CircuitBreaker.init("test", 5, 60_000);
    const http = infra.HttpClient.init(alloc, 1000, 0, 0, 0);
    var orch = Orchestrator.init(http, &cache, &breaker);

    const result = orch.extractSongInfo(alloc, "https://www.youtube.com/watch?v=dQw4w9WgXcQ");
    try std.testing.expect(result != null);
    try std.testing.expectError(error.ConnectionRefused, result);
}

test "extractSongInfo — youtu.be routes through toYoutubeMusicUrl then youtube branch" {
    const alloc = std.testing.allocator;
    var cache = infra.TTLCache.init(alloc, 60_000);
    defer cache.deinit();
    var breaker = infra.CircuitBreaker.init("test", 5, 60_000);
    const http = infra.HttpClient.init(alloc, 1000, 0, 0, 0);
    var orch = Orchestrator.init(http, &cache, &breaker);

    const result = orch.extractSongInfo(alloc, "https://youtu.be/dQw4w9WgXcQ");
    try std.testing.expect(result != null);
    try std.testing.expectError(error.ConnectionRefused, result);
}

test "extractSongInfo — music.apple.com routes to apple music branch" {
    const alloc = std.testing.allocator;
    var cache = infra.TTLCache.init(alloc, 60_000);
    defer cache.deinit();
    var breaker = infra.CircuitBreaker.init("test", 5, 60_000);
    const http = infra.HttpClient.init(alloc, 1000, 0, 0, 0);
    var orch = Orchestrator.init(http, &cache, &breaker);

    const result = orch.extractSongInfo(alloc, "https://music.apple.com/us/album/song/123");
    try std.testing.expect(result != null);
    try std.testing.expectError(error.ConnectionRefused, result);
}

test "extractSongInfo — text with multiple URLs picks the first one" {
    const alloc = std.testing.allocator;
    var cache = infra.TTLCache.init(alloc, 60_000);
    defer cache.deinit();
    var breaker = infra.CircuitBreaker.init("test", 5, 60_000);
    const http = infra.HttpClient.init(alloc, 1000, 0, 0, 0);
    var orch = Orchestrator.init(http, &cache, &breaker);

    const result = orch.extractSongInfo(alloc, "https://first.unknown/foo and https://music.youtube.com/watch?v=abc");
    try std.testing.expect(result == null);
}

test "extractSongInfo — m.youtube.com routes through toYoutubeMusicUrl" {
    const alloc = std.testing.allocator;
    var cache = infra.TTLCache.init(alloc, 60_000);
    defer cache.deinit();
    var breaker = infra.CircuitBreaker.init("test", 5, 60_000);
    const http = infra.HttpClient.init(alloc, 1000, 0, 0, 0);
    var orch = Orchestrator.init(http, &cache, &breaker);

    const result = orch.extractSongInfo(alloc, "https://m.youtube.com/watch?v=dQw4w9WgXcQ");
    try std.testing.expect(result != null);
    try std.testing.expectError(error.ConnectionRefused, result);
}

test "extractSongInfo — www.youtube.com with playlist id" {
    const alloc = std.testing.allocator;
    var cache = infra.TTLCache.init(alloc, 60_000);
    defer cache.deinit();
    var breaker = infra.CircuitBreaker.init("test", 5, 60_000);
    const http = infra.HttpClient.init(alloc, 1000, 0, 0, 0);
    var orch = Orchestrator.init(http, &cache, &breaker);

    const result = orch.extractSongInfo(alloc, "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLabc&index=1");
    try std.testing.expect(result != null);
    try std.testing.expectError(error.ConnectionRefused, result);
}

test "extractSongInfo — itunes.apple.com routes to apple music branch" {
    const alloc = std.testing.allocator;
    var cache = infra.TTLCache.init(alloc, 60_000);
    defer cache.deinit();
    var breaker = infra.CircuitBreaker.init("test", 5, 60_000);
    const http = infra.HttpClient.init(alloc, 1000, 0, 0, 0);
    var orch = Orchestrator.init(http, &cache, &breaker);

    const result = orch.extractSongInfo(alloc, "https://itunes.apple.com/us/album/song/123");
    try std.testing.expect(result != null);
    try std.testing.expectError(error.ConnectionRefused, result);
}

test "extractSongInfo — text with trailing whitespace and newline" {
    const alloc = std.testing.allocator;
    var cache = infra.TTLCache.init(alloc, 60_000);
    defer cache.deinit();
    var breaker = infra.CircuitBreaker.init("test", 5, 60_000);
    const http = infra.HttpClient.init(alloc, 1000, 0, 0, 0);
    var orch = Orchestrator.init(http, &cache, &breaker);

    const result = orch.extractSongInfo(alloc, "  https://music.youtube.com/watch?v=dQw4w9WgXcQ  \n");
    try std.testing.expect(result != null);
    try std.testing.expectError(error.ConnectionRefused, result);
}

test "extractSongInfo — only http (not https) URL" {
    const alloc = std.testing.allocator;
    var cache = infra.TTLCache.init(alloc, 60_000);
    defer cache.deinit();
    var breaker = infra.CircuitBreaker.init("test", 5, 60_000);
    const http = infra.HttpClient.init(alloc, 1000, 0, 0, 0);
    var orch = Orchestrator.init(http, &cache, &breaker);

    const result = orch.extractSongInfo(alloc, "http://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT");
    try std.testing.expect(result != null);
    try std.testing.expectError(error.ConnectionRefused, result);
}

test "toYoutubeMusicUrl — empty string" {
    const alloc = std.testing.allocator;
    const got = try Orchestrator.toYoutubeMusicUrl("", alloc);
    defer alloc.free(got);
    try std.testing.expectEqualStrings("", got);
}

test "toYoutubeMusicUrl — youtu.be with timestamp param" {
    const alloc = std.testing.allocator;
    const got = try Orchestrator.toYoutubeMusicUrl("https://youtu.be/dQw4w9WgXcQ?t=30", alloc);
    defer alloc.free(got);
    try std.testing.expectEqualStrings("https://music.youtube.com/watch?v=dQw4w9WgXcQ", got);
}

test "toYoutubeMusicUrl — www.youtube.com with no v param passes through" {
    const alloc = std.testing.allocator;
    const got = try Orchestrator.toYoutubeMusicUrl("https://www.youtube.com/playlist?list=PLabc", alloc);
    defer alloc.free(got);
    try std.testing.expectEqualStrings("https://www.youtube.com/playlist?list=PLabc", got);
}

test "toYoutubeMusicUrl — youtu.be with no video id" {
    const alloc = std.testing.allocator;
    const got = try Orchestrator.toYoutubeMusicUrl("https://youtu.be/", alloc);
    defer alloc.free(got);
    try std.testing.expectEqualStrings("https://music.youtube.com/watch?v=", got);
}

test "findOnAllPlatforms — same platform as spotify returns original_url for spotify" {
    const alloc = std.testing.allocator;
    var cache = infra.TTLCache.init(alloc, 60_000);
    defer cache.deinit();
    var breaker = infra.CircuitBreaker.init("test", 5, 60_000);
    const http = infra.HttpClient.init(alloc, 1000, 0, 0, 0);
    var orch = Orchestrator.init(http, &cache, &breaker);

    const info = util.SongInfo{
        .title = "Test Song",
        .artist = "Test Artist",
        .album = "",
        .platform = "Spotify",
        .original_url = "https://open.spotify.com/track/1234567890123456789abc",
    };
    const links = try orch.findOnAllPlatforms(alloc, &info);
    defer {
        util.freeIfAllocated(alloc, links.spotify);
        util.freeIfAllocated(alloc, links.youtube_music);
        util.freeIfAllocated(alloc, links.apple_music);
    }
    try std.testing.expectEqualStrings(info.original_url, links.spotify);
}

test "findOnAllPlatforms — same platform as youtube returns original_url for youtube_music" {
    const alloc = std.testing.allocator;
    var cache = infra.TTLCache.init(alloc, 60_000);
    defer cache.deinit();
    var breaker = infra.CircuitBreaker.init("test", 5, 60_000);
    const http = infra.HttpClient.init(alloc, 1000, 0, 0, 0);
    var orch = Orchestrator.init(http, &cache, &breaker);

    const info = util.SongInfo{
        .title = "Test Song",
        .artist = "Test Artist",
        .album = "",
        .platform = "YouTube Music",
        .original_url = "https://music.youtube.com/watch?v=abc123",
    };
    const links = try orch.findOnAllPlatforms(alloc, &info);
    defer {
        util.freeIfAllocated(alloc, links.spotify);
        util.freeIfAllocated(alloc, links.youtube_music);
        util.freeIfAllocated(alloc, links.apple_music);
    }
    try std.testing.expectEqualStrings(info.original_url, links.youtube_music);
}

test "findOnAllPlatforms — same platform as youtube (not music) returns original_url for youtube_music" {
    const alloc = std.testing.allocator;
    var cache = infra.TTLCache.init(alloc, 60_000);
    defer cache.deinit();
    var breaker = infra.CircuitBreaker.init("test", 5, 60_000);
    const http = infra.HttpClient.init(alloc, 1000, 0, 0, 0);
    var orch = Orchestrator.init(http, &cache, &breaker);

    const info = util.SongInfo{
        .title = "Test Song",
        .artist = "Test Artist",
        .album = "",
        .platform = "YouTube",
        .original_url = "https://youtube.com/watch?v=abc123",
    };
    const links = try orch.findOnAllPlatforms(alloc, &info);
    defer {
        util.freeIfAllocated(alloc, links.spotify);
        util.freeIfAllocated(alloc, links.youtube_music);
        util.freeIfAllocated(alloc, links.apple_music);
    }
    try std.testing.expectEqualStrings(info.original_url, links.youtube_music);
}

test "findOnAllPlatforms — same platform as apple music returns original_url for apple_music" {
    const alloc = std.testing.allocator;
    var cache = infra.TTLCache.init(alloc, 60_000);
    defer cache.deinit();
    var breaker = infra.CircuitBreaker.init("test", 5, 60_000);
    const http = infra.HttpClient.init(alloc, 1000, 0, 0, 0);
    var orch = Orchestrator.init(http, &cache, &breaker);

    const info = util.SongInfo{
        .title = "Test Song",
        .artist = "Test Artist",
        .album = "",
        .platform = "Apple Music",
        .original_url = "https://music.apple.com/us/album/song/123",
    };
    const links = try orch.findOnAllPlatforms(alloc, &info);
    defer {
        util.freeIfAllocated(alloc, links.spotify);
        util.freeIfAllocated(alloc, links.youtube_music);
        util.freeIfAllocated(alloc, links.apple_music);
    }
    try std.testing.expectEqualStrings(info.original_url, links.apple_music);
}

test "findOnAllPlatforms — non-matching platforms try to search (caught errors become empty)" {
    const alloc = std.testing.allocator;
    var cache = infra.TTLCache.init(alloc, 60_000);
    defer cache.deinit();
    var breaker = infra.CircuitBreaker.init("test", 5, 60_000);
    const http = infra.HttpClient.init(alloc, 1000, 0, 0, 0);
    var orch = Orchestrator.init(http, &cache, &breaker);

    const info = util.SongInfo{
        .title = "Test Song",
        .artist = "Test Artist",
        .album = "",
        .platform = "SoundCloud",
        .original_url = "https://soundcloud.com/artist/test-song",
    };
    const links = try orch.findOnAllPlatforms(alloc, &info);
    defer {
        util.freeIfAllocated(alloc, links.spotify);
        util.freeIfAllocated(alloc, links.youtube_music);
        util.freeIfAllocated(alloc, links.apple_music);
    }
    try std.testing.expectEqualStrings("", links.spotify);
    try std.testing.expectEqualStrings("", links.youtube_music);
    try std.testing.expectEqualStrings("", links.apple_music);
}

test "findOnAllPlatforms — only spotify original, others search" {
    const alloc = std.testing.allocator;
    var cache = infra.TTLCache.init(alloc, 60_000);
    defer cache.deinit();
    var breaker = infra.CircuitBreaker.init("test", 5, 60_000);
    const http = infra.HttpClient.init(alloc, 1000, 0, 0, 0);
    var orch = Orchestrator.init(http, &cache, &breaker);

    const info = util.SongInfo{
        .title = "Test Song",
        .artist = "Test Artist",
        .album = "",
        .platform = "Spotify",
        .original_url = "https://open.spotify.com/track/abc123def456ghi789",
    };
    const links = try orch.findOnAllPlatforms(alloc, &info);
    defer {
        util.freeIfAllocated(alloc, links.spotify);
        util.freeIfAllocated(alloc, links.youtube_music);
        util.freeIfAllocated(alloc, links.apple_music);
    }
    try std.testing.expectEqualStrings(info.original_url, links.spotify);
}
