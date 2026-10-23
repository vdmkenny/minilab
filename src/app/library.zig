//! The library as the app keeps it in memory: the rolls in a folder, and their thumbnails on the
//! GPU.

const std = @import("std");
const c = @import("c");
const minilab = @import("minilab");
const Texture = @import("../platform/texture.zig").Texture;

const image = minilab.image;
const roll = minilab.roll;
const labels = @import("labels.zig");

pub const Key = struct { roll: usize, frame: usize };

pub const Library = struct {
    path: []const u8,
    /// The path as the interface shows it, with the home folder as ~.
    label: []const u8,
    rolls: std.ArrayList(roll.Roll) = .empty,
    thumbnails: std.AutoHashMapUnmanaged(Key, Texture) = .empty,
    /// Thumbnails that have been asked for but aren't made yet.
    wanted: std.ArrayList(Key) = .empty,
    /// Thumbnails that couldn't be made. They aren't tried again until their frame changes.
    failed: std.AutoHashMapUnmanaged(Key, void) = .empty,
    /// The looks frames can be developed with: the built-in ones, and the LUTs and fitted looks
    /// in the library's Looks folder.
    looks: minilab.look.Catalog,
    /// The scanners calibrated against the film makers' datasheets, for Stock balance.
    calibrations: minilab.calibration.Calibrations,
    /// Thumbnails dropped during a frame. ImGui may still draw them in that frame, so they're only
    /// released once it has been drawn (`releaseRetired`).
    retired: std.ArrayList(Texture) = .empty,
    /// What the library's folders looked like on disk when `refresh` last looked, or null before
    /// it first does.
    on_disk: ?u64 = null,
    gpa: std.mem.Allocator,

    /// Loads the library at `path`. `home` is the user's home folder, used for the label.
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
    pub fn lookChanged(library: *Library, gpa: std.mem.Allocator, id: minilab.look.Id) void {
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

    /// Keeps `texture` until the frame has been drawn. If there's no memory to keep it, it stays on
    /// the GPU until the app ends, rather than being released while it might still be drawn.
    fn retire(library: *Library, texture: Texture) void {
        library.retired.append(library.gpa, texture) catch std.log.warn("a thumbnail stays on the GPU: out of memory", .{});
    }

    /// Releases the thumbnails dropped during the frame that was just drawn.
    pub fn releaseRetired(library: *Library, gpu: *c.SDL_GPUDevice) void {
        for (library.retired.items) |*t| t.release(gpu);
        library.retired.clearRetainingCapacity();
    }

    /// Reads the rolls again, after one was added or changed.
    pub fn reload(library: *Library, gpa: std.mem.Allocator, io: std.Io) !void {
        // Read the new list first, so if that fails the old one is still good.
        const rolls = try roll.listRolls(gpa, io, library.path);
        library.forgetThumbnails(gpa);
        for (library.rolls.items) |*r| r.close();
        library.rolls.deinit(gpa);
        library.rolls = rolls;
    }

    /// Reads the rolls again if the library changed on disk since the last look, say from rolls
    /// added by `minilab import` or in the Finder, or frames added to one. Returns whether it did.
    pub fn refresh(library: *Library, gpa: std.mem.Allocator, io: std.Io) bool {
        const now = library.fingerprint(io) catch return false;
        const before = library.on_disk;
        library.on_disk = now;
        if (before == null or before.? == now) return false;
        library.reload(gpa, io) catch |err| {
            std.log.err("can't read the library again: {t}", .{err});
            return false;
        };
        return true;
    }

    /// A fingerprint of the library's folders: the times of the library's folder, and of each
    /// roll's folder and frames folder. Adding, removing or renaming anything in them changes
    /// it. Saving a file in place doesn't, so the app's own saves don't count.
    fn fingerprint(library: *const Library, io: std.Io) !u64 {
        const cwd = std.Io.Dir.cwd();
        var hasher: std.hash.Wyhash = .init(0);
        var dir = try cwd.openDir(io, library.path, .{ .iterate = true });
        defer dir.close(io);
        hasher.update(std.mem.asBytes(&(try dir.stat(io)).mtime.nanoseconds));
        var each = dir.iterate();
        while (try each.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            hasher.update(entry.name);
            for ([_][]const u8{ ".", roll.frames_dir }) |sub| {
                var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ entry.name, sub }) catch continue;
                const stat = dir.statFile(io, path, .{}) catch continue;
                hasher.update(std.mem.asBytes(&stat.mtime.nanoseconds));
            }
        }
        return hasher.final();
    }

    /// The index of the roll in the folder at `path`.
    pub fn find(library: *const Library, path: []const u8) ?usize {
        for (library.rolls.items, 0..) |r, i| {
            if (std.mem.eql(u8, r.path, path)) return i;
        }
        return null;
    }

    /// The scanner or camera a roll was made with, under the name its calibration uses.
    pub fn scannerOf(info: roll.Info) ?[]const u8 {
        return info.scanner orelse info.camera;
    }

    /// The layer slopes of the roll's stock on the roll's scanner, for Stock balance. You only get
    /// them when the stock has a preset with gammas, its corrections are on, and the scanner is
    /// calibrated.
    pub fn stockSlopes(library: *const Library, rl: *const roll.Roll) ?[3]f32 {
        if (rl.info.kind != .colour_negative or !rl.info.stock_corrections) return null;
        const gamma = labels.stockGamma(rl.info.stock) orelse return null;
        const factors = library.calibrations.factors(scannerOf(rl.info) orelse return null) orelse return null;
        return minilab.calibration.stockSlopes(factors, gamma);
    }

    /// The curves of the roll's stock on the roll's scanner, for frames of film `kind`. Null when
    /// the stock has no curves, its corrections are off, or the film is a different kind.
    pub fn stockCurves(library: *const Library, rl: *const roll.Roll, kind: minilab.develop.FilmKind) ?minilab.stock_curves.Curves {
        if (!rl.info.stock_corrections) return null;
        const choice = labels.findStock(rl.info.stock orelse return null) orelse return null;
        const preset = choice.preset orelse return null;
        if (choice.kind != kind) return null;
        // Each layer's density relative to Status M. Green is taken to read Status M, and the
        // others are scaled by the scanner's calibration. Without a calibration, they all count as
        // Status M.
        var scale: [3]f32 = @splat(1);
        if (scannerOf(rl.info)) |scanner| if (library.calibrations.factors(scanner)) |factors| {
            for (&scale, factors) |*s, f| s.* = if (f > 0) 1 / f else 1;
        };
        return minilab.stock_curves.of(preset.*, scale);
    }

    /// What `importScans` added: the frames from index `first` onwards, from `files` files.
    pub const Imported = struct { first: usize, files: usize };

    /// Adds the scans at `paths` (PNM, TIFF, camera RAW, or finished JPEGs, which are copied) to
    /// roll `index` as new frames, in the order given: one frame per scan, or one per frame on a
    /// strip. A camera roll's frames are divided by its flat field. A scan that can't be read is
    /// logged and skipped.
    pub fn importScans(library: *Library, gpa: std.mem.Allocator, io: std.Io, index: usize, paths: []const []const u8) Imported {
        const r = &library.rolls.items[index];
        var imported: Imported = .{ .first = r.frames.items.len, .files = 0 };
        var flat = r.flatField(gpa, io) catch |err| {
            std.log.err("can't read the flat field of {s}: {t}", .{ r.info.name, err });
            return imported;
        };
        defer if (flat) |*f| f.deinit(gpa);
        for (paths) |path| {
            _ = r.importFile(gpa, io, path, if (flat) |*f| f else null, .copy) catch |err| {
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

    /// Returns the thumbnail for `key`. Returns null if it isn't made yet (it's then asked for) or
    /// couldn't be made.
    pub fn thumbnail(library: *Library, gpa: std.mem.Allocator, key: Key) ?Texture {
        if (library.thumbnails.get(key)) |t| return t;
        if (library.failed.contains(key)) return null;
        for (library.wanted.items) |w| if (std.meta.eql(w, key)) return null;
        library.wanted.append(gpa, key) catch {};
        return null;
    }

    /// Makes one of the wanted thumbnails.
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
        const gain = if (r.baseFor(key.frame)) |base| minilab.light_table.gainForBase(base) else minilab.light_table.gainForScan(scan);
        minilab.light_table.toScreen(scan.pixels, gain, pixels);
    } else {
        var rendered = try minilab.look.render(gpa, scan, settings.settings, library.looks.resolve(gpa, io, settings.look));
        defer rendered.deinit(gpa);
        var encoded = try minilab.encode.toSrgb8(gpa, rendered);
        defer encoded.deinit(gpa);
        rgba(pixels, encoded);
    }
    return Texture.upload(gpu, @intCast(scan.width), @intCast(scan.height), pixels);
}

fn rgba(pixels: [][4]u8, encoded: image.Encoded8) void {
    for (pixels, encoded.pixels) |*out, p| out.* = .{ p[0], p[1], p[2], std.math.maxInt(u8) };
}
