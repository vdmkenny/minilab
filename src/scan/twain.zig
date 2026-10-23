//! TWAIN, the scanner interface on Windows. We go through the TWAIN 2 data source manager
//! (`TWAINDSM.dll`), which is loaded at run time like the scanner libraries on the other
//! platforms. Every call goes through the manager's single entry point, `DSM_Entry`.
//!
//! **Untested.** This file was written from the TWAIN 2.4 specification without a Windows machine
//! or a TWAIN source to try it on. It compiles for x86_64-windows-gnu, and the sizes of its
//! structures are checked against the specification's packing below, but none of it has run. In
//! particular:
//!
//! - we don't know which capabilities Epson's V200 source (Epson Scan) supports without showing
//!   its own window, or whether it gives linear 48-bit data (design section 5);
//! - we wait for the source's "transfer ready" through both a registered callback and a message
//!   loop on a hidden window, because sources differ in which one they use. Neither has been
//!   tried;
//! - we assume 16-bit samples are little-endian and the data is chunky (RGBRGB…), which the
//!   specification leaves up to the source. Planar data is refused;
//! - areas and resolutions are in inches, so a source that ignores `ICAP_UNITS` would scan the
//!   wrong area.
//!
//! The declarations are written from the specification, because `twain.h` comes with no licence.
//! On Windows, TWAIN packs its structures to 2 bytes, and the `align(2)` fields reproduce that.
//!
//! TWAIN ties a session to the thread that opened it, so load the library, and make every call,
//! on the scan thread.

const std = @import("std");
const builtin = @import("builtin");
const interface = @import("root.zig");
const image = @import("../core/image.zig");
const formats = @import("../frames/formats.zig");

const Error = interface.Error;

pub const supported = builtin.os.tag == .windows;

/// The data source manager. TWAIN 2 uses the same name for 32-bit and 64-bit programs.
pub const manager_name = "TWAINDSM.dll";

const callconv_twain: std.builtin.CallingConvention = if (supported) .winapi else .c;

// The specification's types, as Windows sizes them.
const Handle = *anyopaque;

const Fix32 = extern struct {
    whole: i16,
    frac: u16,

    fn of(number: f64) Fix32 {
        const scaled: i32 = @intFromFloat(@round(number * 65536));
        return .{ .whole = @intCast(scaled >> 16), .frac = @truncate(@as(u32, @bitCast(scaled))) };
    }

    fn value(fix: Fix32) f64 {
        return @as(f64, @floatFromInt(fix.whole)) + @as(f64, @floatFromInt(fix.frac)) / 65536;
    }

    fn bits(fix: Fix32) u32 {
        return @as(u32, @as(u16, @bitCast(fix.whole))) | @as(u32, fix.frac) << 16;
    }

    fn fromBits(raw: u32) Fix32 {
        return .{ .whole = @bitCast(@as(u16, @truncate(raw))), .frac = @truncate(raw >> 16) };
    }
};

const Frame = extern struct { left: Fix32, top: Fix32, right: Fix32, bottom: Fix32 };

const Str32 = [34]u8;

const Version = extern struct {
    major: u16,
    minor: u16,
    language: u16,
    country: u16,
    info: Str32,
};

const Identity = extern struct {
    id: u32 align(2),
    version: Version,
    protocol_major: u16,
    protocol_minor: u16,
    supported_groups: u32 align(2),
    manufacturer: Str32,
    product_family: Str32,
    product_name: Str32,
};

const UserInterface = extern struct {
    show_ui: u16,
    modal_ui: u16,
    parent: ?Handle align(2),
};

const Capability = extern struct {
    cap: u16,
    container_type: u16,
    container: ?Handle align(2),
};

const ImageInfo = extern struct {
    x_resolution: Fix32,
    y_resolution: Fix32,
    width: i32 align(2),
    length: i32 align(2),
    samples_per_pixel: i16,
    bits_per_sample: [8]i16,
    bits_per_pixel: i16,
    planar: u16,
    pixel_type: i16,
    compression: u16,
};

const ImageLayout = extern struct {
    frame: Frame,
    document_number: u32 align(2),
    page_number: u32 align(2),
    frame_number: u32 align(2),
};

const SetupMemXfer = extern struct {
    min_buffer: u32 align(2),
    max_buffer: u32 align(2),
    preferred: u32 align(2),
};

const Memory = extern struct {
    flags: u32 align(2),
    length: u32 align(2),
    data: ?*anyopaque align(2),
};

const ImageMemXfer = extern struct {
    compression: u16,
    bytes_per_row: u32 align(2),
    columns: u32 align(2),
    rows: u32 align(2),
    x_offset: u32 align(2),
    y_offset: u32 align(2),
    bytes_written: u32 align(2),
    memory: Memory align(2),
};

const PendingXfers = extern struct {
    count: u16,
    end_of_job: u32 align(2),
};

const Status = extern struct {
    condition: u16,
    data: u16,
};

const Event = extern struct {
    event: ?*anyopaque align(2),
    message: u16,
};

const Callback = extern struct {
    proc: ?*const anyopaque align(2),
    reference: u32 align(2),
    message: i16,
};

const EntryFn = *const fn (origin: ?*Identity, destination: ?*Identity, group: u32, data_type: u16, message: u16, data: ?*anyopaque) callconv(callconv_twain) u16;

const EntryPoint = extern struct {
    size: u32 align(2),
    entry: ?EntryFn align(2),
    allocate: ?*const fn (size: u32) callconv(callconv_twain) ?Handle align(2),
    free: ?*const fn (handle: Handle) callconv(callconv_twain) void align(2),
    lock: ?*const fn (handle: Handle) callconv(callconv_twain) ?*anyopaque align(2),
    unlock: ?*const fn (handle: Handle) callconv(callconv_twain) void align(2),
};

comptime {
    // The sizes that the specification's 2-byte packing gives on 64-bit Windows.
    if (supported and @sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(Identity) == 156);
        std.debug.assert(@sizeOf(UserInterface) == 12);
        std.debug.assert(@sizeOf(Capability) == 12);
        std.debug.assert(@sizeOf(ImageInfo) == 42);
        std.debug.assert(@sizeOf(ImageLayout) == 28);
        std.debug.assert(@sizeOf(ImageMemXfer) == 42);
        std.debug.assert(@sizeOf(PendingXfers) == 6);
        std.debug.assert(@sizeOf(Event) == 10);
        std.debug.assert(@sizeOf(EntryPoint) == 44);
    }
}

// Data groups, data types, messages and return codes.
/// The largest memory transfer buffer we accept from a source. That's far more than any band of
/// rows needs.
const max_transfer_bytes = 256 << 20;

const dg_control = 0x0001;
const dg_image = 0x0002;
const df_app2 = 0x10000000;
const df_dsm2 = 0x20000000;
const df_ds2 = 0x40000000;

const dat_capability = 0x0001;
const dat_event = 0x0002;
const dat_identity = 0x0003;
const dat_parent = 0x0004;
const dat_pendingxfers = 0x0005;
const dat_setupmemxfer = 0x0006;
const dat_status = 0x0008;
const dat_userinterface = 0x0009;
const dat_callback = 0x0010;
const dat_entrypoint = 0x0403;
const dat_imageinfo = 0x0101;
const dat_imagelayout = 0x0102;
const dat_imagememxfer = 0x0103;

const msg_get = 0x0001;
const msg_getfirst = 0x0004;
const msg_getnext = 0x0005;
const msg_set = 0x0006;
const msg_reset = 0x0007;
const msg_xferready = 0x0101;
const msg_closedsreq = 0x0102;
const msg_closedsok = 0x0103;
const msg_opendsm = 0x0301;
const msg_closedsm = 0x0302;
const msg_opends = 0x0401;
const msg_closeds = 0x0402;
const msg_disableds = 0x0501;
const msg_enableds = 0x0502;
const msg_processevent = 0x0601;
const msg_endxfer = 0x0701;
const msg_register_callback = 0x0902;

const rc_success = 0;
const rc_failure = 1;
const rc_checkstatus = 2;
const rc_cancel = 3;
const rc_dsevent = 4;
const rc_xferdone = 6;
const rc_endoflist = 7;

const cc_lowmemory = 2;
const cc_nods = 3;
const cc_maxconnections = 4;
const cc_badcap = 6;
const cc_badvalue = 10;
const cc_capunsupported = 13;
const cc_paperjam = 20;
const cc_denied = 21;

// Containers and their item types.
const on_array = 3;
const on_enumeration = 4;
const on_onevalue = 5;
const on_range = 6;
const on_dontcare = 0xffff;

const ty_int8 = 0;
const ty_int16 = 1;
const ty_int32 = 2;
const ty_uint8 = 3;
const ty_uint16 = 4;
const ty_uint32 = 5;
const ty_bool = 6;
const ty_fix32 = 7;

// Where the containers' fields are, in bytes from the start. Each container starts with its item
// type, and a field holding a value, a count or an index takes 4 bytes, whatever the item type.
const item_type_at = 0;
const field_bytes = 4;
const one_value_at = 2;
const one_value_bytes = one_value_at + field_bytes;
const range_min_at = 2;
const range_max_at = 6;
const range_step_at = 10;
const range_current_at = 18;
const list_count_at = 2;
const enumeration_current_at = 6;
const enumeration_items_at = 14;
const array_items_at = 6;

// Capabilities and their values.
const cap_xfercount = 0x0001;
const icap_pixeltype = 0x0101;
const icap_units = 0x0102;
const icap_xfermech = 0x0103;
const icap_lightpath = 0x1105;
const icap_gamma = 0x1108;
const icap_physicalwidth = 0x1111;
const icap_physicalheight = 0x1112;
const icap_xresolution = 0x1118;
const icap_yresolution = 0x1119;
const icap_bitdepth = 0x112b;
const icap_filmtype = 0x1169;

const pt_gray = 1;
const pt_rgb = 2;
const un_inches = 0;
const sx_memory = 2;
const lp_reflective = 0;
const lp_transmissive = 1;
const fm_positive = 0;
const fm_negative = 1;
/// The application owns the transfer buffer, and passes it as a pointer.
const mf_appowns = 0x0001;
const mf_pointer = 0x0008;

const lg_usa = 13;
const cy_usa = 1;

/// How long a source can take to say its image is ready. Lamps need to warm up, and a source that
/// shows its own window waits for the user.
const ready_timeout_ms = 10 * 60 * 1000;
const poll_ms = 10;

/// Windows' own functions, declared only where they exist.
const win = struct {
    const Msg = extern struct {
        window: ?Handle,
        message: u32,
        wparam: usize,
        lparam: isize,
        time: u32,
        point: extern struct { x: i32, y: i32 },
        private: u32,
    };
    const gmem_moveable = 0x0002;
    const gmem_zeroinit = 0x0040;
    const pm_remove = 0x0001;
    /// The parent of message-only windows.
    const hwnd_message: Handle = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));

    extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(callconv_twain) ?Handle;
    extern "kernel32" fn GetProcAddress(module: Handle, name: [*:0]const u8) callconv(callconv_twain) ?*const anyopaque;
    extern "kernel32" fn FreeLibrary(module: Handle) callconv(callconv_twain) i32;
    extern "kernel32" fn GlobalAlloc(flags: u32, bytes: usize) callconv(callconv_twain) ?Handle;
    extern "kernel32" fn GlobalLock(memory: Handle) callconv(callconv_twain) ?*anyopaque;
    extern "kernel32" fn GlobalUnlock(memory: Handle) callconv(callconv_twain) i32;
    extern "kernel32" fn GlobalFree(memory: Handle) callconv(callconv_twain) ?Handle;
    extern "kernel32" fn Sleep(milliseconds: u32) callconv(callconv_twain) void;
    extern "kernel32" fn GetTickCount64() callconv(callconv_twain) u64;
    extern "user32" fn CreateWindowExW(ex_style: u32, class: [*:0]const u16, name: [*:0]const u16, style: u32, x: i32, y: i32, width: i32, height: i32, parent: ?Handle, menu: ?Handle, instance: ?Handle, parameter: ?*anyopaque) callconv(callconv_twain) ?Handle;
    extern "user32" fn DestroyWindow(window: Handle) callconv(callconv_twain) i32;
    extern "user32" fn PeekMessageW(msg: *Msg, window: ?Handle, first: u32, last: u32, remove: u32) callconv(callconv_twain) i32;
    extern "user32" fn TranslateMessage(msg: *const Msg) callconv(callconv_twain) i32;
    extern "user32" fn DispatchMessageW(msg: *const Msg) callconv(callconv_twain) isize;
};

/// What the source last told us through the callback: 0, or a message such as `msg_xferready`.
/// One scan thread holds one session, so a single value is enough.
var callback_message: std.atomic.Value(u16) = .init(0);

fn sourceCallback(origin: ?*Identity, destination: ?*Identity, group: u32, data_type: u16, message: u16, data: ?*anyopaque) callconv(callconv_twain) u16 {
    _ = .{ origin, destination, group, data_type, data };
    callback_message.store(message, .release);
    return rc_success;
}

fn str32(value: []const u8) Str32 {
    var out: Str32 = @splat(0);
    const n = @min(value.len, out.len - 1);
    @memcpy(out[0..n], value[0..n]);
    return out;
}

fn span32(value: *const Str32) []const u8 {
    return std.mem.sliceTo(value, 0);
}

/// The open data source manager.
pub const Library = struct {
    module: Handle,
    entry: EntryFn,
    /// A hidden window. The manager wants a parent window, and sources post their messages to its
    /// thread.
    window: Handle,
    app: Identity,
    /// TWAIN 2's memory functions, which sources expect us to use for containers. With a TWAIN 1
    /// manager we use Windows' global memory instead.
    memory: EntryPoint,

    pub fn load() Error!Library {
        if (comptime !supported) return error.Unavailable;
        const module = win.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral(manager_name)) orelse return error.Unavailable;
        errdefer _ = win.FreeLibrary(module);
        // GetProcAddress returns an untyped pointer, and on Arm64 a function pointer has to be
        // 4-byte aligned, so the cast needs the alignment asserted too.
        const entry: EntryFn = @ptrCast(@alignCast(win.GetProcAddress(module, "DSM_Entry") orelse return error.Unavailable));
        const window = win.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral("minilab"), 0, 0, 0, 0, 0, win.hwnd_message, null, null, null) orelse return error.Unavailable;
        errdefer _ = win.DestroyWindow(window);

        var library: Library = .{
            .module = module,
            .entry = entry,
            .window = window,
            .app = .{
                .id = 0,
                .version = .{ .major = 0, .minor = 1, .language = lg_usa, .country = cy_usa, .info = str32("minilab") },
                .protocol_major = 2,
                .protocol_minor = 4,
                .supported_groups = dg_control | dg_image | df_app2,
                .manufacturer = str32("minilab"),
                .product_family = str32("minilab"),
                .product_name = str32("minilab"),
            },
            .memory = .{ .size = @sizeOf(EntryPoint), .entry = null, .allocate = null, .free = null, .lock = null, .unlock = null },
        };
        var parent: ?Handle = window;
        if (entry(&library.app, null, dg_control, dat_parent, msg_opendsm, @ptrCast(&parent)) != rc_success) return error.Unavailable;
        if (library.app.supported_groups & df_dsm2 != 0) {
            if (entry(&library.app, null, dg_control, dat_entrypoint, msg_get, @ptrCast(&library.memory)) != rc_success) library.memory.allocate = null;
        }
        return library;
    }

    pub fn unload(library: *Library) void {
        if (comptime !supported) unreachable;
        var parent: ?Handle = library.window;
        _ = library.entry(&library.app, null, dg_control, dat_parent, msg_closedsm, @ptrCast(&parent));
        _ = win.DestroyWindow(library.window);
        _ = win.FreeLibrary(library.module);
        library.* = undefined;
    }

    /// Lists the sources the manager knows: every TWAIN driver that's installed, whether its
    /// scanner is attached or not.
    pub fn devices(library: *Library, gpa: std.mem.Allocator) Error![]interface.Device {
        if (comptime !supported) return error.Unavailable;
        // Each source's identity is read into the same `identity`, so we copy its strings.
        var found: interface.DeviceList = .empty;
        errdefer found.deinit(gpa);
        var identity: Identity = std.mem.zeroes(Identity);
        var message: u16 = msg_getfirst;
        while (library.entry(&library.app, null, dg_control, dat_identity, message, @ptrCast(&identity)) == rc_success) : (message = msg_getnext) {
            try found.append(gpa, .{
                .id = span32(&identity.product_name),
                .vendor = span32(&identity.manufacturer),
                .model = span32(&identity.product_name),
                .driver = "TWAIN",
                .kind = .twain,
            });
        }
        return found.toOwnedSlice(gpa);
    }

    pub fn open(library: *Library, gpa: std.mem.Allocator, device: interface.Device) Error!Scanner {
        _ = gpa;
        if (comptime !supported) return error.Unavailable;
        var source: Identity = std.mem.zeroes(Identity);
        source.product_name = str32(device.id);
        if (library.entry(&library.app, null, dg_control, dat_identity, msg_opends, @ptrCast(&source)) != rc_success) {
            return library.failure(null);
        }
        var scanner: Scanner = .{ .library = library, .source = source };
        // Sources that speak TWAIN 2 can say "ready" through a callback instead of a message.
        if (source.supported_groups & df_ds2 != 0 and library.app.supported_groups & df_dsm2 != 0) {
            var callback: Callback = .{ .proc = @ptrCast(&sourceCallback), .reference = 0, .message = 0 };
            _ = scanner.call(dg_control, dat_callback, msg_register_callback, @ptrCast(&callback));
        }
        return scanner;
    }

    /// Returns the error behind the last failure, from the condition code of the manager or the
    /// source.
    fn failure(library: *Library, source: ?*Identity) Error {
        var status: Status = .{ .condition = 0, .data = 0 };
        if (library.entry(&library.app, source, dg_control, dat_status, msg_get, @ptrCast(&status)) != rc_success) return error.Failed;
        return switch (status.condition) {
            cc_lowmemory => error.OutOfMemory,
            cc_nods => error.NotFound,
            cc_maxconnections => error.Busy,
            cc_badcap, cc_badvalue, cc_capunsupported => error.Unsupported,
            cc_paperjam => error.Jammed,
            cc_denied => error.AccessDenied,
            else => error.Failed,
        };
    }

    fn allocate(library: *Library, size: u32) ?Handle {
        if (library.memory.allocate) |f| return f(size);
        return win.GlobalAlloc(win.gmem_moveable | win.gmem_zeroinit, size);
    }

    fn free(library: *Library, handle: Handle) void {
        if (library.memory.free) |f| return f(handle);
        _ = win.GlobalFree(handle);
    }

    fn lock(library: *Library, handle: Handle) ?[*]u8 {
        const pointer = if (library.memory.lock) |f| f(handle) else win.GlobalLock(handle);
        return @ptrCast(pointer);
    }

    fn unlock(library: *Library, handle: Handle) void {
        if (library.memory.unlock) |f| return f(handle);
        _ = win.GlobalUnlock(handle);
    }
};

/// A capability's values, read out of its container.
const Values = struct {
    items: std.ArrayList(f64) = .empty,
    current: ?f64 = null,
    /// For a range: its two ends and its step.
    range: ?[3]f64 = null,

    fn deinit(values: *Values, gpa: std.mem.Allocator) void {
        values.items.deinit(gpa);
    }

    fn contains(values: Values, wanted: f64) bool {
        if (values.range) |r| return wanted >= r[0] and wanted <= r[1];
        for (values.items.items) |v| if (v == wanted) return true;
        return values.current == wanted;
    }
};

fn itemSize(item_type: u16) ?usize {
    return switch (item_type) {
        ty_int8, ty_uint8 => 1,
        ty_int16, ty_uint16, ty_bool => 2,
        ty_int32, ty_uint32, ty_fix32 => 4,
        else => null,
    };
}

/// Reads the number in a 4-byte container slot, or in a list item, of type `item_type`.
fn itemValue(item_type: u16, bytes: []const u8) f64 {
    return switch (item_type) {
        ty_int8 => @floatFromInt(@as(i8, @bitCast(bytes[0]))),
        ty_uint8 => @floatFromInt(bytes[0]),
        ty_int16 => @floatFromInt(std.mem.readInt(i16, bytes[0..2], .little)),
        ty_uint16, ty_bool => @floatFromInt(std.mem.readInt(u16, bytes[0..2], .little)),
        ty_int32 => @floatFromInt(std.mem.readInt(i32, bytes[0..4], .little)),
        ty_uint32 => @floatFromInt(std.mem.readInt(u32, bytes[0..4], .little)),
        ty_fix32 => Fix32.fromBits(std.mem.readInt(u32, bytes[0..4], .little)).value(),
        else => 0,
    };
}

/// Returns the container's 4-byte field at `at`.
fn field(bytes: [*]u8, at: usize) *[field_bytes]u8 {
    return bytes[at..][0..field_bytes];
}

/// An open TWAIN data source.
pub const Scanner = struct {
    library: *Library,
    source: Identity,

    fn call(scanner: *Scanner, group: u32, data_type: u16, message: u16, data: ?*anyopaque) u16 {
        return scanner.library.entry(&scanner.library.app, &scanner.source, group, data_type, message, data);
    }

    fn check(scanner: *Scanner, rc: u16) Error!void {
        if (rc != rc_success and rc != rc_checkstatus) return scanner.library.failure(&scanner.source);
    }

    pub fn close(scanner: *Scanner) void {
        if (comptime !supported) unreachable;
        const library = scanner.library;
        _ = library.entry(&library.app, null, dg_control, dat_identity, msg_closeds, @ptrCast(&scanner.source));
        scanner.* = undefined;
    }

    /// Reads capability `cap`. Returns null when the source doesn't have it.
    fn get(scanner: *Scanner, gpa: std.mem.Allocator, cap: u16) Error!?Values {
        var capability: Capability = .{ .cap = cap, .container_type = on_dontcare, .container = null };
        if (scanner.call(dg_control, dat_capability, msg_get, @ptrCast(&capability)) != rc_success) return null;
        const handle = capability.container orelse return null;
        defer scanner.library.free(handle);
        const bytes = scanner.library.lock(handle) orelse return null;
        defer scanner.library.unlock(handle);

        var values: Values = .{};
        errdefer values.deinit(gpa);
        const item_type = std.mem.readInt(u16, bytes[item_type_at..][0..@sizeOf(u16)], .little);
        switch (capability.container_type) {
            on_onevalue => values.current = itemValue(item_type, field(bytes, one_value_at)),
            on_range => {
                values.range = .{
                    itemValue(item_type, field(bytes, range_min_at)),
                    itemValue(item_type, field(bytes, range_max_at)),
                    itemValue(item_type, field(bytes, range_step_at)),
                };
                values.current = itemValue(item_type, field(bytes, range_current_at));
            },
            on_enumeration, on_array => {
                const size = itemSize(item_type) orelse return values;
                const count = std.mem.readInt(u32, field(bytes, list_count_at), .little);
                const list_at: usize = if (capability.container_type == on_enumeration) enumeration_items_at else array_items_at;
                for (0..count) |i| try values.items.append(gpa, itemValue(item_type, bytes[list_at + i * size ..][0..size]));
                if (capability.container_type == on_enumeration) {
                    const index = std.mem.readInt(u32, field(bytes, enumeration_current_at), .little);
                    if (index < values.items.items.len) values.current = values.items.items[index];
                }
            },
            else => {},
        }
        return values;
    }

    /// Sets capability `cap` to a single value of type `item_type`, whose bits are in `raw`.
    fn set(scanner: *Scanner, cap: u16, item_type: u16, raw: u32) Error!void {
        const handle = scanner.library.allocate(one_value_bytes) orelse return error.OutOfMemory;
        defer scanner.library.free(handle);
        const bytes = scanner.library.lock(handle) orelse return error.OutOfMemory;
        std.mem.writeInt(u16, bytes[item_type_at..][0..@sizeOf(u16)], item_type, .little);
        std.mem.writeInt(u32, field(bytes, one_value_at), raw, .little);
        scanner.library.unlock(handle);
        var capability: Capability = .{ .cap = cap, .container_type = on_onevalue, .container = handle };
        try scanner.check(scanner.call(dg_control, dat_capability, msg_set, @ptrCast(&capability)));
    }

    fn setFix(scanner: *Scanner, cap: u16, value: f64) Error!void {
        return scanner.set(cap, ty_fix32, Fix32.of(value).bits());
    }

    fn setLightPath(scanner: *Scanner, source: interface.Source) Error!void {
        switch (source) {
            .flatbed => scanner.set(icap_lightpath, ty_uint16, lp_reflective) catch {},
            .transparency => try scanner.set(icap_lightpath, ty_uint16, lp_transmissive),
            .feeder => return error.Unsupported,
        }
    }

    pub fn capabilities(scanner: *Scanner, gpa: std.mem.Allocator, wanted: ?interface.Source) Error!interface.Capabilities {
        if (comptime !supported) return error.Unavailable;
        var sources: std.EnumSet(interface.Source) = .initOne(.flatbed);
        if (try scanner.get(gpa, icap_lightpath)) |paths| {
            var p = paths;
            defer p.deinit(gpa);
            if (p.contains(lp_transmissive)) sources.insert(.transparency);
        }
        const source = wanted orelse .flatbed;
        if (!sources.contains(source)) return error.Unsupported;
        try scanner.setLightPath(source);
        scanner.set(icap_units, ty_uint16, un_inches) catch {};
        scanner.set(icap_pixeltype, ty_uint16, pt_rgb) catch {};

        var resolutions: std.ArrayList(u32) = .empty;
        errdefer resolutions.deinit(gpa);
        if (try scanner.get(gpa, icap_xresolution)) |found| {
            var r = found;
            defer r.deinit(gpa);
            if (r.range) |range| {
                try interface.appendResolutionsInRange(gpa, &resolutions, range[0], range[1], range[2]);
            } else for (r.items.items) |v| if (interface.resolutionOf(v)) |dpi| try resolutions.append(gpa, dpi);
            if (resolutions.items.len == 0) if (r.current) |v| if (interface.resolutionOf(v)) |dpi| try resolutions.append(gpa, dpi);
        }
        std.mem.sortUnstable(u32, resolutions.items, {}, std.sort.asc(u32));

        var area: interface.Area = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        if (try scanner.get(gpa, icap_physicalwidth)) |found| {
            var w = found;
            defer w.deinit(gpa);
            area.width = @floatCast((w.current orelse 0) * formats.mm_per_inch);
        }
        if (try scanner.get(gpa, icap_physicalheight)) |found| {
            var h = found;
            defer h.deinit(gpa);
            area.height = @floatCast((h.current orelse 0) * formats.mm_per_inch);
        }
        var deep = false;
        if (try scanner.get(gpa, icap_bitdepth)) |found| {
            var d = found;
            defer d.deinit(gpa);
            deep = d.contains(48) or d.contains(16);
        }
        var film_setting = false;
        if (try scanner.get(gpa, icap_filmtype)) |found| {
            var f = found;
            f.deinit(gpa);
            film_setting = true;
        }
        return .{
            .sources = sources,
            .source = source,
            .resolutions = try resolutions.toOwnedSlice(gpa),
            .area = area,
            .deep = deep,
            .film_setting = film_setting,
            .profile = null,
        };
    }

    pub fn scan(scanner: *Scanner, gpa: std.mem.Allocator, request: interface.Request, progress: *interface.Progress) Error!interface.Image {
        if (comptime !supported) return error.Unavailable;
        progress.reset();
        try scanner.setLightPath(request.source);
        try scanner.set(icap_units, ty_uint16, un_inches);
        if (request.source == .transparency) scanner.set(icap_filmtype, ty_uint16, switch (request.film) {
            .negative => fm_negative,
            .positive => fm_positive,
        }) catch {};
        try scanner.set(icap_pixeltype, ty_uint16, pt_rgb);
        scanner.set(icap_bitdepth, ty_uint16, if (request.deep) 48 else 24) catch try scanner.set(icap_bitdepth, ty_uint16, 24);
        const dpi: f64 = @floatFromInt(request.dpi);
        try scanner.setFix(icap_xresolution, dpi);
        try scanner.setFix(icap_yresolution, dpi);
        scanner.setFix(icap_gamma, 1.0) catch {};
        try scanner.set(icap_xfermech, ty_uint16, sx_memory);
        scanner.set(cap_xfercount, ty_int16, 1) catch {};

        var area = request.area orelse interface.Area{ .x = 0, .y = 0, .width = 0, .height = 0 };
        if (request.area) |a| {
            var layout: ImageLayout = .{
                .frame = .{
                    .left = .of(a.x / formats.mm_per_inch),
                    .top = .of(a.y / formats.mm_per_inch),
                    .right = .of(a.right() / formats.mm_per_inch),
                    .bottom = .of(a.bottom() / formats.mm_per_inch),
                },
                .document_number = 1,
                .page_number = 1,
                .frame_number = 1,
            };
            try scanner.check(scanner.call(dg_image, dat_imagelayout, msg_set, @ptrCast(&layout)));
        }
        var layout: ImageLayout = undefined;
        if (scanner.call(dg_image, dat_imagelayout, msg_get, @ptrCast(&layout)) == rc_success) {
            const left = layout.frame.left.value() * formats.mm_per_inch;
            const top = layout.frame.top.value() * formats.mm_per_inch;
            area = .{
                .x = @floatCast(left),
                .y = @floatCast(top),
                .width = @floatCast(layout.frame.right.value() * formats.mm_per_inch - left),
                .height = @floatCast(layout.frame.bottom.value() * formats.mm_per_inch - top),
            };
        }

        // Enable the source with its window hidden, and wait for it to say the image is ready.
        var ui: UserInterface = .{ .show_ui = 0, .modal_ui = 0, .parent = scanner.library.window };
        callback_message.store(0, .release);
        try scanner.check(scanner.call(dg_control, dat_userinterface, msg_enableds, @ptrCast(&ui)));
        defer _ = scanner.call(dg_control, dat_userinterface, msg_disableds, @ptrCast(&ui));
        try scanner.waitUntilReady();

        var info: ImageInfo = undefined;
        try scanner.check(scanner.call(dg_image, dat_imageinfo, msg_get, @ptrCast(&info)));
        const picture = scanner.transfer(gpa, info, area, progress);
        // End the transfer and drop any others the source has queued, whatever happened.
        var pending: PendingXfers = .{ .count = 0, .end_of_job = 0 };
        _ = scanner.call(dg_control, dat_pendingxfers, msg_endxfer, @ptrCast(&pending));
        if (pending.count != 0) _ = scanner.call(dg_control, dat_pendingxfers, msg_reset, @ptrCast(&pending));
        return picture;
    }

    /// Pumps the scan thread's messages until the source says "transfer ready", through the
    /// message loop or the callback, whichever it uses.
    fn waitUntilReady(scanner: *Scanner) Error!void {
        const start = win.GetTickCount64();
        while (win.GetTickCount64() - start < ready_timeout_ms) {
            switch (callback_message.swap(0, .acq_rel)) {
                msg_xferready => return,
                msg_closedsreq, msg_closedsok => return error.Failed,
                else => {},
            }
            var msg: win.Msg = undefined;
            if (win.PeekMessageW(&msg, null, 0, 0, win.pm_remove) == 0) {
                win.Sleep(poll_ms);
                continue;
            }
            var event: Event = .{ .event = @ptrCast(&msg), .message = 0 };
            if (scanner.call(dg_control, dat_event, msg_processevent, @ptrCast(&event)) == rc_dsevent) {
                switch (event.message) {
                    msg_xferready => return,
                    msg_closedsreq, msg_closedsok => return error.Failed,
                    else => {},
                }
                continue;
            }
            _ = win.TranslateMessage(&msg);
            _ = win.DispatchMessageW(&msg);
        }
        return error.Failed;
    }

    /// Reads the image in buffered memory transfers, strip by strip.
    fn transfer(scanner: *Scanner, gpa: std.mem.Allocator, info: ImageInfo, area: interface.Area, progress: *interface.Progress) Error!interface.Image {
        if (info.planar != 0 or info.compression != 0) return error.Unsupported;
        if (info.width <= 0) return error.Failed;
        const width: usize = @intCast(info.width);
        const channels: usize = switch (info.samples_per_pixel) {
            1, 3 => @intCast(info.samples_per_pixel),
            else => return error.Unsupported,
        };
        const depth = std.enums.fromInt(image.Depth, info.bits_per_sample[0]) orelse return error.Unsupported;
        const sample_bytes = depth.bytes();
        if (info.length > 0) progress.total.store(@intCast(info.length), .release);

        var setup: SetupMemXfer = undefined;
        try scanner.check(scanner.call(dg_control, dat_setupmemxfer, msg_get, @ptrCast(&setup)));
        const row_bytes = width * channels * sample_bytes;
        // A source may say "don't care" (all ones) for its preferred size, and that isn't a real
        // size.
        const preferred = if (setup.preferred == std.math.maxInt(u32)) 0 else setup.preferred;
        // A source reporting a row too big for a transfer buffer can't be scanned from.
        const row_size = std.math.cast(u32, row_bytes) orelse return error.Failed;
        const size: u32 = @max(preferred, setup.min_buffer, row_size);
        if (size > max_transfer_bytes) return error.Failed;
        const buffer = try gpa.alloc(u8, size);
        defer gpa.free(buffer);

        var pixels: std.ArrayList([3]u16) = .empty;
        defer pixels.deinit(gpa);
        if (info.length > 0) try pixels.ensureTotalCapacity(gpa, width * @as(usize, @intCast(info.length)));
        var rows: usize = 0;
        while (true) {
            var strip: ImageMemXfer = .{
                .compression = 0,
                .bytes_per_row = 0,
                .columns = 0,
                .rows = 0,
                .x_offset = 0,
                .y_offset = 0,
                .bytes_written = 0,
                .memory = .{ .flags = mf_appowns | mf_pointer, .length = size, .data = buffer.ptr },
            };
            const rc = scanner.call(dg_image, dat_imagememxfer, msg_get, @ptrCast(&strip));
            switch (rc) {
                rc_success, rc_xferdone => {},
                rc_cancel => return error.Failed,
                else => return scanner.library.failure(&scanner.source),
            }
            if (strip.x_offset != 0 or strip.columns != width) return error.Unsupported;
            // The strip has to fit in the buffer it was written to, row by row.
            if (strip.bytes_per_row < row_bytes or @as(u64, strip.rows) * strip.bytes_per_row > size) return error.Failed;
            for (0..strip.rows) |r| {
                const y = strip.y_offset + r;
                const line = buffer[r * strip.bytes_per_row ..][0 .. width * channels * sample_bytes];
                if (pixels.items.len < (y + 1) * width) try pixels.appendNTimes(gpa, .{ 0, 0, 0 }, (y + 1) * width - pixels.items.len);
                for (pixels.items[y * width ..][0..width], 0..) |*p, x| {
                    for (p, 0..) |*out, c| out.* = image.sampleAt(line, x * channels + if (channels == 3) c else 0, depth, .little);
                }
                rows = @max(rows, y + 1);
            }
            _ = progress.lines.fetchAdd(strip.rows, .acq_rel);
            if (rc == rc_xferdone) break;
        }
        if (rows == 0) return error.Failed;
        pixels.shrinkRetainingCapacity(rows * width);
        return .{
            .scan = .{ .width = width, .height = rows, .pixels = try pixels.toOwnedSlice(gpa) },
            .depth = depth,
            .dpi = .{ @floatCast(info.x_resolution.value()), @floatCast(info.y_resolution.value()) },
            .area = area,
        };
    }
};

test "TWAIN's fixed-point numbers" {
    try std.testing.expectEqual(@as(f64, 2400), Fix32.of(2400).value());
    try std.testing.expectApproxEqAbs(@as(f64, 1.3), Fix32.of(1.3).value(), 1.0 / 65536.0);
    try std.testing.expectApproxEqAbs(@as(f64, -0.25), Fix32.fromBits(Fix32.of(-0.25).bits()).value(), 1e-9);
}

test "structures pack to 2 bytes" {
    try std.testing.expectEqual(@as(usize, 50), @offsetOf(Identity, "supported_groups"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(UserInterface, "parent"));
    try std.testing.expectEqual(@as(usize, 2), @offsetOf(ImageMemXfer, "bytes_per_row"));
    try std.testing.expectEqual(@as(usize, 26), @offsetOf(ImageMemXfer, "memory"));
}

test "container items read as numbers" {
    try std.testing.expectEqual(@as(f64, 300), itemValue(ty_fix32, &.{ 0x2c, 0x01, 0, 0 }));
    try std.testing.expectEqual(@as(f64, 48), itemValue(ty_uint16, &.{ 48, 0 }));
    try std.testing.expectEqual(@as(f64, -1), itemValue(ty_int16, &.{ 0xff, 0xff }));
}

test "every function compiles, on every platform" {
    std.testing.refAllDecls(Library);
    std.testing.refAllDecls(Scanner);
}
