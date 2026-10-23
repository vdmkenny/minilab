//! Scanners. This is one interface over the platform's scanner library: SANE on macOS and Linux,
//! and TWAIN on Windows (design section 5). Both are loaded at run time, so minilab starts, and
//! does everything except scanning, on a machine that has neither.
//!
//! Every call here blocks, often for seconds: listing devices probes USB and the network, and a
//! scan takes as long as the scanner takes. Neither SANE nor TWAIN can be called from two threads
//! at once, so one thread owns the library and the scanner and makes all the calls.
//!
//!     var library = try scan.Library.load(gpa, io);
//!     defer library.unload();
//!     const devices = try library.devices(gpa);
//!     defer scan.freeDevices(gpa, devices);
//!     var scanner = try library.open(gpa, devices[0]);
//!     defer scanner.close(gpa);
//!     var capabilities = try scanner.capabilities(gpa, .transparency);
//!     defer capabilities.deinit(gpa);
//!     var progress: scan.Progress = .{};
//!     var image = try scanner.scan(gpa, .{ .source = .transparency, .dpi = 300 }, &progress);
//!     defer image.deinit(gpa);
//!
//! Apart from `std`, this module only uses the image constants from `core/` and the film format
//! constants from `frames/`.

const std = @import("std");
const builtin = @import("builtin");

pub const sane = @import("sane.zig");
pub const twain = @import("twain.zig");

/// The scanner libraries we support.
pub const Kind = enum {
    sane,
    twain,

    pub fn label(kind: Kind) []const u8 {
        return switch (kind) {
            .sane => "SANE",
            .twain => "TWAIN",
        };
    }
};

/// The library this platform scans through.
pub const native: Kind = if (builtin.os.tag == .windows) .twain else .sane;

pub const Error = error{
    /// The scanner library isn't installed, or this platform doesn't have it.
    Unavailable,
    /// There's no such device, or it went away.
    NotFound,
    Busy,
    AccessDenied,
    /// The scanner can't do what was asked: a source, mode or area it doesn't have.
    Unsupported,
    Jammed,
    CoverOpen,
    /// The feeder is empty.
    NoDocument,
    /// The library or the scanner reported an error without saying more precisely what went
    /// wrong.
    Failed,
    OutOfMemory,
};

/// A scanner the library can open.
pub const Device = struct {
    /// The name the library knows the device by: SANE's device name, such as
    /// "epkowa:interpreter:000:004", or a TWAIN source's product name.
    id: []const u8,
    vendor: []const u8,
    model: []const u8,
    /// The driver behind the device: a SANE backend such as "epkowa", or "TWAIN".
    driver: []const u8,
    kind: Kind,

    pub fn deinit(device: *Device, gpa: std.mem.Allocator) void {
        gpa.free(device.id);
        gpa.free(device.vendor);
        gpa.free(device.model);
        gpa.free(device.driver);
        device.* = undefined;
    }

    pub fn clone(device: Device, gpa: std.mem.Allocator) !Device {
        const id = try gpa.dupe(u8, device.id);
        errdefer gpa.free(id);
        const vendor = try gpa.dupe(u8, device.vendor);
        errdefer gpa.free(vendor);
        const model = try gpa.dupe(u8, device.model);
        errdefer gpa.free(model);
        return .{ .id = id, .vendor = vendor, .model = model, .driver = try gpa.dupe(u8, device.driver), .kind = device.kind };
    }
};

/// Frees a list from `Library.devices`.
pub fn freeDevices(gpa: std.mem.Allocator, devices: []Device) void {
    for (devices) |*d| d.deinit(gpa);
    gpa.free(devices);
}

/// Copies `devices`, giving each copy its own strings. Free the list with `freeDevices`.
pub fn cloneDevices(gpa: std.mem.Allocator, devices: []const Device) error{OutOfMemory}![]Device {
    var list: DeviceList = .empty;
    errdefer list.deinit(gpa);
    try list.devices.ensureTotalCapacityPrecise(gpa, devices.len);
    for (devices) |device| try list.append(gpa, device);
    return list.toOwnedSlice(gpa);
}

/// A list of devices being built, holding its own copy of each device's strings. The libraries
/// list their devices in their own memory, which they reuse or free.
pub const DeviceList = struct {
    devices: std.ArrayList(Device),

    pub const empty: DeviceList = .{ .devices = .empty };

    /// Frees the list and every device in it.
    pub fn deinit(list: *DeviceList, gpa: std.mem.Allocator) void {
        for (list.devices.items) |*d| d.deinit(gpa);
        list.devices.deinit(gpa);
        list.* = undefined;
    }

    /// Adds a copy of `device`, whose strings may belong to someone else.
    pub fn append(list: *DeviceList, gpa: std.mem.Allocator, device: Device) error{OutOfMemory}!void {
        var copy = try device.clone(gpa);
        errdefer copy.deinit(gpa);
        try list.devices.append(gpa, copy);
    }

    /// Hands over the devices, for the caller to free with `freeDevices`. The list is left empty.
    pub fn toOwnedSlice(list: *DeviceList, gpa: std.mem.Allocator) error{OutOfMemory}![]Device {
        return list.devices.toOwnedSlice(gpa);
    }
};

/// Standard resolutions, for scanners that give a range instead of a list.
pub const standard_resolutions = [_]u32{ 75, 100, 150, 200, 300, 400, 600, 800, 1200, 1600, 2400, 3200, 4800, 6400, 9600 };

/// Appends the standard resolutions that fall in a scanner's range to `resolutions`. The range
/// goes from `low` to `high` in steps of `step`, and a step of 0 allows any value in it.
pub fn appendResolutionsInRange(gpa: std.mem.Allocator, resolutions: *std.ArrayList(u32), low: f64, high: f64, step: f64) error{OutOfMemory}!void {
    for (standard_resolutions) |r| {
        const value: f64 = @floatFromInt(r);
        if (value < low or value > high) continue;
        if (step > 0 and @mod(value - low, step) != 0) continue;
        try resolutions.append(gpa, r);
    }
}

/// Where the scanner reads from.
pub const Source = enum {
    /// Reflective: prints and documents on the glass.
    flatbed,
    /// Light shining through the film: a transparency unit or film adapter.
    transparency,
    feeder,

    pub fn label(source: Source) []const u8 {
        return switch (source) {
            .flatbed => "Flatbed",
            .transparency => "Transparency Unit",
            .feeder => "Document feeder",
        };
    }

    /// Works out which source a library's name for it means, from the words in the name. Returns
    /// null for names with no words we recognise.
    pub fn classify(name: []const u8) ?Source {
        const transparency_words = [_][]const u8{ "transparen", "film", "tpu", "slide", "negative", "positive", "tma", "tpa" };
        for (transparency_words) |word| if (containsIgnoreCase(name, word)) return .transparency;
        const feeder_words = [_][]const u8{ "adf", "feeder", "duplex" };
        for (feeder_words) |word| if (containsIgnoreCase(name, word)) return .feeder;
        if (containsIgnoreCase(name, "flatbed") or containsIgnoreCase(name, "normal") or containsIgnoreCase(name, "glass")) return .flatbed;
        return null;
    }
};

/// The scanner's own film setting. Scanners that have one adjust their exposure per channel for
/// the orange mask when it's set to `negative`. `positive` leaves the channels alone.
pub const Film = enum {
    negative,
    positive,
};

/// A rectangle on the scanner, in mm from its origin: x across the glass, y down it.
pub const Area = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub fn right(area: Area) f32 {
        return area.x + area.width;
    }

    pub fn bottom(area: Area) f32 {
        return area.y + area.height;
    }

    /// Cuts `area` down to `limit`. Returns null when none of it is inside.
    pub fn clip(area: Area, limit: Area) ?Area {
        const x = @max(area.x, limit.x);
        const y = @max(area.y, limit.y);
        const r = @min(area.right(), limit.right());
        const b = @min(area.bottom(), limit.bottom());
        if (r <= x or b <= y) return null;
        return .{ .x = x, .y = y, .width = r - x, .height = b - y };
    }
};

/// What one of a scanner's sources can do.
pub const Capabilities = struct {
    /// Every source the scanner has.
    sources: std.EnumSet(Source),
    /// The source that the rest of these fields describe.
    source: Source,
    /// Its resolutions in pixels per inch, from low to high.
    resolutions: []u32,
    /// The largest area the source can scan.
    area: Area,
    /// Whether it delivers 16 bits per channel.
    deep: bool,
    /// Whether it has a film setting (`Film`).
    film_setting: bool,
    /// The settings that make this model's data linear, if we've measured them.
    profile: ?*const Profile,

    pub fn deinit(capabilities: *Capabilities, gpa: std.mem.Allocator) void {
        gpa.free(capabilities.resolutions);
        capabilities.* = undefined;
    }

    /// Returns the lowest resolution that's at least `dpi`, or else the highest one there is.
    pub fn resolutionFrom(capabilities: Capabilities, dpi: u32) ?u32 {
        for (capabilities.resolutions) |r| if (r >= dpi) return r;
        return if (capabilities.resolutions.len > 0) capabilities.resolutions[capabilities.resolutions.len - 1] else null;
    }
};

/// What to ask the scanner for in one scan.
pub const Request = struct {
    source: Source,
    film: Film = .negative,
    dpi: u32,
    /// 16 bits per channel if the scanner has them, otherwise 8.
    deep: bool = true,
    /// What to scan, or null for the source's whole area.
    area: ?Area = null,
};

/// A scan as the scanner delivered it: RGB, and linear if the scanner's profile makes it so.
pub const Image = struct {
    width: usize,
    height: usize,
    /// Row by row. 8-bit data is scaled to the full 16-bit range.
    pixels: [][3]u16,
    /// The bits per channel the scanner delivered: 8 or 16.
    depth: u8,
    /// The resolution the scanner used, across and down.
    dpi: [2]f32,
    /// The area the scanner used. It may have rounded the area we asked for.
    area: Area,

    pub fn deinit(image: *Image, gpa: std.mem.Allocator) void {
        gpa.free(image.pixels);
        image.* = undefined;
    }
};

/// How far a scan has got, for another thread to read while it runs.
pub const Progress = struct {
    /// Lines read so far.
    lines: std.atomic.Value(u32) = .init(0),
    /// How many lines the scan will have. It's 0 until the scanner tells us, which happens after
    /// its lamp has warmed up.
    total: std.atomic.Value(u32) = .init(0),

    pub fn reset(progress: *Progress) void {
        progress.lines.store(0, .release);
        progress.total.store(0, .release);
    }

    /// The share of lines read so far, or 0 before the scan starts.
    pub fn fraction(progress: *const Progress) f32 {
        const total = progress.total.load(.acquire);
        if (total == 0) return 0;
        return @min(1, @as(f32, @floatFromInt(progress.lines.load(.acquire))) / @as(f32, @floatFromInt(total)));
    }
};

/// The settings that make one scanner model deliver linear, unprocessed data, based on our own
/// measurements of it. The option names and values are the ones its SANE backend uses.
pub const Profile = struct {
    driver: []const u8,
    /// Matched against the start of the device's model name.
    model: []const u8,
    /// What it sets up, in the words the interface shows.
    summary: []const u8,
    /// Options set for every scan.
    options: []const Setting,
    /// The option for the film setting, and its value for each `Film`.
    film_option: ?[]const u8 = null,
    negative: []const u8 = "",
    positive: []const u8 = "",

    pub const Setting = struct { name: []const u8, value: Value };
    pub const Value = union(enum) { string: []const u8, int: i32 };
};

/// Every profile we have. The V200's comes from the epkowa work and our raw scans of a colour
/// strip. Setting its gamma table to 1.0 gives linear data, and setting its colour matrix ("cct")
/// to the identity keeps the channels apart. Its default matrix mixes them to make the picture
/// more saturated.
pub const profiles = [_]Profile{
    .{
        .driver = "epkowa",
        .model = "Perfection V200",
        .summary = "Transparency Unit, 48-bit, gamma 1.0, no colour matrix (raw)",
        .options = &.{
            .{ .name = "mode", .value = .{ .string = "Color" } },
            .{ .name = "gamma-correction", .value = .{ .string = "User defined (Gamma=1.0)" } },
            .{ .name = "cct-1", .value = .{ .int = 1 } },
            .{ .name = "cct-2", .value = .{ .int = 0 } },
            .{ .name = "cct-3", .value = .{ .int = 0 } },
            .{ .name = "cct-4", .value = .{ .int = 0 } },
            .{ .name = "cct-5", .value = .{ .int = 1 } },
            .{ .name = "cct-6", .value = .{ .int = 0 } },
            .{ .name = "cct-7", .value = .{ .int = 0 } },
            .{ .name = "cct-8", .value = .{ .int = 0 } },
            .{ .name = "cct-9", .value = .{ .int = 1 } },
        },
        .film_option = "film-type",
        .negative = "Negative Film",
        .positive = "Positive Film",
    },
};

/// The profile of a device, if we have one.
pub fn profileOf(driver: []const u8, model: []const u8) ?*const Profile {
    for (&profiles) |*p| {
        if (std.mem.eql(u8, p.driver, driver) and std.mem.startsWith(u8, model, p.model)) return p;
    }
    return null;
}

/// A loaded scanner library.
pub const Library = union(Kind) {
    sane: sane.Library,
    twain: twain.Library,

    /// Loads the platform's library. Returns `Error.Unavailable` when it isn't installed.
    pub fn load(gpa: std.mem.Allocator, io: std.Io) Error!Library {
        return switch (native) {
            .sane => .{ .sane = try sane.Library.load(gpa, io) },
            .twain => .{ .twain = try twain.Library.load(gpa) },
        };
    }

    pub fn unload(library: *Library) void {
        switch (library.*) {
            inline else => |*l| l.unload(),
        }
        library.* = undefined;
    }

    /// Lists the scanners that are attached. Free the list with `freeDevices`.
    pub fn devices(library: *Library, gpa: std.mem.Allocator) Error![]Device {
        return switch (library.*) {
            inline else => |*l| l.devices(gpa),
        };
    }

    pub fn open(library: *Library, gpa: std.mem.Allocator, device: Device) Error!Scanner {
        return switch (library.*) {
            .sane => |*l| .{ .sane = try l.open(gpa, device) },
            .twain => |*l| .{ .twain = try l.open(gpa, device) },
        };
    }
};

/// An open scanner.
pub const Scanner = union(Kind) {
    sane: sane.Scanner,
    twain: twain.Scanner,

    /// Switches to `source` and says what it can do. Null keeps the scanner's current source.
    /// Free the result with `Capabilities.deinit`.
    pub fn capabilities(scanner: *Scanner, gpa: std.mem.Allocator, source: ?Source) Error!Capabilities {
        return switch (scanner.*) {
            inline else => |*s| s.capabilities(gpa, source),
        };
    }

    /// Scans, and returns once the whole image has been read. The scan always runs to the end,
    /// because on the V200 an interrupted scan leaves the scanner stuck until it's switched off.
    pub fn scan(scanner: *Scanner, gpa: std.mem.Allocator, request: Request, progress: *Progress) Error!Image {
        return switch (scanner.*) {
            inline else => |*s| s.scan(gpa, request, progress),
        };
    }

    pub fn close(scanner: *Scanner, gpa: std.mem.Allocator) void {
        switch (scanner.*) {
            inline else => |*s| s.close(gpa),
        }
        scanner.* = undefined;
    }
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.findIgnoreCase(haystack, needle) != null;
}

test "sources are told apart by their names" {
    try std.testing.expectEqual(Source.transparency, Source.classify("Transparency Unit").?);
    try std.testing.expectEqual(Source.transparency, Source.classify("Transparency Adapter").?);
    try std.testing.expectEqual(Source.transparency, Source.classify("Film").?);
    try std.testing.expectEqual(Source.flatbed, Source.classify("Flatbed").?);
    try std.testing.expectEqual(Source.feeder, Source.classify("ADF Duplex").?);
    try std.testing.expectEqual(@as(?Source, null), Source.classify("Default"));
}

test "the V200 has a profile, other scanners don't" {
    const v200 = profileOf("epkowa", "Perfection V200").?;
    try std.testing.expectEqualStrings("film-type", v200.film_option.?);
    try std.testing.expectEqual(@as(?*const Profile, null), profileOf("epson2", "Perfection V200"));
    try std.testing.expectEqual(@as(?*const Profile, null), profileOf("epkowa", "GT-X980"));
}

test "areas clip to the scanner's" {
    const glass: Area = .{ .x = 0, .y = 0, .width = 33.02, .height = 244.348 };
    const inside = (Area{ .x = 10, .y = 50, .width = 40, .height = 40 }).clip(glass).?;
    try std.testing.expectApproxEqAbs(@as(f32, 23.02), inside.width, 1e-4);
    try std.testing.expectEqual(@as(?Area, null), (Area{ .x = 40, .y = 0, .width = 5, .height = 5 }).clip(glass));
}

test "a resolution of at least the one asked for" {
    var resolutions = [_]u32{ 300, 2400, 4800 };
    const capabilities: Capabilities = .{ .sources = .initOne(.transparency), .source = .transparency, .resolutions = &resolutions, .area = .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .deep = true, .film_setting = true, .profile = null };
    try std.testing.expectEqual(@as(?u32, 300), capabilities.resolutionFrom(200));
    try std.testing.expectEqual(@as(?u32, 2400), capabilities.resolutionFrom(301));
    try std.testing.expectEqual(@as(?u32, 4800), capabilities.resolutionFrom(9600));
}

test "a range gives the standard resolutions on its steps" {
    const gpa = std.testing.allocator;
    var resolutions: std.ArrayList(u32) = .empty;
    defer resolutions.deinit(gpa);
    try appendResolutionsInRange(gpa, &resolutions, 100, 1200, 100);
    try std.testing.expectEqualSlices(u32, &.{ 100, 200, 300, 400, 600, 800, 1200 }, resolutions.items);
    resolutions.clearRetainingCapacity();
    try appendResolutionsInRange(gpa, &resolutions, 50, 160, 0);
    try std.testing.expectEqualSlices(u32, &.{ 75, 100, 150 }, resolutions.items);
}

test "copied devices keep their strings when the library's change" {
    const gpa = std.testing.allocator;
    var id = "test".*;
    const borrowed: Device = .{ .id = &id, .vendor = "Noname", .model = "frontend-tester", .driver = "test", .kind = .sane };
    const copies = try cloneDevices(gpa, &.{ borrowed, borrowed });
    defer freeDevices(gpa, copies);
    id[0] = 'b';
    try std.testing.expectEqual(@as(usize, 2), copies.len);
    try std.testing.expectEqualStrings("test", copies[1].id);
    try std.testing.expectEqualStrings("frontend-tester", copies[0].model);
}

fn cloneAndFreeDevices(gpa: std.mem.Allocator) !void {
    const device: Device = .{ .id = "test", .vendor = "Noname", .model = "frontend-tester", .driver = "test", .kind = .sane };
    freeDevices(gpa, try cloneDevices(gpa, &.{ device, device, device }));
}

test "copying devices frees what it made when memory runs out" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, cloneAndFreeDevices, .{});
}

test {
    std.testing.refAllDecls(@This());
}
