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
//!     defer scanner.close();
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
const image = @import("../core/image.zig");

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
/// No scanner comes near this many pixels per inch. A driver that reports more is wrong.
const max_dpi = 100_000;

/// A resolution a driver reports, as a whole number, or null when it isn't one a scanner could
/// have: not a number, below 1, or absurdly high. Casting it as it is could crash the app.
pub fn resolutionOf(value: f64) ?u32 {
    if (!std.math.isFinite(value) or value < 1 or value > max_dpi) return null;
    return @intFromFloat(@round(value));
}

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
    /// Without a profile, the options raw setup reads (`rawSetup`). Empty with a profile, and on
    /// TWAIN, which doesn't list its options.
    options: ?Owned(OptionInfo) = null,

    pub fn deinit(capabilities: *Capabilities, gpa: std.mem.Allocator) void {
        gpa.free(capabilities.resolutions);
        if (capabilities.options) |*o| o.deinit();
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
    /// The scanner settings' changes to raw setup. They're borrowed, so they have to last until
    /// the scan is done.
    raw: []const RawSetting = &.{},
};

/// A scan as the scanner delivered it: RGB, and linear if the scanner's profile makes it so.
pub const Image = struct {
    /// The pixels. 8-bit data is scaled to the full 16-bit range.
    scan: image.Scan,
    /// The bits per channel the scanner delivered.
    depth: image.Depth,
    /// The resolution the scanner used, across and down.
    dpi: [2]f32,
    /// The area the scanner used. It may have rounded the area we asked for.
    area: Area,

    pub fn deinit(picture: *Image, gpa: std.mem.Allocator) void {
        picture.scan.deinit(gpa);
        picture.* = undefined;
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
    /// The option for the film setting and its value for each `Film`, if the scanner has one.
    film: ?FilmSetting = null,

    pub const Setting = struct { name: []const u8, value: Value };
    pub const FilmSetting = struct {
        option: []const u8,
        negative: []const u8,
        positive: []const u8,

        pub fn value(setting: FilmSetting, film: Film) []const u8 {
            return switch (film) {
                .negative => setting.negative,
                .positive => setting.positive,
            };
        }
    };
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
        .summary = "Transparency Unit, 48-bit, gamma 1.0, no color matrix (raw)",
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
        .film = .{ .option = "film-type", .negative = "Negative Film", .positive = "Positive Film" },
    },
};

/// The profile of a device, if we have one.
pub fn profileOf(driver: []const u8, model: []const u8) ?*const Profile {
    for (&profiles) |*p| {
        if (std.mem.eql(u8, p.driver, driver) and std.mem.startsWith(u8, model, p.model)) return p;
    }
    return null;
}

// Raw setup without a profile ----------------------------------------------------------------

/// One of a scanner's options, as raw setup sees it.
pub const OptionInfo = struct {
    name: []const u8,
    kind: Type,
    /// A string option's values.
    choices: []const []const u8 = &.{},
    /// A number's or a table's range, when it has one.
    range: ?[2]f64 = null,

    pub const Type = enum {
        bool,
        number,
        string,
        table,
        /// epkowa's colour matrix: its nine `cct` options, taken as one.
        matrix,
        other,
    };
};

/// What raw setup sets an option to.
pub const RawValue = union(enum) {
    /// Nothing: the driver's own default.
    leave,
    /// The film setting for the scan's `Film`, found with `filmChoice`.
    film,
    /// One of a list option's values.
    choose: []const u8,
    /// A number, or a switch's 1 (on) or 0 (off).
    number: f64,
    /// A gamma table filled with a straight line, or the colour matrix set to the identity.
    straight,

    /// Writes the value for the log, as `{f}`.
    pub fn format(value: RawValue, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (value) {
            .leave => try writer.writeAll("(driver default)"),
            .film => try writer.writeAll("(film type)"),
            .choose => |v| try writer.print("\"{s}\"", .{v}),
            .number => |v| try writer.print("{d}", .{v}),
            .straight => try writer.writeAll("(straight)"),
        }
    }

    pub fn eql(a: RawValue, b: RawValue) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .choose => |v| std.mem.eql(u8, v, b.choose),
            .number => |v| v == b.number,
            .leave, .film, .straight => true,
        };
    }
};

/// An option and what raw setup sets it to. The scanner settings keep the user's changes in
/// the same form.
pub const RawSetting = struct {
    name: []const u8,
    value: RawValue,
};

/// An option raw setup can set, what it's for, and what raw setup sets it to by itself.
pub const RawControl = struct {
    option: OptionInfo,
    role: Role,
    auto: RawValue,

    pub const Role = enum {
        film,
        /// SANE's `custom-gamma`, which switches the gamma tables on.
        gamma_switch,
        /// A list of gamma settings, such as epson2's `gamma-correction`.
        gamma_choice,
        gamma_table,
        /// A gamma number.
        gamma,
        colour_correction,
        colour_matrix,
        /// Brightness or contrast.
        tone,
    };
};

/// How raw setup leaves the scanner, for the Scan screen.
pub const RawReport = struct {
    /// Gamma 1.0: a straight table, a gamma of 1.0, or a choice that says so.
    linear: bool = false,
    /// Colour correction off, or its matrix set to the identity.
    colour_off: bool = false,
    /// A film setting, so positive film can keep the scanner from inverting.
    film: bool = false,

    /// The report as a label, such as "Raw · gamma 1.0 · color correction off".
    pub fn label(report: RawReport, buffer: []u8) []const u8 {
        if (!report.linear) return "No profile · data may not be linear";
        return std.fmt.bufPrint(buffer, "Raw · gamma 1.0{s}", .{if (report.colour_off) " · color correction off" else ""}) catch "Raw · gamma 1.0";
    }
};

/// The most options raw setup sets.
const max_raw_controls = 24;

/// The options raw setup can set on one scanner, in the order it sets them.
pub const RawControls = struct {
    buffer: [max_raw_controls]RawControl = undefined,
    len: usize = 0,

    pub fn all(controls: *const RawControls) []const RawControl {
        return controls.buffer[0..controls.len];
    }

    fn add(controls: *RawControls, option: OptionInfo, role: RawControl.Role, auto: RawValue) void {
        if (controls.len == controls.buffer.len) return;
        controls.buffer[controls.len] = .{ .option = option, .role = role, .auto = auto };
        controls.len += 1;
    }
};

/// SANE's standard names for the gamma switch and tables (`saneopts.h`).
const custom_gamma = "custom-gamma";
const gamma_tables = [_][]const u8{ "gamma-table", "red-gamma-table", "green-gamma-table", "blue-gamma-table" };
const gamma_numbers = [_][]const u8{ "gamma", "analog-gamma", "analog-gamma-r", "analog-gamma-g", "analog-gamma-b" };
/// epkowa's colour matrix, row by row (the V200's profile sets it).
pub const colour_matrix = [_][]const u8{ "cct-1", "cct-2", "cct-3", "cct-4", "cct-5", "cct-6", "cct-7", "cct-8", "cct-9" };
/// The name the colour matrix goes by as one control.
pub const colour_matrix_name = "cct";

/// Words in a gamma choice that mean gamma 1.0.
const linear_words = [_][]const u8{ "1.0", "linear" };
/// Words in a gamma choice that mean it takes the gamma tables.
const custom_words = [_][]const u8{ "user defined", "custom" };
/// Words in a colour correction choice that mean off.
const off_words = [_][]const u8{ "none", "off", "disable" };

/// Finds the options that raw setup sets on a scanner we have no profile for, and what it sets
/// each to by itself, in this order:
///
/// - The film setting, set to positive for raw (or negative when asked). It goes first, since a
///   backend may reset its colour settings when it changes.
/// - Gamma: SANE's `custom-gamma` switched on and its gamma tables filled with a straight line;
///   or a gamma choice that says 1.0 or linear; or one that takes your own table, and then the
///   tables. Tables with no switch, as on Nikon's Coolscans, are always on and get filled too. A
///   gamma number is set to 1.0.
/// - Colour correction off, or epkowa's colour matrix set to the identity.
/// - Brightness and contrast at 0, where 0 is the middle of their range.
///
/// A gamma choice or colour correction it can't pick a value for still gets a control, left as
/// it is, so the scanner settings can set it.
pub fn rawControls(options: []const OptionInfo) RawControls {
    var controls: RawControls = .{};

    for (options) |o| {
        if (o.kind != .string or !nameHas(o.name, "film")) continue;
        if (choiceWith(o.choices, &.{"positive"}) == null) continue;
        controls.add(o, .film, .film);
        break;
    }

    if (optionOf(options, custom_gamma, .bool)) |o| controls.add(o, .gamma_switch, .{ .number = 1 });
    const has_table = for (gamma_tables) |name| {
        if (optionOf(options, name, .table) != null) break true;
    } else false;
    for (options) |o| {
        if (o.kind != .string or !nameHas(o.name, "gamma")) continue;
        const auto: RawValue = auto: {
            if (choiceWith(o.choices, &linear_words)) |value| break :auto .{ .choose = value };
            if (has_table) if (choiceWith(o.choices, &custom_words)) |value| break :auto .{ .choose = value };
            break :auto .leave;
        };
        controls.add(o, .gamma_choice, auto);
        break;
    }
    for (gamma_tables) |name| if (optionOf(options, name, .table)) |o| {
        if (o.range != null) controls.add(o, .gamma_table, .straight);
    };
    for (gamma_numbers) |name| if (optionOf(options, name, .number)) |o| {
        if (inRange(o.range, 1)) controls.add(o, .gamma, .{ .number = 1 });
    };

    for (options) |o| {
        if (o.kind != .string or !isColourCorrection(o.name)) continue;
        controls.add(o, .colour_correction, if (choiceWith(o.choices, &off_words)) |value| .{ .choose = value } else .leave);
        break;
    }
    const has_matrix = for (colour_matrix) |name| {
        if (optionOf(options, name, .number) == null) break false;
    } else true;
    if (has_matrix) controls.add(.{ .name = colour_matrix_name, .kind = .matrix }, .colour_matrix, .straight);

    for ([_][]const u8{ "brightness", "contrast" }) |name| if (optionOf(options, name, .number)) |o| {
        const range = o.range orelse continue;
        if (range[0] < 0 and range[1] > 0) controls.add(o, .tone, .{ .number = 0 });
    };
    return controls;
}

/// What raw setup does on one scan: its settings in order, and how they leave the scanner.
pub const RawSetup = struct {
    buffer: [max_raw_controls]RawSetting = undefined,
    len: usize = 0,
    report: RawReport = .{},

    pub fn settings(setup: *const RawSetup) []const RawSetting {
        return setup.buffer[0..setup.len];
    }
};

/// Raw setup for a scanner with these `options`: what `rawControls` picks, with the user's
/// `changes` from the scanner settings in its place.
pub fn rawSetup(options: []const OptionInfo, changes: []const RawSetting) RawSetup {
    const controls = rawControls(options);
    var setup: RawSetup = .{};
    for (controls.all()) |control| {
        const value = valueOf(changes, control.option.name) orelse control.auto;
        if (value == .leave) continue;
        setup.buffer[setup.len] = .{ .name = control.option.name, .value = value };
        setup.len += 1;
    }
    setup.report = reportOf(controls.all(), setup.settings());
    return setup;
}

/// The value `settings` give the option `name`, if they give it one.
pub fn valueOf(settings: []const RawSetting, name: []const u8) ?RawValue {
    for (settings) |s| if (std.mem.eql(u8, s.name, name)) return s.value;
    return null;
}

/// How `settings` leave a scanner with these `controls`. The gamma tables only count when
/// they're on: switched on, turned on by the gamma choice, or always on when there's neither.
fn reportOf(controls: []const RawControl, settings: []const RawSetting) RawReport {
    var report: RawReport = .{};
    var switch_on: ?bool = null;
    var choice_takes_tables: ?bool = null;
    var straight_tables = false;
    for (controls) |control| {
        const value = valueOf(settings, control.option.name) orelse .leave;
        const choice = if (value == .choose) value.choose else "";
        switch (control.role) {
            .film => report.film = value != .leave,
            .gamma_switch => switch_on = value == .number and value.number != 0,
            .gamma_choice => {
                if (saysAny(choice, &linear_words)) report.linear = true;
                choice_takes_tables = saysAny(choice, &custom_words);
            },
            .gamma_table => if (value == .straight) {
                straight_tables = true;
            },
            .gamma => if (value == .number and value.number == 1) {
                report.linear = true;
            },
            .colour_correction => if (saysAny(choice, &off_words)) {
                report.colour_off = true;
            },
            .colour_matrix => if (value == .straight) {
                report.colour_off = true;
            },
            .tone => {},
        }
    }
    const tables_on = switch_on orelse choice_takes_tables orelse true;
    if (tables_on and straight_tables) report.linear = true;
    return report;
}

/// The film setting's value for `film` among `choices`: one that names positive or negative film,
/// preferring "film" over "slide".
pub fn filmChoice(choices: []const []const u8, film: Film) ?[]const u8 {
    const word = switch (film) {
        .positive => "positive",
        .negative => "negative",
    };
    for (choices) |choice| {
        if (containsIgnoreCase(choice, word) and containsIgnoreCase(choice, "film")) return choice;
    }
    return choiceWith(choices, &.{word});
}

/// The option called `name`, if it's there and of the type `kind`.
fn optionOf(options: []const OptionInfo, name: []const u8, kind: OptionInfo.Type) ?OptionInfo {
    for (options) |o| if (o.kind == kind and std.mem.eql(u8, o.name, name)) return o;
    return null;
}

/// The first of `choices` that contains any of `words`, ignoring case.
fn choiceWith(choices: []const []const u8, words: []const []const u8) ?[]const u8 {
    for (words) |word| for (choices) |choice| {
        if (containsIgnoreCase(choice, word)) return choice;
    };
    return null;
}

fn saysAny(text: []const u8, words: []const []const u8) bool {
    return choiceWith(&.{text}, words) != null;
}

fn nameHas(name: []const u8, word: []const u8) bool {
    return containsIgnoreCase(name, word);
}

/// Colour correction, such as epson2's `color-correction`. Not shading correction, which evens
/// out the lamp and has to stay on.
fn isColourCorrection(name: []const u8) bool {
    return nameHas(name, "correction") and (nameHas(name, "color") or nameHas(name, "colour")) and !nameHas(name, "gamma");
}

fn inRange(range: ?[2]f64, value: f64) bool {
    const r = range orelse return true;
    return r[0] <= value and value <= r[1];
}

/// The values a gamma table takes for a straight line: `entries` of them, evenly from the bottom
/// of `range` to its top.
pub fn straightTable(values: []f64, range: [2]f64) void {
    const last: f64 = @floatFromInt(@max(values.len, 2) - 1);
    for (values, 0..) |*v, i| v.* = range[0] + (range[1] - range[0]) * @as(f64, @floatFromInt(i)) / last;
}

/// A list of options or settings with the memory it lives in, for handing between threads.
pub fn Owned(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        items: []const T = &.{},

        pub fn deinit(owned: *@This()) void {
            owned.arena.deinit();
            owned.* = undefined;
        }
    };
}

/// Copies `settings` and their strings into memory of their own.
pub fn cloneSettings(gpa: std.mem.Allocator, settings: []const RawSetting) error{OutOfMemory}!Owned(RawSetting) {
    var owned: Owned(RawSetting) = .{ .arena = .init(gpa) };
    errdefer owned.arena.deinit();
    const a = owned.arena.allocator();
    const copy = try a.alloc(RawSetting, settings.len);
    for (copy, settings) |*to, from| to.* = .{ .name = try a.dupe(u8, from.name), .value = switch (from.value) {
        .choose => |v| .{ .choose = try a.dupe(u8, v) },
        else => from.value,
    } };
    owned.items = copy;
    return owned;
}

/// A loaded scanner library.
pub const Library = union(Kind) {
    sane: sane.Library,
    twain: twain.Library,

    /// Loads the platform's library. Returns `Error.Unavailable` when it isn't installed.
    pub fn load(gpa: std.mem.Allocator, io: std.Io) Error!Library {
        return switch (native) {
            .sane => .{ .sane = try sane.Library.load(gpa, io) },
            .twain => .{ .twain = try twain.Library.load() },
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

    pub fn close(scanner: *Scanner) void {
        switch (scanner.*) {
            inline else => |*s| s.close(),
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
    try std.testing.expectEqualStrings("film-type", v200.film.?.option);
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

test "resolutions from a driver are checked before they become numbers" {
    try std.testing.expectEqual(@as(?u32, 2400), resolutionOf(2400.2));
    try std.testing.expectEqual(@as(?u32, null), resolutionOf(-300));
    try std.testing.expectEqual(@as(?u32, null), resolutionOf(std.math.nan(f64)));
    try std.testing.expectEqual(@as(?u32, null), resolutionOf(1e12));
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

/// The value raw setup gives `name`, or null when it leaves it.
fn settingOf(setup: *const RawSetup, name: []const u8) ?RawValue {
    return valueOf(setup.settings(), name);
}

test "raw setup on an epkowa scanner picks what the V200's profile sets" {
    // epkowa's option names and values, as the V200 gives them (see its profile above).
    var options = [_]OptionInfo{
        .{ .name = "film-type", .kind = .string, .choices = &.{ "Positive Film", "Negative Film" } },
        .{ .name = "gamma-correction", .kind = .string, .choices = &.{ "Default", "User defined (Gamma=1.0)", "User defined (Gamma=1.8)" } },
    } ++ @as([colour_matrix.len]OptionInfo, @splat(.{ .name = undefined, .kind = .number }));
    for (options[2..], colour_matrix) |*o, name| o.name = name;
    const setup = rawSetup(&options, &.{});
    const settings = setup.settings();
    try std.testing.expectEqualStrings("film-type", settings[0].name);
    try std.testing.expectEqual(RawValue.film, settings[0].value);
    try std.testing.expectEqualStrings("User defined (Gamma=1.0)", settingOf(&setup, "gamma-correction").?.choose);
    // The matrix is set as one, to the identity, as the profile does.
    try std.testing.expectEqual(RawValue.straight, settingOf(&setup, colour_matrix_name).?);
    try std.testing.expect(setup.report.linear and setup.report.colour_off and setup.report.film);
    try std.testing.expectEqualStrings("Positive Film", filmChoice(options[0].choices, .positive).?);
    try std.testing.expectEqualStrings("Negative Film", filmChoice(options[0].choices, .negative).?);
}

test "raw setup on epson2 picks its gamma 1.0 and turns colour correction off" {
    // epson2's names and values, from the backend's own strings.
    const options = [_]OptionInfo{
        .{ .name = "film-type", .kind = .string, .choices = &.{ "Positive Film", "Negative Film", "Positive Slide", "Negative Slide" } },
        .{ .name = "gamma-correction", .kind = .string, .choices = &.{ "Default", "User defined (Gamma=1.0)", "User defined (Gamma=1.8)", "High density printing" } },
        .{ .name = "color-correction", .kind = .string, .choices = &.{ "None", "Default", "User defined CCT profile" } },
        .{ .name = "red-gamma-table", .kind = .table, .range = .{ 0, 255 } },
    };
    const setup = rawSetup(&options, &.{});
    try std.testing.expect(setup.report.linear and setup.report.colour_off);
    try std.testing.expectEqualStrings("User defined (Gamma=1.0)", settingOf(&setup, "gamma-correction").?.choose);
    try std.testing.expectEqualStrings("None", settingOf(&setup, "color-correction").?.choose);
    try std.testing.expectEqualStrings("Positive Film", filmChoice(options[0].choices, .positive).?);
}

test "raw setup switches on SANE's custom gamma and straightens its tables" {
    // The standard names (`saneopts.h`), as genesys, plustek and Canon's backends use them.
    const options = [_]OptionInfo{
        .{ .name = "custom-gamma", .kind = .bool },
        .{ .name = "gamma-table", .kind = .table, .range = .{ 0, 65535 } },
        .{ .name = "red-gamma-table", .kind = .table, .range = .{ 0, 65535 } },
        .{ .name = "brightness", .kind = .number, .range = .{ -100, 100 } },
        .{ .name = "contrast", .kind = .number, .range = .{ 0, 255 } },
    };
    const setup = rawSetup(&options, &.{});
    const settings = setup.settings();
    try std.testing.expectEqualStrings("custom-gamma", settings[0].name);
    try std.testing.expectEqual(@as(f64, 1), settings[0].value.number);
    try std.testing.expectEqual(RawValue.straight, settings[1].value);
    try std.testing.expectEqual(RawValue.straight, settings[2].value);
    // Brightness is centred on 0; contrast's 0 is an end, so it's left alone.
    try std.testing.expectEqualStrings("brightness", settings[3].name);
    try std.testing.expectEqual(@as(usize, 4), settings.len);
    try std.testing.expect(setup.report.linear and !setup.report.colour_off);

    var table: [5]f64 = undefined;
    straightTable(&table, .{ 0, 65535 });
    try std.testing.expectEqualSlices(f64, &.{ 0, 16383.75, 32767.5, 49151.25, 65535 }, &table);
}

test "raw setup fills tables that are always on, and says so when it can't help" {
    // Nikon's Coolscan backends have tables and no switch.
    const coolscan = [_]OptionInfo{.{ .name = "red-gamma-table", .kind = .table, .range = .{ 0, 4095 } }};
    try std.testing.expect(rawSetup(&coolscan, &.{}).report.linear);
    // A scanner with nothing to set.
    const plain = [_]OptionInfo{.{ .name = "resolution", .kind = .number, .range = .{ 75, 1200 } }};
    const nothing = rawSetup(&plain, &.{});
    try std.testing.expectEqual(@as(usize, 0), nothing.settings().len);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("No profile · data may not be linear", nothing.report.label(&buffer));
}

test "the scanner settings' changes take the place of what raw setup picks" {
    const options = [_]OptionInfo{
        .{ .name = "custom-gamma", .kind = .bool },
        .{ .name = "gamma-table", .kind = .table, .range = .{ 0, 255 } },
        .{ .name = "color-correction", .kind = .string, .choices = &.{ "Default", "Vivid" } },
        .{ .name = "shading-correction", .kind = .string, .choices = &.{ "On", "Off" } },
    };
    // No "off" among the colour choices, so raw setup leaves it, but it still has a control.
    // Shading correction evens out the lamp, so it isn't one.
    const controls = rawControls(&options);
    try std.testing.expectEqual(@as(usize, 3), controls.all().len);
    try std.testing.expectEqual(RawValue.leave, controls.all()[2].auto);

    // Switching custom gamma off leaves the straight tables doing nothing.
    const off = rawSetup(&options, &.{.{ .name = "custom-gamma", .value = .{ .number = 0 } }});
    try std.testing.expect(!off.report.linear);
    // Leaving the tables alone takes them out of the settings.
    const left = rawSetup(&options, &.{.{ .name = "gamma-table", .value = .leave }});
    try std.testing.expectEqual(@as(?RawValue, null), settingOf(&left, "gamma-table"));
    try std.testing.expect(!left.report.linear);
    // And a change can pick a value raw setup wouldn't.
    const vivid = rawSetup(&options, &.{.{ .name = "color-correction", .value = .{ .choose = "Vivid" } }});
    try std.testing.expectEqualStrings("Vivid", settingOf(&vivid, "color-correction").?.choose);
    try std.testing.expect(vivid.report.linear and !vivid.report.colour_off);
}

test "a gamma choice that takes your own table turns the tables on" {
    const options = [_]OptionInfo{
        .{ .name = "gamma-correction", .kind = .string, .choices = &.{ "Default", "Custom" } },
        .{ .name = "red-gamma-table", .kind = .table, .range = .{ 0, 255 } },
    };
    const auto = rawSetup(&options, &.{});
    try std.testing.expectEqualStrings("Custom", settingOf(&auto, "gamma-correction").?.choose);
    try std.testing.expect(auto.report.linear);
    const default = rawSetup(&options, &.{.{ .name = "gamma-correction", .value = .{ .choose = "Default" } }});
    try std.testing.expect(!default.report.linear);
}

test "raw values are the same when their kind and value are" {
    try std.testing.expect((RawValue{ .choose = "None" }).eql(.{ .choose = "None" }));
    try std.testing.expect(!(RawValue{ .choose = "None" }).eql(.{ .choose = "Default" }));
    try std.testing.expect(!(RawValue{ .number = 1 }).eql(.straight));
    try std.testing.expect((RawValue{ .leave = {} }).eql(.leave));
}

test "copied settings keep their strings" {
    const gpa = std.testing.allocator;
    var value = "Vivid".*;
    var copy = try cloneSettings(gpa, &.{.{ .name = "color-correction", .value = .{ .choose = &value } }});
    defer copy.deinit();
    value[0] = 'L';
    try std.testing.expectEqualStrings("Vivid", copy.items[0].value.choose);
}
