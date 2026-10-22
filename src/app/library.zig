//! The library as the app holds it: the rolls in a folder, and their thumbnails on the GPU.

const std = @import("std");
const c = @import("c");
const negscan = @import("negscan");
const Texture = @import("../platform/texture.zig").Texture;

const image = negscan.image;
const roll = negscan.roll;

pub const Key = struct { roll: usize, frame: usize };

pub const Library = struct {
    path: []const u8,
    /// The path as the interface shows it, with the home folder as ~.
    label: []const u8,
    rolls: std.ArrayList(roll.Roll) = .empty,
    thumbnails: std.AutoHashMapUnmanaged(Key, Texture) = .empty,
    /// Thumbnails asked for and not made yet.
    wanted: std.ArrayList(Key) = .empty,
    /// Thumbnails that couldn't be made, not tried again until their frame changes.
    failed: std.AutoHashMapUnmanaged(Key, void) = .empty,
    /// The looks frames can be developed with: the built-in ones, and the LUTs and fitted looks
    /// in the library's Looks folder.
    looks: negscan.look.Catalog,
    /// The scanners calibrated against the film makers' datasheets, for Stock balance.
    calibrations: negscan.calibration.Calibrations,
    /// Thumbnails let go of during a frame. ImGui may still draw them in it, so they are released
    /// once it has been drawn (`releaseRetired`).
    retired: std.ArrayList(Texture) = .empty,
    gpa: std.mem.Allocator,

    /// The library at `path`; `home` is the user's home folder, for the label.
    pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8, home: ?[]const u8) !Library {
        const label = if (home != null and home.?.len > 0 and std.mem.startsWith(u8, path, home.?))
            try std.mem.concat(gpa, u8, &.{ "~", path[home.?.len..] })
        else
            try gpa.dupe(u8, path);
        errdefer gpa.free(label);
        var library: Library = .{ .path = try gpa.dupe(u8, path), .label = label, .looks = try .init(gpa, path), .calibrations = try .load(gpa, io, path), .gpa = gpa };
        library.rolls = try roll.listRolls(gpa, io, path);
        return library;
    }

    pub fn deinit(library: *Library, gpa: std.mem.Allocator, gpu: *c.SDL_GPUDevice) void {
        library.forgetThumbnails(gpa);
        library.releaseRetired(gpu);
        library.retired.deinit(gpa);
        library.failed.deinit(gpa);
        library.thumbnails.deinit(gpa);
        library.wanted.deinit(gpa);
        for (library.rolls.items) |*r| r.close();
        library.rolls.deinit(gpa);
        library.looks.deinit(gpa);
        library.calibrations.deinit();
        gpa.free(library.path);
        gpa.free(library.label);
    }

    /// Forgets the thumbnails of the frames developed with `id`, after the look changed.
    pub fn lookChanged(library: *Library, gpa: std.mem.Allocator, id: negscan.look.Id) void {
        library.looks.forget(gpa, id);
        for (library.rolls.items, 0..) |r, i| {
            for (r.frames.items, 0..) |frame, j| {
                if (frame.developed and frame.look.eql(&id)) library.invalidate(.{ .roll = i, .frame = j });
            }
        }
    }

    fn forgetThumbnails(library: *Library, gpa: std.mem.Allocator) void {
        var each = library.thumbnails.valueIterator();
        while (each.next()) |t| library.retire(t.*);
        library.thumbnails.clearRetainingCapacity();
        library.wanted.clearRetainingCapacity();
        library.failed.clearRetainingCapacity();
        _ = gpa;
    }

    /// Keeps `texture` until the frame has been drawn. Should that fail, it stays on the GPU
    /// until the app ends rather than going while it may be drawn.
    fn retire(library: *Library, texture: Texture) void {
        library.retired.append(library.gpa, texture) catch std.log.warn("a thumbnail stays on the GPU: out of memory", .{});
    }

    /// Releases the thumbnails let go of during the frame just drawn.
    pub fn releaseRetired(library: *Library, gpu: *c.SDL_GPUDevice) void {
        for (library.retired.items) |*t| t.release(gpu);
        library.retired.clearRetainingCapacity();
    }

    /// Reads the rolls again, after one was added or changed.
    pub fn reload(library: *Library, gpa: std.mem.Allocator, io: std.Io) !void {
        // The new list first: should reading it fail, the old one stays good.
        const rolls = try roll.listRolls(gpa, io, library.path);
        library.forgetThumbnails(gpa);
        for (library.rolls.items) |*r| r.close();
        library.rolls.deinit(gpa);
        library.rolls = rolls;
    }

    /// The index of the roll in the folder at `path`.
    pub fn find(library: *const Library, path: []const u8) ?usize {
        for (library.rolls.items, 0..) |r, i| {
            if (std.mem.eql(u8, r.path, path)) return i;
        }
        return null;
    }

    /// What `importScans` added: the frames from `first` on, out of `files` files.
    pub const Imported = struct { first: usize, files: usize };

    /// Adds the scans at `paths` (PNM, TIFF or camera RAW) to roll `index` as new frames, in the
    /// order given: one frame per scan, or one per frame on a strip. A camera roll's frames are
    /// divided by its flat field. A scan that can't be read is logged and skipped.
    pub fn importScans(library: *Library, gpa: std.mem.Allocator, io: std.Io, index: usize, paths: []const []const u8) Imported {
        const r = &library.rolls.items[index];
        var imported: Imported = .{ .first = r.frames.items.len, .files = 0 };
        var flat = r.flatField(gpa, io) catch |err| {
            std.log.err("can't read the flat field of {s}: {t}", .{ r.info.name, err });
            return imported;
        };
        defer if (flat) |*f| f.deinit(gpa);
        for (paths) |path| {
            _ = r.importFile(gpa, io, path, if (flat) |*f| f else null) catch |err| {
                std.log.err("can't add {s} to {s}: {t}", .{ path, r.info.name, err });
                continue;
            };
            imported.files += 1;
        }
        return imported;
    }

    /// Forgets one frame's thumbnail, after its settings changed.
    pub fn invalidate(library: *Library, key: Key) void {
        if (library.thumbnails.fetchRemove(key)) |entry| library.retire(entry.value);
        _ = library.failed.remove(key);
    }

    /// The thumbnail of `key`, or null while it's still to be made.
    pub fn thumbnail(library: *Library, gpa: std.mem.Allocator, key: Key) ?Texture {
        if (library.thumbnails.get(key)) |t| return t;
        if (library.failed.contains(key)) return null;
        for (library.wanted.items) |w| if (std.meta.eql(w, key)) return null;
        library.wanted.append(gpa, key) catch {};
        return null;
    }

    /// Makes one wanted thumbnail.
    pub fn work(library: *Library, gpa: std.mem.Allocator, io: std.Io, gpu: *c.SDL_GPUDevice) void {
        const key = library.wanted.pop() orelse return;
        const texture = makeThumbnail(library, gpa, io, gpu, key) catch |err| {
            std.log.warn("thumbnail of roll {d} frame {d}: {t}", .{ key.roll, key.frame, err });
            library.failed.put(gpa, key, {}) catch {};
            return;
        };
        library.thumbnails.put(gpa, key, texture) catch {};
    }
};

fn makeThumbnail(library: *Library, gpa: std.mem.Allocator, io: std.Io, gpu: *c.SDL_GPUDevice, key: Key) !Texture {
    const r = &library.rolls.items[key.roll];
    const settings = r.frames.items[key.frame];
    var scan = try r.frameThumbnail(gpa, io, key.frame);
    defer scan.deinit(gpa);

    const pixels = try gpa.alloc([4]u8, scan.pixels.len);
    defer gpa.free(pixels);
    if (!settings.developed) {
        // Undeveloped frames show the film as it is, on a light table.
        const gain = if (r.baseFor(key.frame)) |base| negscan.light_table.gainForBase(base) else negscan.light_table.gainForScan(scan);
        negscan.light_table.toScreen(scan.pixels, gain, pixels);
    } else {
        var rendered = try negscan.look.render(gpa, scan, settings.settings, library.looks.resolve(gpa, io, settings.look));
        defer rendered.deinit(gpa);
        var encoded = try negscan.encode.toSrgb8(gpa, rendered);
        defer encoded.deinit(gpa);
        rgba(pixels, encoded);
    }
    return Texture.upload(gpu, @intCast(scan.width), @intCast(scan.height), pixels);
}

fn rgba(pixels: [][4]u8, encoded: image.Encoded8) void {
    for (pixels, encoded.pixels) |*out, p| out.* = .{ p[0], p[1], p[2], std.math.maxInt(u8) };
}
