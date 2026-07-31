// Root source for library builds — tests live in each module
// For the executable, src/main.zig is the entry point.
const std = @import("std");
pub const util = @import("util.zig");
pub const infra = @import("infra.zig");
pub const orchestrator = @import("orchestrator.zig");
pub const platform = @import("platform.zig");
pub const bot = @import("bot.zig");

test "root: all module exports compile and are accessible" {
    _ = util.Config{ .telegram_token = "test" };
    _ = util.SongInfo{ .title = "", .artist = "", .album = "", .platform = "", .original_url = "" };
    _ = util.MusicLinks{};
    _ = infra.HttpClient.init(std.testing.allocator, 1000, 0, 0, 0);
    var cache = infra.TTLCache.init(std.testing.allocator, 60_000);
    defer cache.deinit();
    var breaker = infra.CircuitBreaker.init("test", 5, 60_000);
    const http = infra.HttpClient.init(std.testing.allocator, 1000, 0, 0, 0);
    var orch = orchestrator.Orchestrator.init(http, &cache, &breaker);
    _ = &orch;
    _ = &bot;
}

test "root: SongInfo defaults and field ordering" {
    const info = util.SongInfo{
        .title = "Test",
        .artist = "Artist",
        .album = "Album",
        .platform = "Spotify",
        .original_url = "https://open.spotify.com/track/abc",
    };
    try std.testing.expectEqualStrings("Test", info.title);
    try std.testing.expectEqualStrings("Artist", info.artist);
    try std.testing.expectEqualStrings("Album", info.album);
    try std.testing.expectEqualStrings("Spotify", info.platform);
    try std.testing.expectEqualStrings("https://open.spotify.com/track/abc", info.original_url);
}

test "root: MusicLinks defaults to empty strings" {
    const links = util.MusicLinks{};
    try std.testing.expectEqualStrings("", links.spotify);
    try std.testing.expectEqualStrings("", links.youtube_music);
    try std.testing.expectEqualStrings("", links.apple_music);
}
