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
            const music_url = try Orchestrator.toYoutubeMusicUrl(url_str, allocator);
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
        const got = try Orchestrator.toYoutubeMusicUrl("https://www.youtube.com/watch?v=dQw4w9WgXcQ", alloc);
        defer alloc.free(got);
        try std.testing.expectEqualStrings("https://music.youtube.com/watch?v=dQw4w9WgXcQ", got);
    }
    {
        const got = try Orchestrator.toYoutubeMusicUrl("https://youtu.be/dQw4w9WgXcQ", alloc);
        defer alloc.free(got);
        try std.testing.expectEqualStrings("https://music.youtube.com/watch?v=dQw4w9WgXcQ", got);
    }
    {
        const got = try Orchestrator.toYoutubeMusicUrl("https://music.youtube.com/watch?v=dQw4w9WgXcQ", alloc);
        defer alloc.free(got);
        try std.testing.expectEqualStrings("https://music.youtube.com/watch?v=dQw4w9WgXcQ", got);
    }
    {
        const got = try Orchestrator.toYoutubeMusicUrl("https://youtu.be/dQw4w9WgXcQ?si=abc123&t=30", alloc);
        defer alloc.free(got);
        try std.testing.expectEqualStrings("https://music.youtube.com/watch?v=dQw4w9WgXcQ", got);
    }
}
