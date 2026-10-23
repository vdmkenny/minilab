//! The version minilab reports. That's the release Release Please keeps in `build.zig.zon`, plus,
//! for a build after that release, how many commits after it and which commit, from
//! `git describe` (see `build.zig`).

const std = @import("std");
const build_options = @import("build_options");

/// For example `0.0.1` at a release, or `0.0.1+12.gabc1234` twelve commits after it, with `.dirty`
/// on the end when the checkout has uncommitted changes.
pub const string = named(build_options.version, build_options.describe);

/// Returns `release`, plus how far past it `describe` says the checkout is, as SemVer build
/// metadata. If `describe` isn't output from `git describe --long --dirty`, `release` stays as it
/// is.
fn named(comptime release: []const u8, comptime describe: []const u8) []const u8 {
    const past = Past.parse(describe) orelse return release;
    if (std.mem.eql(u8, past.commits, "0") and !past.dirty) return release;
    return release ++ "+" ++ past.commits ++ "." ++ past.commit ++ if (past.dirty) ".dirty" else "";
}

/// What `git describe --long --dirty` says about the checkout: how many commits it is past the
/// tag, the commit (with its `g` prefix), and whether it has uncommitted changes.
const Past = struct {
    commits: []const u8,
    commit: []const u8,
    dirty: bool,

    fn parse(describe: []const u8) ?Past {
        const clean = std.mem.cutSuffix(u8, describe, "-dirty");
        const tag_commits, const commit = std.mem.cutScalarLast(u8, clean orelse describe, '-') orelse return null;
        _, const commits = std.mem.cutScalarLast(u8, tag_commits, '-') orelse return null;
        if (commits.len == 0 or commit.len < 2 or commit[0] != 'g') return null;
        for (commits) |digit| if (!std.ascii.isDigit(digit)) return null;
        return .{ .commits = commits, .commit = commit, .dirty = clean != null };
    }
};

test named {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "v0.0.1-0-gabc1234", "0.0.1" },
        .{ "v0.0.1-12-gabc1234", "0.0.1+12.gabc1234" },
        .{ "v0.0.1-12-gabc1234-dirty", "0.0.1+12.gabc1234.dirty" },
        .{ "", "0.0.1" },
        .{ "abc1234", "0.0.1" },
    };
    inline for (cases) |case| try std.testing.expectEqualStrings(case[1], comptime named("0.0.1", case[0]));
}
