//! The system's language, as its user set it.

const std = @import("std");
const c = @import("c");
const Language = @import("minilab").preferences.Language;

/// The first of the user's preferred languages that the app has, or null when it has none of
/// them.
pub fn preferredLanguage() ?Language {
    var count: c_int = 0;
    const locales = c.SDL_GetPreferredLocales(&count) orelse return null;
    defer c.SDL_free(@ptrCast(locales));
    for (locales[0..@intCast(count)]) |locale| {
        const code = locale.*.language orelse continue;
        if (Language.ofCode(std.mem.span(code))) |language| return language;
    }
    return null;
}
