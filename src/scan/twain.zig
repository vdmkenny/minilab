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

    /// One, in the fraction's units.
    const one = 1 << 16;

    fn of(number: f64) Fix32 {
        const scaled: i32 = @intFromFloat(@round(number * one));
        return .{ .whole = @intCast(scaled >> 16), .frac = @truncate(@as(u32, @bitCast(scaled))) };
    }

    fn value(fix: Fix32) f64 {
        return @as(f64, @floatFromInt(fix.whole)) + @as(f64, @floatFromInt(fix.frac)) / one;
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
    cap: CapabilityId,
    container_type: ContainerType,
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
    condition: ConditionCode,
    data: u16,
};

const Event = extern struct {
    event: ?*anyopaque align(2),
    message: Message,
};

const Callback = extern struct {
    proc: ?*const anyopaque align(2),
    reference: u32 align(2),
    message: i16,
};

const EntryFn = *const fn (origin: ?*Identity, destination: ?*Identity, group: Group, data_type: DataType, message: Message, data: ?*anyopaque) callconv(callconv_twain) ReturnCode;

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

/// The data groups a call can be in.
const Group = enum(u32) { control = 0x0001, image = 0x0002 };
/// Flags in an identity's supported groups: the app, the manager or the source speaks TWAIN 2.
const df_app2 = 0x10000000;
const df_dsm2 = 0x20000000;
const df_ds2 = 0x40000000;

const DataType = enum(u16) {
    capability = 0x0001,
    event = 0x0002,
    identity = 0x0003,
    parent = 0x0004,
    pending_xfers = 0x0005,
    setup_mem_xfer = 0x0006,
    status = 0x0008,
    user_interface = 0x0009,
    callback = 0x0010,
    entry_point = 0x0403,
    image_info = 0x0101,
    image_layout = 0x0102,
    image_mem_xfer = 0x0103,
};

/// The messages we send, and the ones sources send us. A source may send others.
const Message = enum(u16) {
    get = 0x0001,
    get_first = 0x0004,
    get_next = 0x0005,
    set = 0x0006,
    reset = 0x0007,
    xfer_ready = 0x0101,
    close_ds_req = 0x0102,
    close_ds_ok = 0x0103,
    open_dsm = 0x0301,
    close_dsm = 0x0302,
    open_ds = 0x0401,
    close_ds = 0x0402,
    disable_ds = 0x0501,
    enable_ds = 0x0502,
    process_event = 0x0601,
    end_xfer = 0x0701,
    register_callback = 0x0902,
    _,
};

const ReturnCode = enum(u16) {
    success = 0,
    check_status = 2,
    cancel = 3,
    ds_event = 4,
    xfer_done = 6,
    _,
};

/// Why a call failed, which the status call tells us.
const ConditionCode = enum(u16) {
    low_memory = 2,
    no_ds = 3,
    max_connections = 4,
    bad_cap = 6,
    bad_value = 10,
    cap_unsupported = 13,
    paper_jam = 20,
    denied = 21,
    _,
};

// Containers and their item types.
const ContainerType = enum(u16) {
    array = 3,
    enumeration = 4,
    one_value = 5,
    range = 6,
    dont_care = 0xffff,
    _,
};

const ItemType = enum(u16) {
    int8 = 0,
    int16 = 1,
    int32 = 2,
    uint8 = 3,
    uint16 = 4,
    uint32 = 5,
    bool = 6,
    fix32 = 7,
    _,
};

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
const CapabilityId = enum(u16) {
    xfer_count = 0x0001,
    pixel_type = 0x0101,
    units = 0x0102,
    xfer_mech = 0x0103,
    light_path = 0x1105,
    gamma = 0x1108,
    physical_width = 0x1111,
    physical_height = 0x1112,
    x_resolution = 0x1118,
    y_resolution = 0x1119,
    bit_depth = 0x112b,
    film_type = 0x1169,
    _,
};

const pt_rgb = 2;
/// Bits per pixel for RGB at 16 and 8 bits a channel, and per pixel for grey at 16.
const rgb_bits_deep = 48;
const rgb_bits = 24;
const grey_bits_deep = 16;
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

/// What the source last told us through the callback: 0, or a message such as `.xfer_ready`.
/// One scan thread holds one session, so a single value is enough.
var callback_message: std.atomic.Value(u16) = .init(0);

fn sourceCallback(origin: ?*Identity, destination: ?*Identity, group: Group, data_type: DataType, message: Message, data: ?*anyopaque) callconv(callconv_twain) ReturnCode {
    _ = .{ origin, destination, group, data_type, data };
    callback_message.store(@backingInt(message), .release);
    return .success;
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
                .supported_groups = @backingInt(Group.control) | @backingInt(Group.image) | df_app2,
                .manufacturer = str32("minilab"),
                .product_family = str32("minilab"),
                .product_name = str32("minilab"),
            },
            .memory = .{ .size = @sizeOf(EntryPoint), .entry = null, .allocate = null, .free = null, .lock = null, .unlock = null },
        };
        var parent: ?Handle = window;
        if (entry(&library.app, null, .control, .parent, .open_dsm, @ptrCast(&parent)) != .success) return error.Unavailable;
        if (library.app.supported_groups & df_dsm2 != 0) {
            if (entry(&library.app, null, .control, .entry_point, .get, @ptrCast(&library.memory)) != .success) library.memory.allocate = null;
        }
        return library;
    }

    pub fn unload(library: *Library) void {
        if (comptime !supported) unreachable;
        var parent: ?Handle = library.window;
        _ = library.entry(&library.app, null, .control, .parent, .close_dsm, @ptrCast(&parent));
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
        var message: Message = .get_first;
        while (library.entry(&library.app, null, .control, .identity, message, @ptrCast(&identity)) == .success) : (message = .get_next) {
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
        if (library.entry(&library.app, null, .control, .identity, .open_ds, @ptrCast(&source)) != .success) {
            return library.failure(null);
        }
        var scanner: Scanner = .{ .library = library, .source = source };
        // Sources that speak TWAIN 2 can say "ready" through a callback instead of a message.
        if (source.supported_groups & df_ds2 != 0 and library.app.supported_groups & df_dsm2 != 0) {
            var callback: Callback = .{ .proc = @ptrCast(&sourceCallback), .reference = 0, .message = 0 };
            _ = scanner.call(.control, .callback, .register_callback, @ptrCast(&callback));
        }
        return scanner;
    }

    /// Returns the error behind the last failure, from the condition code of the manager or the
    /// source.
    fn failure(library: *Library, source: ?*Identity) Error {
        var status: Status = .{ .condition = @fromBackingInt(0), .data = 0 };
        if (library.entry(&library.app, source, .control, .status, .get, @ptrCast(&status)) != .success) return error.Failed;
        return switch (status.condition) {
            .low_memory => error.OutOfMemory,
            .no_ds => error.NotFound,
            .max_connections => error.Busy,
            .bad_cap, .bad_value, .cap_unsupported => error.Unsupported,
            .paper_jam => error.Jammed,
            .denied => error.AccessDenied,
            _ => error.Failed,
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

fn itemSize(item_type: ItemType) ?usize {
    return switch (item_type) {
        .int8, .uint8 => 1,
        .int16, .uint16, .bool => 2,
        .int32, .uint32, .fix32 => 4,
        _ => null,
    };
}

/// Reads the number in a 4-byte container slot, or in a list item, of type `item_type`.
fn itemValue(item_type: ItemType, bytes: []const u8) f64 {
    return switch (item_type) {
        .int8 => @floatFromInt(@as(i8, @bitCast(bytes[0]))),
        .uint8 => @floatFromInt(bytes[0]),
        .int16 => @floatFromInt(std.mem.readInt(i16, bytes[0..2], .little)),
        .uint16, .bool => @floatFromInt(std.mem.readInt(u16, bytes[0..2], .little)),
        .int32 => @floatFromInt(std.mem.readInt(i32, bytes[0..4], .little)),
        .uint32 => @floatFromInt(std.mem.readInt(u32, bytes[0..4], .little)),
        .fix32 => Fix32.fromBits(std.mem.readInt(u32, bytes[0..4], .little)).value(),
        _ => 0,
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

    fn call(scanner: *Scanner, group: Group, data_type: DataType, message: Message, data: ?*anyopaque) ReturnCode {
        return scanner.library.entry(&scanner.library.app, &scanner.source, group, data_type, message, data);
    }

    fn check(scanner: *Scanner, rc: ReturnCode) Error!void {
        switch (rc) {
            .success, .check_status => {},
            else => return scanner.library.failure(&scanner.source),
        }
    }

    pub fn close(scanner: *Scanner) void {
        if (comptime !supported) unreachable;
        const library = scanner.library;
        _ = library.entry(&library.app, null, .control, .identity, .close_ds, @ptrCast(&scanner.source));
        scanner.* = undefined;
    }

    /// Reads capability `cap`. Returns null when the source doesn't have it.
    fn get(scanner: *Scanner, gpa: std.mem.Allocator, cap: CapabilityId) Error!?Values {
        var capability: Capability = .{ .cap = cap, .container_type = .dont_care, .container = null };
        if (scanner.call(.control, .capability, .get, @ptrCast(&capability)) != .success) return null;
        const handle = capability.container orelse return null;
        defer scanner.library.free(handle);
        const bytes = scanner.library.lock(handle) orelse return null;
        defer scanner.library.unlock(handle);

        var values: Values = .{};
        errdefer values.deinit(gpa);
        const item_type: ItemType = @fromBackingInt(std.mem.readInt(u16, bytes[item_type_at..][0..@sizeOf(u16)], .little));
        switch (capability.container_type) {
            .one_value => values.current = itemValue(item_type, field(bytes, one_value_at)),
            .range => {
                values.range = .{
                    itemValue(item_type, field(bytes, range_min_at)),
                    itemValue(item_type, field(bytes, range_max_at)),
                    itemValue(item_type, field(bytes, range_step_at)),
                };
                values.current = itemValue(item_type, field(bytes, range_current_at));
            },
            .enumeration, .array => {
                const size = itemSize(item_type) orelse return values;
                const count = std.mem.readInt(u32, field(bytes, list_count_at), .little);
                const list_at: usize = if (capability.container_type == .enumeration) enumeration_items_at else array_items_at;
                for (0..count) |i| try values.items.append(gpa, itemValue(item_type, bytes[list_at + i * size ..][0..size]));
                if (capability.container_type == .enumeration) {
                    const index = std.mem.readInt(u32, field(bytes, enumeration_current_at), .little);
                    if (index < values.items.items.len) values.current = values.items.items[index];
                }
            },
            .dont_care, _ => {},
        }
        return values;
    }

    /// Sets capability `cap` to a single value of type `item_type`, whose bits are in `raw`.
    fn set(scanner: *Scanner, cap: CapabilityId, item_type: ItemType, raw: u32) Error!void {
        const handle = scanner.library.allocate(one_value_bytes) orelse return error.OutOfMemory;
        defer scanner.library.free(handle);
        const bytes = scanner.library.lock(handle) orelse return error.OutOfMemory;
        std.mem.writeInt(u16, bytes[item_type_at..][0..@sizeOf(u16)], @backingInt(item_type), .little);
        std.mem.writeInt(u32, field(bytes, one_value_at), raw, .little);
        scanner.library.unlock(handle);
        var capability: Capability = .{ .cap = cap, .container_type = .one_value, .container = handle };
        try scanner.check(scanner.call(.control, .capability, .set, @ptrCast(&capability)));
    }

    fn setFix(scanner: *Scanner, cap: CapabilityId, value: f64) Error!void {
        return scanner.set(cap, .fix32, Fix32.of(value).bits());
    }

    fn setLightPath(scanner: *Scanner, source: interface.Source) Error!void {
        switch (source) {
            .flatbed => scanner.set(.light_path, .uint16, lp_reflective) catch {},
            .transparency => try scanner.set(.light_path, .uint16, lp_transmissive),
            .feeder => return error.Unsupported,
        }
    }

    pub fn capabilities(scanner: *Scanner, gpa: std.mem.Allocator, wanted: ?interface.Source) Error!interface.Capabilities {
        if (comptime !supported) return error.Unavailable;
        var sources: std.EnumSet(interface.Source) = .initOne(.flatbed);
        if (try scanner.get(gpa, .light_path)) |paths| {
            var p = paths;
            defer p.deinit(gpa);
            if (p.contains(lp_transmissive)) sources.insert(.transparency);
        }
        const source = wanted orelse .flatbed;
        if (!sources.contains(source)) return error.Unsupported;
        try scanner.setLightPath(source);
        scanner.set(.units, .uint16, un_inches) catch {};
        scanner.set(.pixel_type, .uint16, pt_rgb) catch {};

        var resolutions: std.ArrayList(u32) = .empty;
        errdefer resolutions.deinit(gpa);
        if (try scanner.get(gpa, .x_resolution)) |found| {
            var r = found;
            defer r.deinit(gpa);
            if (r.range) |range| {
                try interface.appendResolutionsInRange(gpa, &resolutions, range[0], range[1], range[2]);
            } else for (r.items.items) |v| if (interface.resolutionOf(v)) |dpi| try resolutions.append(gpa, dpi);
            if (resolutions.items.len == 0) if (r.current) |v| if (interface.resolutionOf(v)) |dpi| try resolutions.append(gpa, dpi);
        }
        std.mem.sortUnstable(u32, resolutions.items, {}, std.sort.asc(u32));

        var area: interface.Area = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        if (try scanner.get(gpa, .physical_width)) |found| {
            var w = found;
            defer w.deinit(gpa);
            area.width = @floatCast((w.current orelse 0) * formats.mm_per_inch);
        }
        if (try scanner.get(gpa, .physical_height)) |found| {
            var h = found;
            defer h.deinit(gpa);
            area.height = @floatCast((h.current orelse 0) * formats.mm_per_inch);
        }
        var deep = false;
        if (try scanner.get(gpa, .bit_depth)) |found| {
            var d = found;
            defer d.deinit(gpa);
            deep = d.contains(rgb_bits_deep) or d.contains(grey_bits_deep);
        }
        var film_setting = false;
        if (try scanner.get(gpa, .film_type)) |found| {
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
        try scanner.set(.units, .uint16, un_inches);
        if (request.source == .transparency) scanner.set(.film_type, .uint16, switch (request.film) {
            .negative => fm_negative,
            .positive => fm_positive,
        }) catch {};
        try scanner.set(.pixel_type, .uint16, pt_rgb);
        scanner.set(.bit_depth, .uint16, if (request.deep) rgb_bits_deep else rgb_bits) catch try scanner.set(.bit_depth, .uint16, rgb_bits);
        const dpi: f64 = @floatFromInt(request.dpi);
        try scanner.setFix(.x_resolution, dpi);
        try scanner.setFix(.y_resolution, dpi);
        scanner.setFix(.gamma, 1.0) catch {};
        try scanner.set(.xfer_mech, .uint16, sx_memory);
        scanner.set(.xfer_count, .int16, 1) catch {};

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
            try scanner.check(scanner.call(.image, .image_layout, .set, @ptrCast(&layout)));
        }
        var layout: ImageLayout = undefined;
        if (scanner.call(.image, .image_layout, .get, @ptrCast(&layout)) == .success) {
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
        try scanner.check(scanner.call(.control, .user_interface, .enable_ds, @ptrCast(&ui)));
        defer _ = scanner.call(.control, .user_interface, .disable_ds, @ptrCast(&ui));
        try scanner.waitUntilReady();

        var info: ImageInfo = undefined;
        try scanner.check(scanner.call(.image, .image_info, .get, @ptrCast(&info)));
        const picture = scanner.transfer(gpa, info, area, progress);
        // End the transfer and drop any others the source has queued, whatever happened.
        var pending: PendingXfers = .{ .count = 0, .end_of_job = 0 };
        _ = scanner.call(.control, .pending_xfers, .end_xfer, @ptrCast(&pending));
        if (pending.count != 0) _ = scanner.call(.control, .pending_xfers, .reset, @ptrCast(&pending));
        return picture;
    }

    /// Pumps the scan thread's messages until the source says "transfer ready", through the
    /// message loop or the callback, whichever it uses.
    fn waitUntilReady(scanner: *Scanner) Error!void {
        const start = win.GetTickCount64();
        while (win.GetTickCount64() - start < ready_timeout_ms) {
            switch (@as(Message, @fromBackingInt(callback_message.swap(0, .acq_rel)))) {
                .xfer_ready => return,
                .close_ds_req, .close_ds_ok => return error.Failed,
                else => {},
            }
            var msg: win.Msg = undefined;
            if (win.PeekMessageW(&msg, null, 0, 0, win.pm_remove) == 0) {
                win.Sleep(poll_ms);
                continue;
            }
            var event: Event = .{ .event = @ptrCast(&msg), .message = @fromBackingInt(0) };
            if (scanner.call(.control, .event, .process_event, @ptrCast(&event)) == .ds_event) {
                switch (event.message) {
                    .xfer_ready => return,
                    .close_ds_req, .close_ds_ok => return error.Failed,
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
    /// The size of the transfer buffer: what the source prefers, but at least what it needs and a
    /// row of `row_bytes`.
    fn bufferSize(scanner: *Scanner, row_bytes: usize) Error!u32 {
        var setup: SetupMemXfer = undefined;
        try scanner.check(scanner.call(.control, .setup_mem_xfer, .get, @ptrCast(&setup)));
        // A source may say "don't care" (all ones) for its preferred size, and that isn't a real
        // size.
        const preferred = if (setup.preferred == std.math.maxInt(u32)) 0 else setup.preferred;
        // A source reporting a row too big for a transfer buffer can't be scanned from.
        const row_size = std.math.cast(u32, row_bytes) orelse return error.Failed;
        const size: u32 = @max(preferred, setup.min_buffer, row_size);
        if (size > max_transfer_bytes) return error.Failed;
        return size;
    }

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

        const row_bytes = width * channels * sample_bytes;
        const size = try scanner.bufferSize(row_bytes);
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
            const rc = scanner.call(.image, .image_mem_xfer, .get, @ptrCast(&strip));
            switch (rc) {
                .success, .xfer_done => {},
                .cancel => return error.Failed,
                else => return scanner.library.failure(&scanner.source),
            }
            if (strip.x_offset != 0 or strip.columns != width) return error.Unsupported;
            // The strip has to fit in the buffer it was written to, row by row.
            if (strip.bytes_per_row < row_bytes or @as(u64, strip.rows) * strip.bytes_per_row > size) return error.Failed;
            if (strip.rows > 0) rows = @max(rows, try copyStrip(gpa, &pixels, buffer, strip, width, channels, depth));
            _ = progress.lines.fetchAdd(strip.rows, .acq_rel);
            if (rc == .xfer_done) break;
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

/// Copies `strip`'s rows from `buffer` into `pixels`, `width` wide, growing it as far as they
/// reach. A grey source fills all three channels. Returns the row below the strip.
fn copyStrip(gpa: std.mem.Allocator, pixels: *std.ArrayList([3]u16), buffer: []const u8, strip: ImageMemXfer, width: usize, channels: usize, depth: image.Depth) error{OutOfMemory}!usize {
    const line_bytes = width * channels * depth.bytes();
    for (0..strip.rows) |r| {
        const y = strip.y_offset + r;
        const line = buffer[r * strip.bytes_per_row ..][0..line_bytes];
        if (pixels.items.len < (y + 1) * width) try pixels.appendNTimes(gpa, .{ 0, 0, 0 }, (y + 1) * width - pixels.items.len);
        for (pixels.items[y * width ..][0..width], 0..) |*p, x| {
            for (p, 0..) |*out, c| out.* = image.sampleAt(line, x * channels + if (channels == 3) c else 0, depth, .little);
        }
    }
    return strip.y_offset + strip.rows;
}

test "TWAIN's fixed-point numbers" {
    try std.testing.expectEqual(@as(f64, 2400), Fix32.of(2400).value());
    try std.testing.expectApproxEqAbs(@as(f64, 1.3), Fix32.of(1.3).value(), 1.0 / @as(f64, Fix32.one));
    try std.testing.expectApproxEqAbs(@as(f64, -0.25), Fix32.fromBits(Fix32.of(-0.25).bits()).value(), 1e-9);
}

test "structures pack to 2 bytes" {
    try std.testing.expectEqual(@as(usize, 50), @offsetOf(Identity, "supported_groups"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(UserInterface, "parent"));
    try std.testing.expectEqual(@as(usize, 2), @offsetOf(ImageMemXfer, "bytes_per_row"));
    try std.testing.expectEqual(@as(usize, 26), @offsetOf(ImageMemXfer, "memory"));
}

test "container items read as numbers" {
    try std.testing.expectEqual(@as(f64, 300), itemValue(.fix32, &.{ 0x2c, 0x01, 0, 0 }));
    try std.testing.expectEqual(@as(f64, 48), itemValue(.uint16, &.{ 48, 0 }));
    try std.testing.expectEqual(@as(f64, -1), itemValue(.int16, &.{ 0xff, 0xff }));
}

test "every function compiles, on every platform" {
    std.testing.refAllDecls(Library);
    std.testing.refAllDecls(Scanner);
}

test "a grey strip fills all three channels, at its place in the picture" {
    const gpa = std.testing.allocator;
    var pixels: std.ArrayList([3]u16) = .empty;
    defer pixels.deinit(gpa);
    // Two rows of two pixels, each row padded to three bytes, starting at row 1.
    const buffer = [_]u8{ 1, 2, 0, 3, 4, 0 };
    const strip: ImageMemXfer = .{ .compression = 0, .bytes_per_row = 3, .columns = 2, .rows = 2, .x_offset = 0, .y_offset = 1, .bytes_written = 0, .memory = .{ .flags = 0, .length = 0, .data = null } };
    try std.testing.expectEqual(@as(usize, 3), try copyStrip(gpa, &pixels, &buffer, strip, 2, 1, .eight));
    try std.testing.expectEqual(@as(usize, 6), pixels.items.len);
    try std.testing.expectEqual([3]u16{ 0, 0, 0 }, pixels.items[0]);
    try std.testing.expectEqual([3]u16{ 2 * 257, 2 * 257, 2 * 257 }, pixels.items[3]);
    try std.testing.expectEqual([3]u16{ 3 * 257, 3 * 257, 3 * 257 }, pixels.items[4]);
}
