//! SANE, the scanner library on macOS and Linux. We load libsane at run time, so minilab doesn't
//! link it or need it. The macOS releases carry their own SANE in a `sane` folder next to the
//! program (`scripts/build-sane-macos.sh` builds it), and we try that first. Otherwise we load the
//! system's. SANE's configuration decides which backends load, and the V200 needs our epkowa build
//! enabled in the system's (the V200 driver's install notes cover this). The bundled SANE reads the
//! system's configuration and backends after its own, so that works with either.
//!
//! The declarations follow `sane.h` (SANE standard 1.0, public domain). We find options by name.
//! SANE's standard ones (`source`, `mode`, `depth`, `resolution`, `tl-x`, `tl-y`, `br-x`, `br-y`)
//! work with every backend, and a model's profile adds its own, such as epkowa's `film-type` and
//! `gamma-correction`.
//!
//! A scan is always read to the end. Calling `sane_cancel` in the middle of a scan leaves the V200
//! stuck until it's switched off (we found this during the V200 driver work), so this file never
//! calls it before the last line.

const std = @import("std");
const builtin = @import("builtin");
const interface = @import("root.zig");
const image = @import("../core/image.zig");

const Error = interface.Error;

/// Whether this platform can load libsane. Windows only has SANE under Cygwin.
pub const supported = switch (builtin.os.tag) {
    .macos, .linux, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => true,
    else => false,
};

/// Where the system's SANE is installed on a Mac, in the order we look: Homebrew on Apple silicon,
/// Homebrew on Intel, and MacPorts.
const mac_prefixes = [_][]const u8{ "/opt/homebrew", "/usr/local", "/opt/local" };

/// `suffix` under each of `mac_prefixes`.
fn underMacPrefixes(comptime suffix: []const u8) [mac_prefixes.len][:0]const u8 {
    var paths: [mac_prefixes.len][:0]const u8 = undefined;
    for (mac_prefixes, &paths) |prefix, *path| path.* = std.fmt.comptimePrint("{s}{s}", .{ prefix, suffix });
    return paths;
}

/// Where we look for the system's libsane, in order. The bare names go through the system's own
/// search.
pub const library_paths: []const [:0]const u8 = switch (builtin.os.tag) {
    .macos => &(underMacPrefixes("/lib/libsane.1.dylib") ++ .{"libsane.1.dylib"}),
    else => &.{ "libsane.so.1", "libsane.so" },
};

/// The SANE the macOS releases carry, in a folder next to the program. It has its backends and
/// configs in folders of their own.
const bundle = struct {
    const folder = "sane";
    const library = "libsane.1.dylib";
    const backends = "backends";
    const config = "sane.d";
};

/// The folder of the SANE that comes with minilab, written into `buffer`, or null when there isn't
/// one. Only the macOS releases have one.
fn bundledFolder(io: std.Io, buffer: []u8) ?[]const u8 {
    if (comptime builtin.os.tag != .macos) return null;
    const length = std.process.executableDirPath(io, buffer) catch return null;
    const name = "/" ++ bundle.folder;
    if (length + name.len > buffer.len) return null;
    @memcpy(buffer[length..][0..name.len], name);
    const folder = buffer[0 .. length + name.len];
    std.Io.Dir.cwd().access(io, folder, .{}) catch return null;
    return folder;
}

/// The C library's functions for changing the environment, which `std.c` doesn't have.
const libc = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

/// An environment variable we changed, and the value it had before.
const Changed = struct {
    name: [:0]const u8,
    old: ?[:0]u8,

    fn set(gpa: std.mem.Allocator, name: [:0]const u8, value: [:0]const u8) Error!Changed {
        const old = if (std.c.getenv(name)) |v| try gpa.dupeSentinel(u8, std.mem.span(v), 0) else null;
        errdefer if (old) |o| gpa.free(o);
        if (libc.setenv(name, value, 1) != 0) return error.Unavailable;
        return .{ .name = name, .old = old };
    }

    /// Puts the old value back.
    fn restore(changed: Changed) void {
        _ = if (changed.old) |o| libc.setenv(changed.name, o, 1) else libc.unsetenv(changed.name);
    }

    fn deinit(changed: Changed, gpa: std.mem.Allocator) void {
        if (changed.old) |o| gpa.free(o);
    }
};

/// Joins `own` and `system` under each of `mac_prefixes` into a search path, with `rest`, if
/// there is one, at the end.
fn searchPath(gpa: std.mem.Allocator, own: []const u8, comptime system: []const u8, rest: ?[]const u8) Error![:0]u8 {
    var parts: [mac_prefixes.len + 2][]const u8 = undefined;
    parts[0] = own;
    for (comptime underMacPrefixes(system), parts[1..][0..mac_prefixes.len]) |dir, *part| part.* = dir;
    var count: usize = mac_prefixes.len + 1;
    if (rest) |r| {
        parts[count] = r;
        count += 1;
    }
    return std.mem.joinZ(gpa, ":", parts[0..count]);
}

const Int = i32;
const Word = i32;
const Bool = Word;
const Handle = *anyopaque;

pub const Status = enum(c_int) {
    good = 0,
    unsupported = 1,
    cancelled = 2,
    device_busy = 3,
    inval = 4,
    eof = 5,
    jammed = 6,
    no_docs = 7,
    cover_open = 8,
    io_error = 9,
    no_mem = 10,
    access_denied = 11,
    _,
};

const ValueType = enum(c_int) { bool = 0, int = 1, fixed = 2, string = 3, button = 4, group = 5, _ };
const Unit = enum(c_int) { none = 0, pixel = 1, bit = 2, mm = 3, dpi = 4, percent = 5, microsecond = 6, _ };
const ConstraintType = enum(c_int) { none = 0, range = 1, word_list = 2, string_list = 3, _ };
const Action = enum(c_int) { get_value = 0, set_value = 1, set_auto = 2 };
const FrameFormat = enum(c_int) { gray = 0, rgb = 1, red = 2, green = 3, blue = 4, _ };

/// Option capability flags.
const cap_soft_select = 1 << 0;
const cap_inactive = 1 << 5;

const RawDevice = extern struct {
    name: [*:0]const u8,
    vendor: [*:0]const u8,
    model: [*:0]const u8,
    type: [*:0]const u8,
};

const Range = extern struct { min: Word, max: Word, quant: Word };

const OptionDescriptor = extern struct {
    name: ?[*:0]const u8,
    title: ?[*:0]const u8,
    desc: ?[*:0]const u8,
    type: ValueType,
    unit: Unit,
    size: Int,
    cap: Int,
    constraint_type: ConstraintType,
    constraint: extern union {
        string_list: [*]const ?[*:0]const u8,
        /// The first word says how many words follow.
        word_list: [*]const Word,
        range: *const Range,
    },

    fn active(option: *const OptionDescriptor) bool {
        return option.cap & cap_inactive == 0;
    }

    fn settable(option: *const OptionDescriptor) bool {
        return option.active() and option.cap & cap_soft_select != 0;
    }

    /// Returns the values of a word list, as words.
    fn words(option: *const OptionDescriptor) []const Word {
        if (option.constraint_type != .word_list) return &.{};
        const count: usize = @intCast(@max(option.constraint.word_list[0], 0));
        return option.constraint.word_list[1 .. count + 1];
    }

    /// Whether `value` is in the option's string list.
    fn allows(option: *const OptionDescriptor, value: []const u8) bool {
        if (option.constraint_type != .string_list) return true;
        var i: usize = 0;
        while (option.constraint.string_list[i]) |s| : (i += 1) {
            if (std.mem.eql(u8, std.mem.span(s), value)) return true;
        }
        return false;
    }

    /// Turns a word of the option's own type into a number.
    fn number(option: *const OptionDescriptor, raw: Word) f64 {
        return if (option.type == .fixed) unfix(raw) else @floatFromInt(raw);
    }

    /// Turns `value` into a word of the option's own type.
    fn word(option: *const OptionDescriptor, value: f64) Word {
        return if (option.type == .fixed) fix(value) else @intFromFloat(@round(value));
    }
};

const Parameters = extern struct {
    format: FrameFormat,
    last_frame: Bool,
    bytes_per_line: Int,
    pixels_per_line: Int,
    lines: Int,
    depth: Int,
};

/// SANE's fixed-point numbers have 16 bits of fraction.
const fixed_one = 1 << 16;

fn fix(value: f64) Word {
    return @intFromFloat(@round(value * fixed_one));
}

fn unfix(value: Word) f64 {
    return @as(f64, @floatFromInt(value)) / fixed_one;
}

/// libsane's functions.
const Api = struct {
    init: *const fn (version: ?*Int, authorize: ?*const anyopaque) callconv(.c) Status,
    exit: *const fn () callconv(.c) void,
    get_devices: *const fn (list: *?[*:null]const ?*const RawDevice, local_only: Bool) callconv(.c) Status,
    open: *const fn (name: [*:0]const u8, handle: *?Handle) callconv(.c) Status,
    close: *const fn (handle: Handle) callconv(.c) void,
    get_option_descriptor: *const fn (handle: Handle, option: Int) callconv(.c) ?*const OptionDescriptor,
    control_option: *const fn (handle: Handle, option: Int, action: Action, value: ?*anyopaque, info: ?*Int) callconv(.c) Status,
    get_parameters: *const fn (handle: Handle, parameters: *Parameters) callconv(.c) Status,
    start: *const fn (handle: Handle) callconv(.c) Status,
    read: *const fn (handle: Handle, data: [*]u8, max_length: Int, length: *Int) callconv(.c) Status,
    cancel: *const fn (handle: Handle) callconv(.c) void,
};

const DynLib = if (supported) std.DynLib else void;

/// libsane, loaded and initialised.
pub const Library = struct {
    dynlib: DynLib,
    api: Api,

    /// Loads the SANE that comes with minilab, or else the system's.
    pub fn load(gpa: std.mem.Allocator, io: std.Io) Error!Library {
        if (comptime !supported) {
            return error.Unavailable;
        } else {
            if (comptime builtin.os.tag == .macos) {
                if (loadBundled(gpa, io)) |library| return library else |_| {}
            }
            for (library_paths) |path| {
                var library = openAt(path) catch continue;
                library.initialise() catch {
                    library.dynlib.close();
                    continue;
                };
                return library;
            }
            return error.Unavailable;
        }
    }

    /// Loads the SANE in the folder next to the program. SANE reads where its files are from the
    /// environment when it starts, so we point it there first: at its own backends and configs,
    /// then at the system's. Backends installed into the system's SANE, like epkowa for the V200,
    /// still load that way. The dll backend searches `LD_LIBRARY_PATH` for backends on every
    /// system (macOS's own loader ignores it). A `SANE_CONFIG_DIR` of your own is left as it is.
    fn loadBundled(gpa: std.mem.Allocator, io: std.Io) Error!Library {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const folder = bundledFolder(io, &buffer) orelse return error.Unavailable;
        const path = try std.fs.path.joinZ(gpa, &.{ folder, bundle.library });
        defer gpa.free(path);
        var library = try openAt(path);
        errdefer library.dynlib.close();

        const backends_dir = try std.fs.path.join(gpa, &.{ folder, bundle.backends });
        defer gpa.free(backends_dir);
        const backends = try searchPath(gpa, backends_dir, "/lib/sane", if (std.c.getenv("LD_LIBRARY_PATH")) |p| std.mem.span(p) else null);
        defer gpa.free(backends);
        const search = try Changed.set(gpa, "LD_LIBRARY_PATH", backends);
        defer search.deinit(gpa);
        errdefer search.restore();

        var config: ?Changed = null;
        defer if (config) |changed| changed.deinit(gpa);
        errdefer if (config) |changed| changed.restore();
        if (std.c.getenv("SANE_CONFIG_DIR") == null) {
            const config_dir = try std.fs.path.join(gpa, &.{ folder, bundle.config });
            defer gpa.free(config_dir);
            const configs = try searchPath(gpa, config_dir, "/etc/sane.d", null);
            defer gpa.free(configs);
            config = try Changed.set(gpa, "SANE_CONFIG_DIR", configs);
        }

        try library.initialise();
        return library;
    }

    /// Opens the libsane at `path` and finds its functions.
    fn openAt(path: [:0]const u8) Error!Library {
        var dynlib = DynLib.openZ(path) catch return error.Unavailable;
        errdefer dynlib.close();
        var library: Library = .{ .dynlib = dynlib, .api = undefined };
        const fields = @typeInfo(Api).@"struct";
        inline for (fields.field_names, fields.field_types) |name, Type| {
            @field(library.api, name) = dynlib.lookup(Type, "sane_" ++ name) orelse return error.Unavailable;
        }
        return library;
    }

    /// Starts SANE up. It reads its configuration now.
    fn initialise(library: *Library) Error!void {
        var version: Int = 0;
        if (library.api.init(&version, null) != .good) return error.Unavailable;
    }

    /// Forgets SANE without shutting it down: it doesn't call `sane_exit` or close the library.
    /// SANE's backends (loaded by its own `dll` backend) and libusb register per-thread clean-up
    /// code, which runs when the scan thread exits. `sane_exit` unloads the backends and closing
    /// the library unloads SANE, and either one leaves that clean-up jumping into unloaded code.
    /// Devices are closed before this, and the rest is released when the process ends.
    pub fn unload(library: *Library) void {
        library.* = undefined;
    }

    /// Lists the devices SANE finds, both on this machine and through `net`.
    pub fn devices(library: *Library, gpa: std.mem.Allocator) Error![]interface.Device {
        var list: ?[*:null]const ?*const RawDevice = null;
        try check(library.api.get_devices(&list, 0));
        // SANE only keeps its list until the next call.
        var found: interface.DeviceList = .empty;
        errdefer found.deinit(gpa);
        const entries = list orelse return found.toOwnedSlice(gpa);
        var i: usize = 0;
        while (entries[i]) |raw| : (i += 1) {
            const name = std.mem.span(raw.name);
            const driver = name[0 .. std.mem.indexOfScalar(u8, name, ':') orelse name.len];
            try found.append(gpa, .{ .id = name, .vendor = std.mem.span(raw.vendor), .model = std.mem.span(raw.model), .driver = driver, .kind = .sane });
        }
        return found.toOwnedSlice(gpa);
    }

    pub fn open(library: *Library, gpa: std.mem.Allocator, device: interface.Device) Error!Scanner {
        const name = try gpa.dupeSentinel(u8, device.id, 0);
        defer gpa.free(name);
        var handle: ?Handle = null;
        try check(library.api.open(name, &handle));
        return .{
            .api = &library.api,
            .handle = handle orelse return error.Failed,
            .profile = interface.profileOf(device.driver, device.model),
        };
    }
};

/// An open SANE device.
pub const Scanner = struct {
    api: *const Api,
    handle: Handle,
    profile: ?*const interface.Profile,

    pub fn close(scanner: *Scanner, gpa: std.mem.Allocator) void {
        _ = gpa;
        scanner.api.close(scanner.handle);
        scanner.* = undefined;
    }

    const Found = struct { index: Int, option: *const OptionDescriptor };

    /// Finds the option called `name`, if the backend has it.
    fn find(scanner: *Scanner, name: []const u8) ?Found {
        var count: Word = 0;
        if (scanner.api.control_option(scanner.handle, 0, .get_value, &count, null) != .good) return null;
        var i: Int = 1;
        while (i < count) : (i += 1) {
            const option = scanner.api.get_option_descriptor(scanner.handle, i) orelse continue;
            const option_name = option.name orelse continue;
            if (std.mem.eql(u8, std.mem.span(option_name), name)) return .{ .index = i, .option = option };
        }
        return null;
    }

    /// Sets the string option `name` to `value`. Options the backend doesn't have, or that are
    /// inactive right now, are left alone, and it returns false.
    fn setString(scanner: *Scanner, name: []const u8, value: []const u8) Error!bool {
        const found = scanner.find(name) orelse return false;
        if (!found.option.settable() or found.option.type != .string or !found.option.allows(value)) return false;
        // The backend reads the option's whole size, so the buffer has to hold it.
        var buffer: [max_string]u8 = @splat(0);
        const size: usize = @intCast(@max(found.option.size, 0));
        if (size > buffer.len or value.len + 1 > size) return error.Unsupported;
        @memcpy(buffer[0..value.len], value);
        try check(scanner.api.control_option(scanner.handle, found.index, .set_value, &buffer, null));
        return true;
    }

    /// Reads the value of string option `name` into `buffer`.
    fn getString(scanner: *Scanner, name: []const u8, buffer: []u8) ?[]const u8 {
        const found = scanner.find(name) orelse return null;
        if (found.option.type != .string or found.option.size > buffer.len) return null;
        @memset(buffer, 0);
        if (scanner.api.control_option(scanner.handle, found.index, .get_value, buffer.ptr, null) != .good) return null;
        return std.mem.sliceTo(buffer, 0);
    }

    /// Sets the number option `name`, in the option's own unit. Returns false when the backend
    /// doesn't have it.
    fn setNumber(scanner: *Scanner, name: []const u8, value: f64) Error!bool {
        const found = scanner.find(name) orelse return false;
        if (!found.option.settable() or found.option.size != @sizeOf(Word)) return false;
        switch (found.option.type) {
            .int, .fixed, .bool => {},
            else => return false,
        }
        var word = found.option.word(value);
        try check(scanner.api.control_option(scanner.handle, found.index, .set_value, &word, null));
        return true;
    }

    fn getNumber(scanner: *Scanner, name: []const u8) ?f64 {
        const found = scanner.find(name) orelse return null;
        if (found.option.size != @sizeOf(Word)) return null;
        switch (found.option.type) {
            .int, .fixed, .bool => {},
            else => return null,
        }
        var word: Word = 0;
        if (scanner.api.control_option(scanner.handle, found.index, .get_value, &word, null) != .good) return null;
        return found.option.number(word);
    }

    /// Returns the range of number option `name`, from its range or its list of values.
    fn limits(scanner: *Scanner, name: []const u8) ?[2]f64 {
        const found = scanner.find(name) orelse return null;
        const option = found.option;
        return switch (option.constraint_type) {
            .range => .{ option.number(option.constraint.range.min), option.number(option.constraint.range.max) },
            .word_list => blk: {
                const words = option.words();
                if (words.len == 0) break :blk null;
                var low = option.number(words[0]);
                var high = low;
                for (words) |w| {
                    low = @min(low, option.number(w));
                    high = @max(high, option.number(w));
                }
                break :blk .{ low, high };
            },
            else => null,
        };
    }

    /// Switches to the first source of kind `source`. Returns false when there's no source
    /// option, or no source of that kind.
    fn selectSource(scanner: *Scanner, source: interface.Source) Error!bool {
        const found = scanner.find("source") orelse return false;
        if (found.option.constraint_type != .string_list) return false;
        var i: usize = 0;
        while (found.option.constraint.string_list[i]) |s| : (i += 1) {
            const name = std.mem.span(s);
            if (interface.Source.classify(name) == source) return scanner.setString("source", name);
        }
        return false;
    }

    pub fn capabilities(scanner: *Scanner, gpa: std.mem.Allocator, wanted: ?interface.Source) Error!interface.Capabilities {
        var sources: std.EnumSet(interface.Source) = .empty;
        var current: interface.Source = .flatbed;
        if (scanner.find("source")) |found| {
            if (found.option.constraint_type == .string_list) {
                var i: usize = 0;
                while (found.option.constraint.string_list[i]) |s| : (i += 1) {
                    if (interface.Source.classify(std.mem.span(s))) |kind| sources.insert(kind);
                }
            }
        }
        if (sources.count() == 0) sources.insert(.flatbed);
        if (wanted) |w| {
            if (!try scanner.selectSource(w) and w != .flatbed) return error.Unsupported;
        }
        var name_buffer: [max_string]u8 = undefined;
        if (scanner.getString("source", &name_buffer)) |name| current = interface.Source.classify(name) orelse .flatbed;

        var resolutions: std.ArrayList(u32) = .empty;
        errdefer resolutions.deinit(gpa);
        if (scanner.find("resolution")) |found| {
            const option = found.option;
            switch (option.constraint_type) {
                .word_list => for (option.words()) |w| {
                    try resolutions.append(gpa, @intFromFloat(@round(option.number(w))));
                },
                .range => try interface.appendResolutionsInRange(
                    gpa,
                    &resolutions,
                    option.number(option.constraint.range.min),
                    option.number(option.constraint.range.max),
                    option.number(option.constraint.range.quant),
                ),
                else => if (scanner.getNumber("resolution")) |r| try resolutions.append(gpa, @intFromFloat(@round(r))),
            }
        }
        std.mem.sortUnstable(u32, resolutions.items, {}, std.sort.asc(u32));

        return .{
            .sources = sources,
            .source = current,
            .resolutions = try resolutions.toOwnedSlice(gpa),
            .area = scanner.fullArea(),
            .deep = scanner.hasDeepColour(),
            .film_setting = scanner.hasFilmSetting(),
            .profile = scanner.profile,
        };
    }

    fn hasDeepColour(scanner: *Scanner) bool {
        const found = scanner.find("depth") orelse return false;
        return std.mem.indexOfScalar(Word, found.option.words(), 16) != null;
    }

    /// Whether the profile's film option is there and active for the current source.
    fn hasFilmSetting(scanner: *Scanner) bool {
        const profile = scanner.profile orelse return false;
        const found = scanner.find(profile.film_option orelse return false) orelse return false;
        return found.option.active();
    }

    /// The whole area of the current source, in mm.
    fn fullArea(scanner: *Scanner) interface.Area {
        const x = scanner.limits("tl-x") orelse .{ 0, 0 };
        const y = scanner.limits("tl-y") orelse .{ 0, 0 };
        const r = scanner.limits("br-x") orelse .{ 0, 0 };
        const b = scanner.limits("br-y") orelse .{ 0, 0 };
        return .{
            .x = @floatCast(x[0]),
            .y = @floatCast(y[0]),
            .width = @floatCast(r[1] - x[0]),
            .height = @floatCast(b[1] - y[0]),
        };
    }

    /// Sets the scanner up for `request`: the profile's options if there's a profile, and
    /// otherwise colour at the deepest bit depth the scanner has.
    fn prepare(scanner: *Scanner, request: interface.Request) Error!void {
        if (!try scanner.selectSource(request.source) and request.source != .flatbed) return error.Unsupported;
        if (scanner.profile) |profile| {
            // Set the film type first, because a backend may reset its colour settings when the
            // film type changes. scanimage uses the same order (film type, then the rest) for the
            // same reason.
            if (profile.film_option) |name| _ = try scanner.setString(name, switch (request.film) {
                .negative => profile.negative,
                .positive => profile.positive,
            });
            for (profile.options) |setting| {
                const set = switch (setting.value) {
                    .string => |v| try scanner.setString(setting.name, v),
                    .int => |n| try scanner.setNumber(setting.name, @floatFromInt(n)),
                };
                // The scan goes ahead, but it may not be raw. That's worth knowing if its colours
                // look off.
                if (!set) std.log.warn("the scanner didn't take {s} from its profile", .{setting.name});
            }
        } else {
            _ = try scanner.setString("mode", "Color");
        }
        _ = try scanner.setNumber("depth", if (request.deep) 16 else 8);
        if (!try scanner.setNumber("resolution", @floatFromInt(request.dpi))) return error.Unsupported;

        // Now the area. Move the far corner out of the way first, so the near corner can go
        // anywhere.
        const full = scanner.fullArea();
        const area = if (request.area) |a| a.clip(full) orelse return error.Unsupported else full;
        _ = try scanner.setNumber("br-x", full.right());
        _ = try scanner.setNumber("br-y", full.bottom());
        _ = try scanner.setNumber("tl-x", area.x);
        _ = try scanner.setNumber("tl-y", area.y);
        _ = try scanner.setNumber("br-x", area.right());
        _ = try scanner.setNumber("br-y", area.bottom());
    }

    /// The area the scanner will use, after rounding.
    fn usedArea(scanner: *Scanner) interface.Area {
        const full = scanner.fullArea();
        const x: f32 = @floatCast(scanner.getNumber("tl-x") orelse full.x);
        const y: f32 = @floatCast(scanner.getNumber("tl-y") orelse full.y);
        const r: f32 = @floatCast(scanner.getNumber("br-x") orelse full.right());
        const b: f32 = @floatCast(scanner.getNumber("br-y") orelse full.bottom());
        return .{ .x = x, .y = y, .width = r - x, .height = b - y };
    }

    pub fn scan(scanner: *Scanner, gpa: std.mem.Allocator, request: interface.Request, progress: *interface.Progress) Error!interface.Image {
        progress.reset();
        try scanner.prepare(request);
        const area = scanner.usedArea();
        const dpi: f32 = @floatCast(scanner.getNumber("resolution") orelse @as(f64, @floatFromInt(request.dpi)));
        const x_dpi: f32 = @floatCast(scanner.getNumber("x-resolution") orelse dpi);
        const y_dpi: f32 = @floatCast(scanner.getNumber("y-resolution") orelse dpi);

        var pixels: std.ArrayList([3]u16) = .empty;
        defer pixels.deinit(gpa);
        var width: usize = 0;
        var depth: u8 = 8;
        var rows: usize = 0;
        // Three-pass scanners send red, green and blue as separate frames.
        var frame: usize = 0;
        while (true) : (frame += 1) {
            try check(scanner.api.start(scanner.handle));
            var parameters: Parameters = undefined;
            try scanner.checkOrFinish(scanner.api.get_parameters(scanner.handle, &parameters));
            const layout = Layout.of(parameters) catch |err| {
                scanner.finish();
                return err;
            };
            if (frame == 0) {
                width = layout.width;
                depth = layout.depth;
                if (parameters.lines > 0) pixels.ensureTotalCapacity(gpa, width * @as(usize, @intCast(parameters.lines))) catch |err| {
                    scanner.finish();
                    return err;
                };
            } else if (layout.width != width) {
                scanner.finish();
                return error.Failed;
            }
            const lines: u32 = @intCast(@max(parameters.lines, 0));
            if (frame == 0) progress.total.store(lines * @as(u32, if (layout.channel == null) 1 else 3), .release);
            const read = try scanner.readFrame(gpa, parameters, layout, &pixels, progress);
            if (frame == 0) rows = read;
            if (parameters.last_frame != 0 or frame == 2) break;
        }
        // After the last frame, `sane_cancel` puts the backend back to idle.
        scanner.api.cancel(scanner.handle);

        if (rows == 0 or width == 0) return error.Failed;
        pixels.shrinkRetainingCapacity(rows * width);
        return .{
            .width = width,
            .height = rows,
            .pixels = try pixels.toOwnedSlice(gpa),
            .depth = depth,
            .dpi = .{ x_dpi, y_dpi },
            .area = area,
        };
    }

    /// Reads one frame to the end into `pixels`, and returns how many lines it had.
    fn readFrame(scanner: *Scanner, gpa: std.mem.Allocator, parameters: Parameters, layout: Layout, pixels: *std.ArrayList([3]u16), progress: *interface.Progress) Error!usize {
        const line_bytes: usize = @intCast(parameters.bytes_per_line);
        const line = try gpa.alloc(u8, line_bytes);
        defer gpa.free(line);
        var buffer: [read_size]u8 = undefined;
        var filled: usize = 0;
        var row: usize = 0;
        // After an error we still read the rest of the scan, so the scanner ends up idle.
        var failure: ?Error = null;
        while (true) {
            var length: Int = 0;
            const status = scanner.api.read(scanner.handle, &buffer, buffer.len, &length);
            switch (status) {
                .good => {},
                .eof => break,
                else => {
                    scanner.api.cancel(scanner.handle);
                    return failure orelse errorOf(status);
                },
            }
            // If a backend claims it sent more than the buffer holds, cut it down to the buffer.
            var chunk = buffer[0..@min(@as(usize, @intCast(@max(length, 0))), buffer.len)];
            while (chunk.len > 0) {
                const take = @min(chunk.len, line_bytes - filled);
                @memcpy(line[filled..][0..take], chunk[0..take]);
                filled += take;
                chunk = chunk[take..];
                if (filled < line_bytes) continue;
                filled = 0;
                if (failure == null) layout.decode(gpa, line, row, pixels) catch |err| {
                    failure = err;
                };
                row += 1;
                _ = progress.lines.fetchAdd(1, .acq_rel);
            }
        }
        if (failure) |err| {
            scanner.api.cancel(scanner.handle);
            return err;
        }
        return row;
    }

    /// Ends a scan that failed before sending its data, which puts the backend back to idle.
    fn finish(scanner: *Scanner) void {
        scanner.api.cancel(scanner.handle);
    }

    fn checkOrFinish(scanner: *Scanner, status: Status) Error!void {
        check(status) catch |err| {
            scanner.finish();
            return err;
        };
    }
};

/// The longest string option value we handle.
const max_string = 1024;

/// How many bytes we ask `sane_read` for at a time.
const read_size = 64 * 1024;

/// How the samples are laid out in a frame's lines.
const Layout = struct {
    width: usize,
    depth: u8,
    /// Gray data fills all three channels.
    gray: bool,
    /// For three-pass frames, the one channel this frame holds.
    channel: ?usize,

    fn of(parameters: Parameters) Error!Layout {
        if (parameters.depth != 8 and parameters.depth != 16) return error.Unsupported;
        if (parameters.pixels_per_line <= 0) return error.Failed;
        const width: usize = @intCast(parameters.pixels_per_line);
        const channels: usize = switch (parameters.format) {
            .rgb => 3,
            .gray, .red, .green, .blue => 1,
            _ => return error.Unsupported,
        };
        if (parameters.bytes_per_line < width * channels * @as(usize, @intCast(@divExact(parameters.depth, 8)))) return error.Failed;
        return .{
            .width = width,
            .depth = @intCast(parameters.depth),
            .gray = parameters.format == .gray,
            .channel = switch (parameters.format) {
                .red => 0,
                .green => 1,
                .blue => 2,
                else => null,
            },
        };
    }

    /// Returns the sample at `index` in a line, scaled to 16 bits. SANE sends 16-bit samples in
    /// the machine's own byte order.
    fn sample(layout: Layout, line: []const u8, index: usize) u16 {
        if (layout.depth == 8) return @as(u16, line[index]) * image.widen_8_to_16;
        return std.mem.readInt(u16, line[index * 2 ..][0..2], builtin.cpu.arch.endian());
    }

    /// Decodes line `row` into `pixels`. The first pass appends the pixels, and the other passes
    /// fill in their own channel.
    fn decode(layout: Layout, gpa: std.mem.Allocator, line: []const u8, row: usize, pixels: *std.ArrayList([3]u16)) !void {
        if (layout.channel) |channel| {
            if (channel == 0 or pixels.items.len < (row + 1) * layout.width) {
                for (0..layout.width) |x| {
                    var p: [3]u16 = @splat(0);
                    p[channel] = layout.sample(line, x);
                    try pixels.append(gpa, p);
                }
            } else {
                for (pixels.items[row * layout.width ..][0..layout.width], 0..) |*p, x| p[channel] = layout.sample(line, x);
            }
            return;
        }
        try pixels.ensureUnusedCapacity(gpa, layout.width);
        for (0..layout.width) |x| {
            const p: [3]u16 = if (layout.gray) @splat(layout.sample(line, x)) else .{ layout.sample(line, x * 3), layout.sample(line, x * 3 + 1), layout.sample(line, x * 3 + 2) };
            pixels.appendAssumeCapacity(p);
        }
    }
};

fn check(status: Status) Error!void {
    if (status != .good) return errorOf(status);
}

fn errorOf(status: Status) Error {
    return switch (status) {
        .good, .eof => error.Failed,
        .unsupported, .inval => error.Unsupported,
        .device_busy => error.Busy,
        .jammed => error.Jammed,
        .no_docs => error.NoDocument,
        .cover_open => error.CoverOpen,
        .access_denied => error.AccessDenied,
        .no_mem => error.OutOfMemory,
        .cancelled, .io_error, _ => error.Failed,
    };
}

test "the bundled SANE looks in its own folders first, then the system's" {
    const gpa = std.testing.allocator;
    const backends = try searchPath(gpa, "/Apps/minilab/sane/backends", "/lib/sane", "/mine");
    defer gpa.free(backends);
    try std.testing.expectEqualStrings("/Apps/minilab/sane/backends:/opt/homebrew/lib/sane:/usr/local/lib/sane:/opt/local/lib/sane:/mine", backends);
    const configs = try searchPath(gpa, "/Apps/minilab/sane/sane.d", "/etc/sane.d", null);
    defer gpa.free(configs);
    try std.testing.expectEqualStrings("/Apps/minilab/sane/sane.d:/opt/homebrew/etc/sane.d:/usr/local/etc/sane.d:/opt/local/etc/sane.d", configs);
}

test "an environment variable we change goes back to what it was" {
    if (comptime builtin.os.tag != .macos) {
        return error.SkipZigTest;
    } else {
        const gpa = std.testing.allocator;
        const name = "MINILAB_SANE_TEST";
        const first = try Changed.set(gpa, name, "first");
        defer first.deinit(gpa);
        const second = try Changed.set(gpa, name, "second");
        defer second.deinit(gpa);
        try std.testing.expectEqualStrings("second", std.mem.span(std.c.getenv(name).?));
        second.restore();
        try std.testing.expectEqualStrings("first", std.mem.span(std.c.getenv(name).?));
        first.restore();
        try std.testing.expect(std.c.getenv(name) == null);
    }
}

test "fixed-point numbers" {
    try std.testing.expectEqual(@as(Word, @intFromFloat(@round(33.02 * fixed_one))), fix(33.02));
    try std.testing.expectApproxEqAbs(@as(f64, 244.348), unfix(fix(244.348)), 1e-4);
}

test "lines decode at 8 and 16 bits, colour and grey" {
    const gpa = std.testing.allocator;
    var pixels: std.ArrayList([3]u16) = .empty;
    defer pixels.deinit(gpa);

    const rgb16: Layout = .{ .width = 1, .depth = 16, .gray = false, .channel = null };
    var line16: [6]u8 = undefined;
    for (0..3) |i| std.mem.writeInt(u16, line16[i * 2 ..][0..2], @intCast(1000 * (i + 1)), builtin.cpu.arch.endian());
    try rgb16.decode(gpa, &line16, 0, &pixels);
    try std.testing.expectEqual([3]u16{ 1000, 2000, 3000 }, pixels.items[0]);

    const gray8: Layout = .{ .width = 2, .depth = 8, .gray = true, .channel = null };
    try gray8.decode(gpa, &.{ 0, 255 }, 1, &pixels);
    try std.testing.expectEqual([3]u16{ 0, 0, 0 }, pixels.items[1]);
    try std.testing.expectEqual([3]u16{ 65535, 65535, 65535 }, pixels.items[2]);
}

test "three-pass frames fill one channel each" {
    const gpa = std.testing.allocator;
    var pixels: std.ArrayList([3]u16) = .empty;
    defer pixels.deinit(gpa);
    for ([_]usize{ 0, 1, 2 }) |channel| {
        const layout: Layout = .{ .width = 1, .depth = 8, .gray = false, .channel = channel };
        try layout.decode(gpa, &.{@intCast(channel + 1)}, 0, &pixels);
    }
    try std.testing.expectEqual(@as(usize, 1), pixels.items.len);
    try std.testing.expectEqual([3]u16{ 1 * image.widen_8_to_16, 2 * image.widen_8_to_16, 3 * image.widen_8_to_16 }, pixels.items[0]);
}

test "SANE's test backend scans, where libsane is installed" {
    if (comptime !supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var library = Library.load(gpa, std.testing.io) catch return error.SkipZigTest;
    defer library.unload();
    const device: interface.Device = .{ .id = "test", .vendor = "Noname", .model = "frontend-tester", .driver = "test", .kind = .sane };
    var scanner = library.open(gpa, device) catch return error.SkipZigTest;
    defer scanner.close(gpa);
    var capabilities = try scanner.capabilities(gpa, null);
    defer capabilities.deinit(gpa);
    try std.testing.expect(capabilities.resolutions.len > 0);
    try std.testing.expect(capabilities.area.width > 0);
    var progress: interface.Progress = .{};
    var picture = try scanner.scan(gpa, .{ .source = capabilities.source, .dpi = 25, .area = .{ .x = 0, .y = 0, .width = 20, .height = 10 } }, &progress);
    defer picture.deinit(gpa);
    try std.testing.expect(picture.width > 0 and picture.height > 0);
    try std.testing.expectEqual(picture.width * picture.height, picture.pixels.len);
    try std.testing.expectEqual(@as(u32, @intCast(picture.height)), progress.lines.load(.acquire));
}

test "every function compiles, on every platform" {
    std.testing.refAllDecls(Library);
    std.testing.refAllDecls(Scanner);
}
