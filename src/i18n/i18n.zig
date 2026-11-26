//! The interface's text in each language. English is written in `messages.zig` and the files
//! in `en/`, as the messages' defaults, and each other language has a file of its own here,
//! like `nl.zon`, with the same messages translated. A message a language doesn't have falls
//! back to English. docs/translating.md has how to add a language.
//!
//! Messages with values in them mark where each goes with `{0}`, `{1}` and so on, so a
//! translation can put them in its own order. `format` fills them in.

const std = @import("std");
const Language = @import("minilab").preferences.Language;
pub const Messages = @import("messages.zig").Messages;

/// Every language's messages. A language's file only needs the messages it translates.
const catalogue: std.EnumArray(Language, Messages) = .init(.{
    .en = .{},
    .nl = @import("nl.zon"),
    .fr = @import("fr.zon"),
    .de = @import("de.zon"),
    .it = @import("it.zon"),
    .es = @import("es.zon"),
    .ja = @import("ja.zon"),
});

/// The files, for the tests that check them.
const sources: std.EnumArray(Language, [:0]const u8) = .init(.{
    .en = "",
    .nl = @embedFile("nl.zon"),
    .fr = @embedFile("fr.zon"),
    .de = @embedFile("de.zon"),
    .it = @embedFile("it.zon"),
    .es = @embedFile("es.zon"),
    .ja = @embedFile("ja.zon"),
});

/// The messages in the language the interface uses now. Change it with `use`.
pub var t: *const Messages = catalogue.getPtrConst(.en);
/// The language `t` is in.
pub var current: Language = .en;

pub fn use(language: Language) void {
    t = catalogue.getPtrConst(language);
    current = language;
}

/// The label for enum `value` from `labels`, a struct with a message for each of its tags, as
/// in `t.labels`.
pub fn label(labels: anytype, value: anytype) [:0]const u8 {
    return switch (value) {
        inline else => |tag| @field(labels, @tagName(tag)),
    };
}

/// The most values a message has.
const max_values = 10;

/// `template` with its placeholders, `{0}` up to `{9}`, filled with `values` in order. A
/// string goes in as it is and a number in decimal; anything else, like a number to round, is
/// formatted by the caller first.
pub fn format(gpa: std.mem.Allocator, template: []const u8, values: anytype) ![:0]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < template.len) {
        const at = placeholderAt(template, i) orelse {
            try out.writer.writeByte(template[i]);
            i += 1;
            continue;
        };
        inline for (values, 0..) |value, n| {
            if (n == at) try writeValue(&out.writer, value);
        }
        i += placeholder_len;
    }
    return out.toOwnedSliceSentinel(0);
}

/// A placeholder's length: a brace, a digit and a brace.
const placeholder_len = "{0}".len;

/// The number of the placeholder at `i` in `template`, if there's one there.
fn placeholderAt(template: []const u8, i: usize) ?usize {
    if (i + placeholder_len > template.len or template[i] != '{' or template[i + 2] != '}') return null;
    return std.fmt.charToDigit(template[i + 1], max_values) catch null;
}

fn writeValue(w: *std.Io.Writer, value: anytype) !void {
    const T = @TypeOf(value);
    if (comptime isString(T)) return w.print("{s}", .{value});
    return w.print("{d}", .{value});
}

fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child == u8 or switch (@typeInfo(p.child)) {
            .array => |a| a.child == u8,
            else => false,
        },
        else => false,
    };
}

/// The placeholders in `message`, as a set of their numbers.
fn placeholders(message: []const u8) std.bit_set.Integer(max_values) {
    var set: std.bit_set.Integer(max_values) = .empty;
    for (0..message.len) |i| if (placeholderAt(message, i)) |n| set.set(n);
    return set;
}

test "a message's values go where its placeholders say, in any order" {
    const gpa = std.testing.allocator;
    const text = try format(gpa, "Added {0} of {1} scans to {2}", .{ 3, 4, "Roll 012" });
    defer gpa.free(text);
    try std.testing.expectEqualStrings("Added 3 of 4 scans to Roll 012", text);
    const swapped = try format(gpa, "{2}: {0}/{1}", .{ 3, 4, "Roll 012" });
    defer gpa.free(swapped);
    try std.testing.expectEqualStrings("Roll 012: 3/4", swapped);
}

test "every language translates every message" {
    const gpa = std.testing.allocator;
    var missing: usize = 0;
    for (std.enums.values(Language)) |language| {
        if (language == .en) continue;
        var keys = try keysIn(gpa, sources.get(language));
        defer freeKeys(gpa, &keys);
        missing += reportMissing(Messages, .{}, "", &keys, language);
    }
    try std.testing.expectEqual(@as(usize, 0), missing);
}

test "every translation keeps its message's placeholders" {
    var wrong: usize = 0;
    for (std.enums.values(Language)) |language| {
        wrong += checkPlaceholders(Messages, .{}, catalogue.get(language), "", language);
    }
    try std.testing.expectEqual(@as(usize, 0), wrong);
}

/// Prints each message of `english` (of type `T`, at `prefix`) that `keys` doesn't have, with
/// its English text, ready to translate. Returns how many there are.
fn reportMissing(comptime T: type, english: T, comptime prefix: []const u8, keys: *const Keys, language: Language) usize {
    var count: usize = 0;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, Field| {
        const path = prefix ++ name;
        if (Field == [:0]const u8) {
            if (!keys.contains(path)) {
                std.debug.print("{t}.zon is missing .{s} = \"{s}\"\n", .{ language, path, @field(english, name) });
                count += 1;
            }
        } else count += reportMissing(Field, @field(english, name), path ++ ".", keys, language);
    }
    return count;
}

fn checkPlaceholders(comptime T: type, english: T, translated: T, comptime prefix: []const u8, language: Language) usize {
    var count: usize = 0;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, Field| {
        const ours = @field(english, name);
        const theirs = @field(translated, name);
        if (Field == [:0]const u8) {
            if (!placeholders(ours).eql(placeholders(theirs))) {
                std.debug.print("{t}.zon: .{s} has other placeholders than \"{s}\"\n", .{ language, prefix ++ name, ours });
                count += 1;
            }
        } else count += checkPlaceholders(Field, ours, theirs, prefix ++ name ++ ".", language);
    }
    return count;
}

/// The keys a language's file has, as paths like "rolls.new_roll".
const Keys = std.StringHashMapUnmanaged(void);

fn keysIn(gpa: std.mem.Allocator, source: [:0]const u8) !Keys {
    var tree: std.zig.Ast = try .parse(gpa, source, .{ .mode = .zon });
    defer tree.deinit(gpa);
    var zoir = try std.zig.ZonGen.generate(gpa, tree, .{});
    defer zoir.deinit(gpa);
    var keys: Keys = .empty;
    errdefer freeKeys(gpa, &keys);
    try collectKeys(gpa, &zoir, .root, "", &keys);
    return keys;
}

fn collectKeys(gpa: std.mem.Allocator, zoir: *const std.zig.Zoir, node: std.zig.Zoir.Node.Index, prefix: []const u8, keys: *Keys) !void {
    switch (node.get(zoir)) {
        .struct_literal => |literal| for (literal.names, 0..) |name, i| {
            const path = try std.fmt.allocPrint(gpa, "{s}{s}", .{ prefix, name.get(zoir) });
            errdefer gpa.free(path);
            const value = literal.vals.at(@intCast(i));
            if (value.get(zoir) == .struct_literal) {
                defer gpa.free(path);
                const nested = try std.fmt.allocPrint(gpa, "{s}.", .{path});
                defer gpa.free(nested);
                try collectKeys(gpa, zoir, value, nested, keys);
            } else try keys.put(gpa, path, {});
        },
        .empty_literal => {},
        else => return error.NotMessages,
    }
}

fn freeKeys(gpa: std.mem.Allocator, keys: *Keys) void {
    var each = keys.keyIterator();
    while (each.next()) |key| gpa.free(key.*);
    keys.deinit(gpa);
}
