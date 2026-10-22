//! The Looks workspace: the looks a frame can be developed with, and making a look of one's own
//! from pairs of images: our raw scan of a negative, and a reference rendering of the same
//! negative, such as a lab's Frontier or Noritsu scan. See the design's Looks.dc.html.
//!
//! The work itself is in src/looks. Reading, lining up and fitting run off the page's thread
//! (`looks.work`); the page starts a job, shows how far it got, and takes its results when it's
//! done.

const std = @import("std");
const c = @import("c");
const negscan = @import("negscan");
const gui = @import("../ui/gui.zig");
const theme = @import("../ui/theme.zig");
const fonts = @import("../ui/fonts.zig");
const context = @import("context.zig");
const shortcuts = @import("shortcuts.zig");
const Texture = @import("../platform/texture.zig").Texture;
const Library = @import("library.zig").Library;
const looks = negscan.looks;

const draft = looks.draft;
const fit = looks.fit;
const work = looks.work;
const pairs = looks.pairs;
const register = looks.register;
const model = looks.model;
const curve = looks.curve;

/// Sizes in the design's pixels.
const list_width = 230;
const model_width = 340;
const list_padding = 12;
const main_padding_x = 20;
const main_padding_y = 16;
const model_padding = 16;
const table_min_width = 620;
const figure_gap = 12;
/// The figures are 3:2.
const figure_ratio = 2.0 / 3.0;
/// The figures' images, at most this many pixels across.
const view_longest = 640;

/// A registration this good or better counts as lined up; below the second, as not.
const aligned_quality = 0.8;
const poor_quality = 0.5;

/// Which look is shown.
const Selected = union(enum) {
    neutral,
    frontier,
    /// An imported LUT, an index in `State.imported`.
    imported: usize,
    own: usize,
};

/// A look of the user's, in the library's Looks folder.
const Own = struct {
    name: []u8,
    path: []u8,
    /// Whether look.json is there, so that Develop can use it.
    saved: bool,
    /// The pairs' strings.
    arena: std.heap.ArenaAllocator,
    references: draft.Source = .frontier_software,
    options: fit.Options = .{},
    pairs: std.ArrayList(draft.Pair) = .empty,
    /// Each pair read, once it is; or whether it couldn't be.
    prepared: std.ArrayList(?*pairs.Prepared) = .empty,
    failed: std.ArrayList(bool) = .empty,
    /// Each pair's balance offsets from the last fit.
    balance: std.ArrayList([3]f32) = .empty,
    result: ?fit.Result = null,
    /// Whether the pairs or the choices changed since the fit.
    stale: bool = false,
    /// Whether the fit on hand is the one saved.
    kept: bool = false,

    fn open(gpa: std.mem.Allocator, io: std.Io, entry: looks.saved.Entry) !Own {
        const name = try gpa.dupe(u8, entry.name);
        const path = gpa.dupe(u8, entry.path) catch |err| {
            gpa.free(name);
            return err;
        };
        var own: Own = .{ .name = name, .path = path, .saved = entry.saved, .arena = .init(gpa) };
        errdefer own.deinit(gpa);
        const d = try draft.load(own.arena.allocator(), io, entry.path);
        own.references = d.references;
        own.options = d.options;
        for (d.pairs) |p| try own.append(gpa, p);
        own.kept = entry.saved;
        return own;
    }

    fn deinit(own: *Own, gpa: std.mem.Allocator) void {
        gpa.free(own.name);
        gpa.free(own.path);
        for (own.prepared.items) |p| if (p) |prepared| {
            prepared.deinit(gpa);
            gpa.destroy(prepared);
        };
        own.prepared.deinit(gpa);
        own.failed.deinit(gpa);
        own.balance.deinit(gpa);
        own.pairs.deinit(gpa);
        if (own.result) |*r| r.deinit(gpa);
        own.arena.deinit();
    }

    /// Adds `pair`, its strings copied.
    fn append(own: *Own, gpa: std.mem.Allocator, pair: draft.Pair) !void {
        const a = own.arena.allocator();
        var copy = pair;
        copy.ours = try a.dupe(u8, pair.ours);
        copy.label = try a.dupe(u8, pair.label);
        copy.theirs = try a.dupe(u8, pair.theirs);
        copy.stock = if (pair.stock) |s| try a.dupe(u8, s) else null;
        // The four lists run in step, so room in all of them first.
        try own.pairs.ensureUnusedCapacity(gpa, 1);
        try own.prepared.ensureUnusedCapacity(gpa, 1);
        try own.failed.ensureUnusedCapacity(gpa, 1);
        try own.balance.ensureUnusedCapacity(gpa, 1);
        own.pairs.appendAssumeCapacity(copy);
        own.prepared.appendAssumeCapacity(null);
        own.failed.appendAssumeCapacity(false);
        own.balance.appendAssumeCapacity(@splat(0));
        own.changed();
    }

    fn remove(own: *Own, gpa: std.mem.Allocator, index: usize) void {
        _ = own.pairs.orderedRemove(index);
        if (own.prepared.orderedRemove(index)) |p| {
            p.deinit(gpa);
            gpa.destroy(p);
        }
        _ = own.failed.orderedRemove(index);
        _ = own.balance.orderedRemove(index);
        own.changed();
    }

    fn changed(own: *Own) void {
        if (own.result != null) own.stale = true;
    }

    fn save(own: *const Own, gpa: std.mem.Allocator, io: std.Io) void {
        draft.save(gpa, io, own.path, .{ .references = own.references, .options = own.options, .pairs = own.pairs.items }) catch |err| {
            std.log.err("can't save the look {s}: {t}", .{ own.name, err });
        };
    }

    fn heldOut(own: *const Own) usize {
        var n: usize = 0;
        for (own.pairs.items) |p| n += @intFromBool(p.held_out);
        return n;
    }

    /// Pairs not read yet that can be.
    fn unread(own: *const Own) usize {
        var n: usize = 0;
        for (own.prepared.items, own.failed.items) |p, f| n += @intFromBool(p == null and !f);
        return n;
    }

    /// The badge: Saved once look.json holds the fit on hand, Fitted once there is a fit that
    /// isn't saved, and Draft until then.
    fn status(own: *const Own) []const u8 {
        if (own.result != null and !own.kept) return if (own.stale) "Draft" else "Fitted";
        return if (own.saved) "Saved" else "Draft";
    }
};

/// The images of the selected pair, on the GPU.
const Figures = struct {
    key: ?Key = null,
    neutral: ?Texture = null,
    reference: ?Texture = null,
    difference: ?Texture = null,
    /// The pair's median ΔE2000 with the fit, when there's a fit.
    median: ?f32 = null,

    const Key = struct { look: usize, pair: usize, prepared: *const pairs.Prepared, aligned: bool, generation: u32 };

    fn release(f: *Figures, gpu: *c.SDL_GPUDevice) void {
        for ([_]*?Texture{ &f.neutral, &f.reference, &f.difference }) |t| {
            if (t.*) |*texture| texture.release(gpu);
            t.* = null;
        }
        f.key = null;
        f.median = null;
    }
};

const file_dialog = @import("../platform/file_dialog.zig");
const Dialog = file_dialog.Dialog;

/// What "Add pairs" opens.
const pair_files = [_]c.SDL_DialogFileFilter{
    .{ .name = "Scans and references (PPM, JPEG, TIFF)", .pattern = "ppm;jpg;jpeg;tif;tiff" },
};

/// What a job is doing, for the line under the references.
const Doing = enum { reading, matching, fitting };

pub const State = struct {
    loaded: bool = false,
    own: std.ArrayList(Own) = .empty,
    /// The LUTs imported into the library's Looks folder.
    imported: std.ArrayList(negscan.look.Id) = .empty,
    cube_dialog: Dialog = .{ .filters = &file_dialog.cube_files, .many = true },
    selected: Selected = .neutral,
    /// The selected pair of the selected look.
    pair: usize = 0,
    job: ?*work.Job = null,
    /// The look the job works for, and what it does.
    job_look: usize = 0,
    doing: Doing = .reading,
    /// For a fit: each pair's place in the job's list.
    job_pairs: std.ArrayList(usize) = .empty,
    dialog: Dialog = .{ .filters = &pair_files, .many = true },
    figures: Figures = .{},
    /// Counts fits, so that the figures know when to work out the difference again.
    generation: u32 = 0,
    rename: [128:0]u8 = @splat(0),

    pub fn deinit(state: *State, gpa: std.mem.Allocator, gpu: *c.SDL_GPUDevice) void {
        state.imported.deinit(gpa);
        state.cube_dialog.deinit(gpa);
        if (state.job) |j| j.finish(true);
        state.job = null;
        state.job_pairs.deinit(gpa);
        state.figures.release(gpu);
        for (state.own.items) |*o| o.deinit(gpa);
        state.own.deinit(gpa);
        state.dialog.deinit(gpa);
    }

    /// Whether everything the page shows has loaded: for a screenshot, which waits for it.
    pub fn settled(state: *const State) bool {
        if (!state.loaded or state.job != null) return false;
        const own = state.current() orelse return true;
        if (own.unread() > 0) return false;
        if (state.pair >= own.pairs.items.len) return true;
        if (own.prepared.items[state.pair] == null) return true;
        return state.figures.key != null;
    }

    /// Adds `paths`, scans and references, to the selected look as pairs: for files dropped on
    /// the window while the page shows. Our raw scans are PPM files and references JPEG or
    /// TIFF; references on their own are matched to the frames of the roll open in Develop, or
    /// of the whole library.
    pub fn addFiles(state: *State, ctx: context.Context, paths: []const []const u8) void {
        const index = switch (state.selected) {
            .own => |i| i,
            else => {
                ctx.notice.set("Pairs go in a look of your own: make one with New look from references.", .{});
                return;
            },
        };
        if (state.job != null) {
            ctx.notice.set("Wait for the work under way to finish, then add the pairs again.", .{});
            return;
        }
        var ours: std.ArrayList([]const u8) = .empty;
        defer ours.deinit(ctx.gpa);
        var theirs: std.ArrayList([]const u8) = .empty;
        defer theirs.deinit(ctx.gpa);
        for (paths) |p| {
            const extension = std.fs.path.extension(p);
            if (std.ascii.eqlIgnoreCase(extension, ".ppm") or std.ascii.eqlIgnoreCase(extension, ".pnm")) {
                ours.append(ctx.gpa, p) catch return;
            } else if (isReference(p)) {
                theirs.append(ctx.gpa, p) catch return;
            }
        }
        if (theirs.items.len == 0) {
            ctx.notice.set("Choose references, JPEG or TIFF, with our scans or without.", .{});
            return;
        }
        const own = &state.own.items[index];
        if (ours.items.len > 0) {
            if (ours.items.len != theirs.items.len) {
                ctx.notice.set("{d} scans and {d} references: choose as many of each, or references alone.", .{ ours.items.len, theirs.items.len });
                return;
            }
            // Paired in the order of their names.
            std.mem.sort([]const u8, ours.items, {}, byName);
            std.mem.sort([]const u8, theirs.items, {}, byName);
            for (ours.items, theirs.items) |o, t| {
                const where = findFrame(ctx.library, o);
                own.append(ctx.gpa, .{
                    .ours = o,
                    .label = if (where) |w| w.label else std.fs.path.basename(o),
                    .theirs = t,
                    .stock = if (where) |w| w.stock else null,
                    .held_out = draft.heldOutByDefault(own.pairs.items.len),
                    .placement = if (where) |w| w.placement else null,
                }) catch return;
            }
            own.save(ctx.gpa, ctx.io);
            ctx.notice.set("Added {d} pairs to {s}.", .{ ours.items.len, own.name });
            return;
        }
        state.startMatch(ctx, index, theirs.items);
    }

    fn current(state: *const State) ?*Own {
        return switch (state.selected) {
            .own => |i| &state.own.items[i],
            else => null,
        };
    }

    fn load(state: *State, ctx: context.Context) void {
        state.loaded = true;
        var entries = looks.saved.list(ctx.gpa, ctx.io, ctx.library.path) catch |err| {
            std.log.err("can't list the looks in {s}: {t}", .{ ctx.library.path, err });
            return;
        };
        defer {
            for (entries.items) |*e| e.deinit(ctx.gpa);
            entries.deinit(ctx.gpa);
        }
        for (entries.items) |entry| {
            const own = Own.open(ctx.gpa, ctx.io, entry) catch |err| {
                std.log.err("can't read the look {s}: {t}", .{ entry.name, err });
                continue;
            };
            state.own.append(ctx.gpa, own) catch return;
        }
        state.listImported(ctx);
        // The page opens on the user's own looks, where the work is.
        if (state.own.items.len > 0) state.selected = .{ .own = 0 };
    }

    /// Reads the list of imported LUTs again.
    fn listImported(state: *State, ctx: context.Context) void {
        state.imported.clearRetainingCapacity();
        // Whatever happens below, a selected LUT that isn't on the list any more isn't selected.
        defer if (state.selected == .imported and state.selected.imported >= state.imported.items.len) {
            state.selected = .neutral;
        };
        var choices = ctx.library.looks.choices(ctx.gpa, ctx.io) catch return;
        defer choices.deinit(ctx.gpa);
        for (choices.items) |choice| {
            if (choice.group == .imported) state.imported.append(ctx.gpa, choice.id) catch return;
        }
    }

    /// Imports the .cube files chosen, and selects the last.
    fn importCubes(state: *State, ctx: context.Context, paths: []const []const u8) void {
        var last: ?negscan.look.Id = null;
        for (paths) |path| {
            last = ctx.library.looks.import(ctx.gpa, ctx.io, path) catch |err| {
                ctx.notice.set("Can't import {s}: {t}.", .{ std.fs.path.basename(path), err });
                continue;
            };
        }
        const id = last orelse return;
        state.listImported(ctx);
        for (state.imported.items, 0..) |*i, n| if (i.eql(&id)) select(state, .{ .imported = n });
        ctx.notice.set("Imported {s}. It's in Develop's look list now.", .{id.label()});
    }

    /// Deletes the selected imported LUT from the library.
    fn removeImported(state: *State, ctx: context.Context, index: usize) void {
        const id = state.imported.items[index];
        ctx.library.looks.remove(ctx.gpa, ctx.io, id) catch |err| {
            ctx.notice.set("Can't remove {s}: {t}.", .{ id.label(), err });
            return;
        };
        ctx.library.lookChanged(ctx.gpa, id);
        ctx.notice.set("Removed {s}. Frames that used it develop with Neutral.", .{id.label()});
        state.listImported(ctx);
        state.selected = .neutral;
    }

    /// Takes a finished job's results, and starts reading the selected look's pairs if they
    /// aren't yet.
    fn pump(state: *State, ctx: context.Context) void {
        if (state.job) |job| {
            if (!job.isDone()) return;
            state.take(ctx, job);
            job.finish(false);
            state.job = null;
        }
        const chosen = state.dialog.take(ctx.gpa, ctx.io);
        defer Dialog.free(ctx.gpa, chosen);
        if (chosen.len > 0) state.addFiles(ctx, chosen);
        const cubes = state.cube_dialog.take(ctx.gpa, ctx.io);
        defer Dialog.free(ctx.gpa, cubes);
        if (cubes.len > 0) state.importCubes(ctx, cubes);
        if (state.job != null) return;

        const index = switch (state.selected) {
            .own => |i| i,
            else => return,
        };
        const own = &state.own.items[index];
        const count = own.unread();
        if (count == 0) return;
        var task = work.Prepare.init(ctx.gpa, count) catch return;
        var n: usize = 0;
        for (own.pairs.items, own.prepared.items, own.failed.items, 0..) |p, prepared, failed, i| {
            if (prepared != null or failed) continue;
            task.set(ctx.gpa, n, i, p.ours, p.placement, p.theirs, p.alignment) catch break;
            n += 1;
        }
        state.start(ctx, index, .reading, .{ .prepare = task });
    }

    fn start(state: *State, ctx: context.Context, look: usize, doing: Doing, task: work.Task) void {
        state.job = work.Job.start(ctx.gpa, ctx.io, task) catch |err| {
            std.log.err("can't start the work: {t}", .{err});
            return;
        };
        state.job_look = look;
        state.doing = doing;
    }

    fn take(state: *State, ctx: context.Context, job: *work.Job) void {
        const own = &state.own.items[state.job_look];
        switch (job.task) {
            .prepare => |*task| {
                var aligned = false;
                for (task.items) |*item| {
                    // Items left unset when memory ran out.
                    if (item.ours.len == 0 or item.pair >= own.pairs.items.len) continue;
                    if (item.prepared) |p| {
                        own.prepared.items[item.pair] = p;
                        item.prepared = null;
                    } else own.failed.items[item.pair] = true;
                    if (item.failure) |err| std.log.err("pair {s} and {s}: {t}", .{ item.ours, item.theirs, err });
                    const pair = &own.pairs.items[item.pair];
                    if (pair.alignment == null and item.alignment != null) {
                        pair.alignment = item.alignment;
                        aligned = true;
                    }
                }
                if (aligned) own.save(ctx.gpa, ctx.io);
            },
            .match => |*task| {
                var added: usize = 0;
                for (task.references, task.found) |path, found| {
                    const frame = task.frames[found orelse continue];
                    own.append(ctx.gpa, .{
                        .ours = frame.scan,
                        .label = frame.label,
                        .theirs = path,
                        .stock = frame.stock,
                        .held_out = draft.heldOutByDefault(own.pairs.items.len),
                        .placement = frame.placement,
                    }) catch break;
                    added += 1;
                }
                if (added > 0) own.save(ctx.gpa, ctx.io);
                if (added == task.references.len) {
                    ctx.notice.set("Found the frame of each of the {d} references.", .{added});
                } else {
                    ctx.notice.set("Found the frames of {d} of {d} references; the rest match no frame well enough.", .{ added, task.references.len });
                }
            },
            .fit => |*task| {
                if (task.result) |result| {
                    if (own.result) |*old| old.deinit(ctx.gpa);
                    own.result = result;
                    task.result = null;
                    for (own.balance.items) |*b| b.* = @splat(0);
                    for (state.job_pairs.items, 0..) |pair, at| {
                        if (pair < own.balance.items.len) own.balance.items[pair] = result.balance[at];
                    }
                    own.stale = false;
                    own.kept = false;
                    state.generation +%= 1;
                } else if (task.failure) |err| {
                    ctx.notice.set("The fit failed: {t}.", .{err});
                }
            },
        }
    }

    /// Finds the frames that `references` show, among the frames of the roll open in Develop,
    /// or of every roll when none is.
    fn startMatch(state: *State, ctx: context.Context, look: usize, references: []const []const u8) void {
        const library = ctx.library;
        const open = ctx.develop.rollIndex(library);
        var count: usize = 0;
        for (library.rolls.items, 0..) |r, i| {
            if (open == null or open == i) count += r.frames.items.len;
        }
        if (count == 0) {
            ctx.notice.set("No frames to match the references to: add our scans as well, or scan the roll first.", .{});
            return;
        }
        var task = work.Match.init(ctx.gpa, references, count) catch return;
        var n: usize = 0;
        for (library.rolls.items, 0..) |*r, i| {
            if (open != null and open != i) continue;
            for (0..r.frames.items.len) |f| {
                const path = r.scanPath(ctx.gpa, f) catch continue;
                defer ctx.gpa.free(path);
                const thumbnail = r.thumbnailPath(ctx.gpa, f) catch continue;
                defer ctx.gpa.free(thumbnail);
                task.setFrame(ctx.gpa, n, path, thumbnail, gui.print("{s} / {d:0>2}", .{ r.info.name, f + 1 }), r.info.stock, placementOf(r, f)) catch continue;
                n += 1;
            }
        }
        state.start(ctx, look, .matching, .{ .match = task });
    }

    fn startFit(state: *State, ctx: context.Context, look: usize) void {
        const own = &state.own.items[look];
        state.job_pairs.clearRetainingCapacity();
        for (own.pairs.items, own.prepared.items, 0..) |p, prepared, i| {
            if (prepared == null or !linedUp(p)) continue;
            state.job_pairs.append(ctx.gpa, i) catch return;
        }
        const n = state.job_pairs.items.len;
        const prepared = ctx.gpa.alloc(*const pairs.Prepared, n) catch return;
        const alignments = ctx.gpa.alloc(register.Alignment, n) catch {
            ctx.gpa.free(prepared);
            return;
        };
        const held_out = ctx.gpa.alloc(bool, n) catch {
            ctx.gpa.free(prepared);
            ctx.gpa.free(alignments);
            return;
        };
        for (state.job_pairs.items, 0..) |pair, at| {
            prepared[at] = own.prepared.items[pair].?;
            alignments[at] = own.pairs.items[pair].alignment.?;
            held_out[at] = own.pairs.items[pair].held_out;
        }
        state.start(ctx, look, .fitting, .{ .fit = .{ .prepared = prepared, .alignments = alignments, .held_out = held_out, .options = own.options } });
    }

    /// A new look, "Look N", with no pairs yet, selected.
    fn newLook(state: *State, ctx: context.Context) void {
        var number: usize = state.own.items.len + 1;
        const name = while (true) : (number += 1) {
            const candidate = gui.print("Look {d}", .{number});
            for (state.own.items) |o| {
                if (std.ascii.eqlIgnoreCase(o.name, candidate)) break;
            } else break candidate;
        };
        const root = looks.saved.folderOf(ctx.gpa, ctx.library.path) catch return;
        defer ctx.gpa.free(root);
        const path = std.fs.path.join(ctx.gpa, &.{ root, name }) catch return;
        defer ctx.gpa.free(path);
        var own = Own.open(ctx.gpa, ctx.io, .{ .name = @constCast(name), .path = path, .saved = false }) catch return;
        own.save(ctx.gpa, ctx.io);
        state.own.append(ctx.gpa, own) catch {
            own.deinit(ctx.gpa);
            return;
        };
        state.selected = .{ .own = state.own.items.len - 1 };
        state.pair = 0;
        ctx.notice.set("Made {s}. Add pairs: our raw scans and references of the same negatives.", .{name});
    }

    fn renameLook(state: *State, ctx: context.Context, index: usize, name: []const u8) void {
        const own = &state.own.items[index];
        if (name.len == 0 or std.mem.eql(u8, name, own.name)) return;
        if (std.mem.indexOfAny(u8, name, "/\\:") != null) {
            ctx.notice.set("A look's name can't have / \\ or : in it.", .{});
            return;
        }
        const parent = std.fs.path.dirname(own.path) orelse return;
        const path = std.fs.path.join(ctx.gpa, &.{ parent, name }) catch return;
        const cwd = std.Io.Dir.cwd();
        cwd.rename(own.path, cwd, path, ctx.io) catch |err| {
            ctx.gpa.free(path);
            ctx.notice.set("Can't rename the look: {t}.", .{err});
            return;
        };
        const old_id = negscan.look.Id.ofFitted(std.fs.path.basename(own.path)) catch null;
        ctx.gpa.free(own.path);
        own.path = path;
        const copy = ctx.gpa.dupe(u8, name) catch return;
        ctx.gpa.free(own.name);
        own.name = copy;
        // Frames name their look by its folder: they follow it to the new name.
        const old = old_id orelse return;
        const new = negscan.look.Id.ofFitted(name) catch return;
        ctx.library.lookChanged(ctx.gpa, old);
        for (ctx.library.rolls.items, 0..) |*r, i| {
            for (r.frames.items, 0..) |*frame, j| {
                if (!frame.look.eql(&old)) continue;
                frame.look = new;
                r.saveFrame(ctx.io, j) catch |err| std.log.err("can't save frame {d} of {s}: {t}", .{ j + 1, r.info.name, err });
                ctx.library.invalidate(.{ .roll = i, .frame = j });
            }
        }
        if (ctx.develop.frame) |*f| if (f.look.eql(&old)) {
            f.look = new;
        };
    }

    fn handle(state: *State, keys: std.EnumSet(shortcuts.Command)) void {
        const own = state.current() orelse return;
        const n = own.pairs.items.len;
        if (n == 0) return;
        if (keys.contains(.next) and state.pair + 1 < n) state.pair += 1;
        if (keys.contains(.previous) and state.pair > 0) state.pair -= 1;
        if (keys.contains(.first)) state.pair = 0;
        if (keys.contains(.last)) state.pair = n - 1;
    }

    /// Puts the selected pair's images on the GPU when they changed.
    fn refreshFigures(state: *State, ctx: context.Context) void {
        const look = switch (state.selected) {
            .own => |i| i,
            else => return state.figures.release(ctx.gpu),
        };
        const own = &state.own.items[look];
        if (state.pair >= own.pairs.items.len) return state.figures.release(ctx.gpu);
        const prepared = own.prepared.items[state.pair] orelse return state.figures.release(ctx.gpu);
        const alignment = own.pairs.items[state.pair].alignment;
        const key: Figures.Key = .{ .look = look, .pair = state.pair, .prepared = prepared, .aligned = alignment != null, .generation = if (own.result != null) state.generation else 0 };
        if (state.figures.key) |k| if (std.meta.eql(k, key)) return;
        state.figures.release(ctx.gpu);
        state.figures.key = key;
        makeFigures(state, ctx, own, prepared, alignment) catch |err| std.log.err("can't show the pair: {t}", .{err});
    }
};

fn makeFigures(state: *State, ctx: context.Context, own: *const Own, prepared: *const pairs.Prepared, alignment: ?register.Alignment) !void {
    const gpa = ctx.gpa;
    var v = try pairs.view(gpa, prepared, alignment, view_longest);
    defer v.deinit(gpa);
    const w: u32 = @intCast(v.width);
    const h: u32 = @intCast(v.height);
    state.figures.neutral = try .upload(ctx.gpu, w, h, v.neutral);
    state.figures.reference = try .upload(ctx.gpu, w, h, v.reference);
    const result = own.result orelse return;
    if (alignment == null) return;
    const errors = try gpa.alloc(f32, v.width * v.height);
    defer gpa.free(errors);
    var m = result.model;
    m.lut = result.lut;
    try v.difference(gpa, &m, own.balance.items[state.pair], errors);
    const colours = try gpa.alloc([4]u8, errors.len);
    defer gpa.free(colours);
    for (colours, errors, v.reference) |*out, e, r| out.* = if (r[3] == 0) .{ 0, 0, 0, 0 } else ramp(e);
    state.figures.difference = try .upload(ctx.gpu, w, h, colours);
    // Only where the reference covers our frame: elsewhere there's nothing to compare.
    var covered: usize = 0;
    for (errors, v.reference) |e, r| if (r[3] != 0) {
        errors[covered] = e;
        covered += 1;
    };
    state.figures.median = if (covered > 0) looks.colour.percentile(errors[0..covered], 0.5) else null;
}

/// A colour for a ΔE2000: near black where the look matches, through grey and amber, to red
/// from about 12 on.
fn ramp(e: f32) [4]u8 {
    const stops = [_]struct { f32, theme.Color }{
        .{ 0, theme.histogram_ground },
        .{ 2.5, theme.text_tertiary },
        .{ 6, theme.accent },
        .{ 12, theme.red },
    };
    var colour = stops[stops.len - 1][1];
    for (stops[0 .. stops.len - 1], stops[1..]) |a, b| {
        if (e > b[0]) continue;
        const t = (e - a[0]) / (b[0] - a[0]);
        colour = .{ .x = a[1].x + (b[1].x - a[1].x) * t, .y = a[1].y + (b[1].y - a[1].y) * t, .z = a[1].z + (b[1].z - a[1].z) * t, .w = 1 };
        break;
    }
    return .{ @intFromFloat(@round(colour.x * 255)), @intFromFloat(@round(colour.y * 255)), @intFromFloat(@round(colour.z * 255)), 255 };
}

fn isReference(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    for ([_][]const u8{ ".jpg", ".jpeg", ".tif", ".tiff" }) |e| {
        if (std.ascii.eqlIgnoreCase(extension, e)) return true;
    }
    return false;
}

/// Whether the pair's reference lined up well enough to fit from: a poor registration puts our
/// colours beside the wrong parts of theirs.
fn linedUp(pair: draft.Pair) bool {
    const alignment = pair.alignment orelse return false;
    return alignment.quality >= poor_quality;
}

/// By file name, numbers by their value, so that `fr_2.jpg` comes before `fr_10.jpg` as `02.ppm`
/// comes before `10.ppm`.
fn byName(_: void, a: []const u8, b: []const u8) bool {
    return naturalLess(std.fs.path.basename(a), std.fs.path.basename(b));
}

fn naturalLess(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            const start_a = i;
            const start_b = j;
            while (i < a.len and std.ascii.isDigit(a[i])) i += 1;
            while (j < b.len and std.ascii.isDigit(b[j])) j += 1;
            const x = std.fmt.parseInt(u64, a[start_a..i], 10) catch std.math.maxInt(u64);
            const y = std.fmt.parseInt(u64, b[start_b..j], 10) catch std.math.maxInt(u64);
            if (x != y) return x < y;
            continue;
        }
        if (a[i] != b[j]) return a[i] < b[j];
        i += 1;
        j += 1;
    }
    return a.len - i < b.len - j;
}

test "names sort by the numbers in them" {
    try std.testing.expect(naturalLess("fr_2.jpg", "fr_10.jpg"));
    try std.testing.expect(!naturalLess("fr_10.jpg", "fr_2.jpg"));
    try std.testing.expect(naturalLess("02.ppm", "10.ppm"));
    try std.testing.expect(naturalLess("a.jpg", "b.jpg"));
    try std.testing.expect(naturalLess("roll", "roll 2"));
}

/// The roll frame whose raw scan is at `path`, named as the table names it.
fn findFrame(library: *Library, path: []const u8) ?struct { label: []const u8, stock: ?[]const u8, placement: draft.Placement } {
    for (library.rolls.items) |*r| {
        if (!std.mem.startsWith(u8, path, r.path)) continue;
        for (0..r.frames.items.len) |i| {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
            const scan = r.scanPath(fixed.allocator(), i) catch continue;
            if (std.mem.eql(u8, scan, path)) return .{ .label = gui.print("{s} / {d:0>2}", .{ r.info.name, i + 1 }), .stock = r.info.stock, .placement = placementOf(r, i) };
        }
    }
    return null;
}

/// Where frame `index` of `r` lies on its scan, and its film base, as the roll has them.
fn placementOf(r: *const negscan.roll.Roll, index: usize) draft.Placement {
    const frame = r.frames.items[index];
    return .{
        .crop = frame.crop,
        .width = frame.width,
        .height = frame.height,
        .quarter_turns = frame.quarter_turns,
        .mirrored = frame.mirrored,
        .film_base = r.baseFor(index),
    };
}

/// Draws the workspace. Returns a workspace to go to, when the page asks for one.
pub fn draw(state: *State, ctx: context.Context) ?context.Workspace {
    if (!state.loaded) state.load(ctx);
    state.pump(ctx);
    state.handle(ctx.keys);
    if (state.current()) |own| {
        if (state.pair >= own.pairs.items.len) state.pair = own.pairs.items.len -| 1;
    }
    state.refreshFigures(ctx);

    const top = c.ImGui_GetCursorScreenPos();
    const available = c.ImGui_GetContentRegionAvail();
    const left = gui.px(list_width);
    const right = gui.px(model_width);

    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, gui.vec2(gui.px(list_padding), gui.px(list_padding)));
    _ = c.ImGui_BeginChild("looks", gui.vec2(left, available.y), c.ImGuiChildFlags_AlwaysUseWindowPadding, c.ImGuiWindowFlags_NoScrollbar);
    c.ImGui_PopStyleVar();
    drawList(state, ctx);
    gui.edge(.right);
    c.ImGui_EndChild();

    c.ImGui_SetCursorScreenPos(gui.vec2(top.x + left, top.y));
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ChildBg, theme.page);
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, gui.vec2(gui.px(main_padding_x), gui.px(main_padding_y)));
    _ = c.ImGui_BeginChild("look", gui.vec2(available.x - left - right, available.y), c.ImGuiChildFlags_AlwaysUseWindowPadding, c.ImGuiWindowFlags_None);
    c.ImGui_PopStyleVar();
    drawMain(state, ctx);
    c.ImGui_EndChild();
    c.ImGui_PopStyleColor();

    c.ImGui_SetCursorScreenPos(gui.vec2(top.x + available.x - right, top.y));
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, gui.vec2(gui.px(model_padding), gui.px(model_padding)));
    _ = c.ImGui_BeginChild("model", gui.vec2(right, available.y), c.ImGuiChildFlags_AlwaysUseWindowPadding, c.ImGuiWindowFlags_NoScrollbar);
    c.ImGui_PopStyleVar();
    drawModel(state, ctx);
    gui.edge(.left);
    c.ImGui_EndChild();
    return null;
}

/// The height of a line of text `size` pixels high, as the design sets lines: 1.4 times.
fn line(size: f32) f32 {
    return gui.px(size * 1.4);
}

/// Text in the current font, its line box's top-left at `at`, `height` high.
fn textIn(list: *c.ImDrawList, at: gui.Vec2, height: f32, colour: theme.Color, value: []const u8) void {
    const shown = gui.print("{s}", .{value});
    c.ImDrawList_AddText(list, gui.vec2(at.x, at.y + (height - c.ImGui_GetFontSize()) / 2), theme.imU32(colour), shown);
}

fn textWidth(value: []const u8) f32 {
    return c.ImGui_CalcTextSize(gui.print("{s}", .{value})).x;
}

/// `value` broken into lines no wider than `width`, at spaces.
fn wrap(value: []const u8, width: f32, out: [][]const u8) [][]const u8 {
    var n: usize = 0;
    var start: usize = 0;
    while (start < value.len and n < out.len) {
        var end = value.len;
        if (textWidth(value[start..end]) > width) {
            var last_space: ?usize = null;
            var i = start;
            while (i < value.len) : (i += 1) {
                if (value[i] != ' ') continue;
                if (textWidth(value[start..i]) > width) break;
                last_space = i;
            }
            end = last_space orelse (std.mem.indexOfScalarPos(u8, value, start, ' ') orelse value.len);
        }
        out[n] = value[start..end];
        n += 1;
        start = end;
        while (start < value.len and value[start] == ' ') start += 1;
    }
    return out[0..n];
}

/// A paragraph wrapped to `width` with the design's line spacing, from `at`. Returns its height.
fn paragraph(list: *c.ImDrawList, at: gui.Vec2, width: f32, colour: theme.Color, value: []const u8) f32 {
    var buffer: [16][]const u8 = undefined;
    const lines = wrap(value, width, &buffer);
    const h = c.ImGui_GetFontSize() * 1.4;
    for (lines, 0..) |l, i| textIn(list, gui.vec2(at.x, at.y + h * @as(f32, @floatFromInt(i))), h, colour, l);
    return h * @as(f32, @floatFromInt(lines.len));
}

fn paragraphHeight(width: f32, value: []const u8) f32 {
    var buffer: [16][]const u8 = undefined;
    return c.ImGui_GetFontSize() * 1.4 * @as(f32, @floatFromInt(wrap(value, width, &buffer).len));
}

// The list of looks.

fn drawList(state: *State, ctx: context.Context) void {
    const list = c.ImGui_GetWindowDrawList();
    const origin = c.ImGui_GetCursorScreenPos();
    const width = c.ImGui_GetContentRegionAvail().x;
    var y = origin.y;

    fonts.pushSized(.semibold, 12);
    textIn(list, gui.vec2(origin.x, y), line(12), theme.text_secondary, "LOOKS");
    fonts.pop();
    y += line(12) + gui.px(4 + 6);

    const item_height = gui.px(8 + 8 + 1) + line(13) + line(12) + 2;
    const built_in = [_]struct { Selected, []const u8, []const u8 }{
        .{ .neutral, "Neutral", "Built in · inversion curve" },
        .{ .frontier, "Frontier emulation", "Built in · colour LUT" },
    };
    for (built_in, 0..) |b, i| {
        c.ImGui_PushIDInt(@intCast(i));
        if (lookItem(list, gui.vec2(origin.x, y), width, item_height, b[1], b[2], std.meta.eql(state.selected, b[0]))) select(state, b[0]);
        c.ImGui_PopID();
        y += item_height + gui.px(6);
    }
    for (state.imported.items, 0..) |*id, i| {
        c.ImGui_PushIDInt(@intCast(i + built_in.len));
        const selected = switch (state.selected) {
            .imported => |s| s == i,
            else => false,
        };
        if (lookItem(list, gui.vec2(origin.x, y), width, item_height, id.label(), "Imported LUT", selected)) select(state, .{ .imported = i });
        c.ImGui_PopID();
        y += item_height + gui.px(6);
    }
    for (state.own.items, 0..) |*own, i| {
        c.ImGui_PushIDInt(@intCast(i + built_in.len + state.imported.items.len));
        const source = gui.print("{s} · {s}", .{ own.status(), own.references.short() });
        const selected = switch (state.selected) {
            .own => |s| s == i,
            else => false,
        };
        if (lookItem(list, gui.vec2(origin.x, y), width, item_height, own.name, source, selected)) select(state, .{ .own = i });
        c.ImGui_PopID();
        y += item_height + gui.px(6);
    }

    // New look from references: a dashed outline, a plus, the label.
    y += gui.px(6);
    const height = gui.px(32);
    c.ImGui_SetCursorScreenPos(gui.vec2(origin.x, y));
    if (c.ImGui_InvisibleButton("new look", gui.vec2(width, height), 0)) state.newLook(ctx);
    const hovered = c.ImGui_IsItemHovered(0);
    if (hovered) c.ImDrawList_AddRectFilledEx(list, gui.vec2(origin.x, y), gui.vec2(origin.x + width, y + height), theme.imU32(theme.control), gui.px(5), 0);
    gui.dashedRoundedRect(list, gui.vec2(origin.x, y), gui.vec2(origin.x + width, y + height), theme.imU32(theme.border), gui.px(5));
    const ink = theme.imU32(if (hovered) theme.text else theme.text_secondary);
    const plus = gui.vec2(origin.x + gui.px(10 + 6), y + height / 2);
    c.ImDrawList_AddLineEx(list, gui.vec2(plus.x - gui.px(4.5), plus.y), gui.vec2(plus.x + gui.px(4.5), plus.y), ink, gui.px(1.6));
    c.ImDrawList_AddLineEx(list, gui.vec2(plus.x, plus.y - gui.px(4.5)), gui.vec2(plus.x, plus.y + gui.px(4.5)), ink, gui.px(1.6));
    textIn(list, gui.vec2(origin.x + gui.px(10 + 12 + 6), y), height, if (hovered) theme.text else theme.text_secondary, "New look from references");
    if (hovered) c.ImGui_SetTooltip("A look fitted from pairs: our raw scans and references of the same negatives");

    // Import .cube, the same way.
    y += height + gui.px(6);
    c.ImGui_SetCursorScreenPos(gui.vec2(origin.x, y));
    if (c.ImGui_InvisibleButton("import cube", gui.vec2(width, height), 0)) state.cube_dialog.show(ctx.gpa, ctx.io);
    const import_hovered = c.ImGui_IsItemHovered(0);
    if (import_hovered) c.ImDrawList_AddRectFilledEx(list, gui.vec2(origin.x, y), gui.vec2(origin.x + width, y + height), theme.imU32(theme.control), gui.px(5), 0);
    gui.dashedRoundedRect(list, gui.vec2(origin.x, y), gui.vec2(origin.x + width, y + height), theme.imU32(theme.border), gui.px(5));
    const import_ink = theme.imU32(if (import_hovered) theme.text else theme.text_secondary);
    const import_plus = gui.vec2(origin.x + gui.px(10 + 6), y + height / 2);
    c.ImDrawList_AddLineEx(list, gui.vec2(import_plus.x - gui.px(4.5), import_plus.y), gui.vec2(import_plus.x + gui.px(4.5), import_plus.y), import_ink, gui.px(1.6));
    c.ImDrawList_AddLineEx(list, gui.vec2(import_plus.x, import_plus.y - gui.px(4.5)), gui.vec2(import_plus.x, import_plus.y + gui.px(4.5)), import_ink, gui.px(1.6));
    textIn(list, gui.vec2(origin.x + gui.px(10 + 12 + 6), y), height, if (import_hovered) theme.text else theme.text_secondary, "Import .cube LUT");
    if (import_hovered) c.ImGui_SetTooltip("A 3D or 1D LUT that expects sRGB or Rec. 709 input, laid over Neutral. It's copied into the library's Looks folder.");

    // The note at the bottom.
    const note = "A fitted look is curves, a density matrix and an optional 3D LUT, after the film base and density stages. A LUT look is laid over Neutral.";
    const bottom = c.ImGui_GetWindowPos().y + c.ImGui_GetWindowHeight() - gui.px(list_padding);
    const note_height = paragraphHeight(width, note);
    _ = paragraph(list, gui.vec2(origin.x, @max(y + height + gui.px(12), bottom - note_height)), width, theme.text_tertiary, note);
}

/// One look in the list: its name and where it comes from. True when clicked.
fn lookItem(list: *c.ImDrawList, at: gui.Vec2, width: f32, height: f32, name: []const u8, source: []const u8, selected: bool) bool {
    c.ImGui_SetCursorScreenPos(at);
    const clicked = c.ImGui_InvisibleButton("look", gui.vec2(width, height), 0);
    const hovered = c.ImGui_IsItemHovered(0);
    const far = gui.vec2(at.x + width, at.y + height);
    if (selected) {
        c.ImDrawList_AddRectFilledEx(list, at, far, theme.imU32(theme.accent_fill), gui.px(5), 0);
        c.ImDrawList_AddRectEx(list, at, far, theme.imU32(theme.accent), gui.px(5), 1, 0);
    } else if (hovered) {
        c.ImDrawList_AddRectFilledEx(list, at, far, theme.imU32(theme.raised), gui.px(5), 0);
    }
    const x = at.x + gui.px(10) + 1;
    var y = at.y + gui.px(8) + 1;
    // The design's medium weight, as semibold, the nearest the app carries.
    fonts.push(.semibold);
    textIn(list, gui.vec2(x, y), line(13), theme.text, gui.elideEnd(name, width - gui.px(20) - 2));
    fonts.pop();
    y += line(13) + gui.px(1);
    fonts.pushSized(.regular, 12);
    textIn(list, gui.vec2(x, y), line(12), theme.text_tertiary, gui.elideEnd(source, width - gui.px(20) - 2));
    fonts.pop();
    return clicked;
}

fn select(state: *State, which: Selected) void {
    if (std.meta.eql(state.selected, which)) return;
    state.selected = which;
    state.pair = 0;
}

// The look itself.

fn drawMain(state: *State, ctx: context.Context) void {
    const list = c.ImGui_GetWindowDrawList();
    const origin = c.ImGui_GetCursorScreenPos();
    const width = c.ImGui_GetContentRegionAvail().x;
    var y = origin.y;

    const title: []const u8, const badge: []const u8, const description: []const u8 = switch (state.selected) {
        .neutral => .{ "Neutral", "Built in", "negscan's own inversion: density above the film base, a density matrix, then the inversion curve. Nothing is added to the colour." },
        .frontier => .{ "Frontier emulation", "Built in", "The Fujifilm Frontier's colour, from the colour cube in its scanning software at its standard saturation, as a LUT over Neutral. Tone, neutrals and lightness stay Neutral's: greens lean a little toward teal, and skin, skies and yellows gain a little." },
        .imported => |i| .{ state.imported.items[i].label(), "Imported LUT", "A LUT laid over Neutral's sRGB output: tone and balance come from Develop, then the LUT. It should expect sRGB or Rec. 709 input." },
        .own => |i| .{ state.own.items[i].name, state.own.items[i].status(), switch (state.own.items[i].references) {
            .frontier_software => "What the Frontier's scanning software does to a negative, measured from its output and kept as small functions and a LUT.",
            .lab_scans => "What the lab's scanning does to a negative, measured from its scans and kept as small functions and a LUT.",
        } },
    };

    // The title and its badge, on one baseline.
    fonts.pushSized(.semibold, 18);
    const title_height = line(18);
    const title_width = textWidth(title);
    textIn(list, gui.vec2(origin.x, y), title_height, theme.text, title);
    fonts.pop();
    if (state.selected == .own) {
        c.ImGui_SetCursorScreenPos(gui.vec2(origin.x, y));
        if (c.ImGui_InvisibleButton("title", gui.vec2(title_width, title_height), 0)) {
            gui.setText(&state.rename, title) catch {
                state.rename = @splat(0);
            };
            _ = c.ImGui_OpenPopup("rename", 0);
        }
        if (c.ImGui_IsItemHovered(0)) c.ImGui_SetTooltip("Click to rename");
        drawRename(state, ctx);
    }
    fonts.pushSized(.regular, 12);
    const badge_width = textWidth(badge) + gui.px(16) + 2;
    const badge_min = gui.vec2(origin.x + title_width + gui.px(10), y + gui.px(4.5));
    const badge_max = gui.vec2(badge_min.x + badge_width, badge_min.y + line(12) + gui.px(2) + 2);
    c.ImDrawList_AddRectEx(list, badge_min, badge_max, theme.imU32(theme.border), gui.px(10), 1, 0);
    textIn(list, gui.vec2(badge_min.x + gui.px(8) + 1, badge_min.y + gui.px(1) + 1), line(12), theme.text_secondary, badge);
    fonts.pop();
    y += title_height + gui.px(4);
    y += paragraph(list, gui.vec2(origin.x, y), width, theme.text_secondary, description);

    const look = switch (state.selected) {
        .own => |i| i,
        .imported => |i| {
            y += gui.px(14);
            c.ImGui_SetCursorScreenPos(gui.vec2(origin.x, y));
            if (gui.buttonOf(.normal, "Remove from library", gui.vec2(0, 30))) state.removeImported(ctx, i);
            if (c.ImGui_IsItemHovered(0)) c.ImGui_SetTooltip("Deletes the library's copy in Looks; the file it was imported from stays");
            return;
        },
        else => {
            y += gui.px(14);
            _ = paragraph(list, gui.vec2(origin.x, y), width, theme.text_tertiary, "Built-in looks aren't fitted. To make a look of your own, use New look from references: pairs of our raw scans and references of the same negatives, such as a lab's scans. Or import a .cube LUT.");
            return;
        },
    };
    const own = &state.own.items[look];
    y += gui.px(14);
    y = drawReferences(state, ctx, own, look, gui.vec2(origin.x, y));
    y += gui.px(14);
    y = drawTable(state, ctx, own, gui.vec2(origin.x, y), width);
    y += gui.px(14);
    drawFigures(state, own, gui.vec2(origin.x, y), width);
}

fn drawRename(state: *State, ctx: context.Context) void {
    if (!c.ImGui_BeginPopup("rename", 0)) return;
    defer c.ImGui_EndPopup();
    const look = switch (state.selected) {
        .own => |i| i,
        else => return,
    };
    gui.heading("RENAME LOOK");
    if (c.ImGui_IsWindowAppearing()) c.ImGui_SetKeyboardFocusHere();
    _ = gui.textField("name", &state.rename, "Name", 240);
    const done = gui.buttonOf(.primary, "Rename", gui.vec2(0, 0)) or c.ImGui_IsKeyPressed(c.ImGuiKey_Enter);
    if (done) {
        state.renameLook(ctx, look, std.mem.sliceTo(&state.rename, 0));
        c.ImGui_CloseCurrentPopup();
    }
    c.ImGui_SameLine();
    if (gui.button("Cancel")) c.ImGui_CloseCurrentPopup();
}

/// References, where they come from, Add pairs, and the count. Returns the y below.
fn drawReferences(state: *State, ctx: context.Context, own: *Own, look: usize, at: gui.Vec2) f32 {
    const height = gui.px(32);
    const list = c.ImGui_GetWindowDrawList();
    var x = at.x;
    textIn(list, gui.vec2(x, at.y), height, theme.text_secondary, "References");
    x += textWidth("References") + gui.px(10);

    const sources = comptime std.enums.values(draft.Source);
    var names: [sources.len][]const u8 = undefined;
    var widest: f32 = 0;
    for (&names, sources) |*n, s| {
        n.* = s.label();
        widest = @max(widest, textWidth(n.*));
    }
    const combo_width = widest + gui.px(8 + 30);
    c.ImGui_SetCursorScreenPos(gui.vec2(x, at.y));
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_FramePadding, gui.vec2(gui.px(8), (height - c.ImGui_GetFontSize()) / 2));
    if (gui.combo("references", &names, @backingInt(own.references), combo_width / gui.scale)) |picked| {
        own.references = sources[picked];
        own.save(ctx.gpa, ctx.io);
    }
    c.ImGui_PopStyleVar();
    x += combo_width + gui.px(10);

    c.ImGui_SetCursorScreenPos(gui.vec2(x, at.y));
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_FramePadding, gui.vec2(gui.px(12), (height - c.ImGui_GetFontSize()) / 2));
    c.ImGui_BeginDisabled(state.job != null);
    if (gui.buttonOf(.normal, "Add pairs", gui.vec2(0, 32))) state.dialog.show(ctx.gpa, ctx.io);
    c.ImGui_EndDisabled();
    c.ImGui_PopStyleVar();
    if (c.ImGui_IsItemHovered(c.ImGuiHoveredFlags_AllowWhenDisabled)) {
        c.ImGui_SetTooltip("Choose references, JPEG or TIFF; with our raw scans (PPM) to pair them by name, or alone to find the frames they show. Or drop them on the window.");
    }
    x = c.ImGui_GetItemRectMax().x + gui.px(10);

    const n = own.pairs.items.len;
    const status: []const u8 = if (state.job != null and state.job_look == look) switch (state.doing) {
        .reading => gui.print("Reading and lining up pairs, {d} of {d}…", .{ state.job.?.progress.load(.acquire), state.job.?.steps }),
        .matching => "Finding the frames the references show…",
        .fitting => "Fitting…",
    } else if (n == 0)
        "No pairs yet"
    else
        gui.print("{d} {s} · {d} held out to check the fit", .{ n, if (n == 1) "pair" else "pairs", own.heldOut() });
    textIn(list, gui.vec2(x, at.y), height, theme.text_tertiary, status);
    return at.y + height;
}

const Column = enum { ours, theirs, stock, registration, use };

/// The pairs. Returns the y below.
fn drawTable(state: *State, ctx: context.Context, own: *Own, at: gui.Vec2, available: f32) f32 {
    const list = c.ImGui_GetWindowDrawList();
    const n = own.pairs.items.len;
    const header_height = gui.px(16) + line(12) + 1;
    const row_height = gui.px(16) + line(13) + 1;
    const width = @max(available, gui.px(table_min_width));
    const height = header_height + row_height * @as(f32, @floatFromInt(n)) + 2;
    const far = gui.vec2(at.x + width, at.y + height);
    // With no pairs, a row for the hint.
    const box_height = if (n == 0) height + row_height else height;
    c.ImDrawList_AddRectFilledEx(list, at, gui.vec2(far.x, at.y + box_height), theme.imU32(theme.panel), gui.px(6), 0);

    // Column widths as a browser's automatic table layout gives them: each column's widest
    // content, then the room left shared out in proportion.
    const headers = [_][]const u8{ "Our raw scan", own.references.one(), "Stock", "Registration", "Use" };
    var widths: [headers.len]f32 = undefined;
    fonts.pushSized(.semibold, 12);
    for (&widths, headers) |*w, h| w.* = textWidth(h);
    fonts.pop();
    for (own.pairs.items, 0..) |p, i| {
        widths[0] = @max(widths[0], textWidth(p.label));
        fonts.pushSized(.mono, 12);
        widths[1] = @max(widths[1], textWidth(std.fs.path.basename(p.theirs)));
        fonts.pop();
        widths[2] = @max(widths[2], textWidth(stockName(p.stock)));
        widths[3] = @max(widths[3], textWidth(registrationText(own, i)));
        widths[4] = @max(widths[4], textWidth(if (p.held_out) "Held out" else "Fit"));
    }
    var total: f32 = 0;
    for (&widths) |*w| {
        w.* += gui.px(24);
        total += w.*;
    }
    const room = width - 2 - total;
    for (&widths) |*w| w.* += room * w.* / total;

    // The header, in the design's medium weight.
    fonts.pushSized(.semibold, 12);
    var x = at.x + 1;
    for (headers, widths) |h, w| {
        textIn(list, gui.vec2(x + gui.px(12), at.y + 1 + gui.px(8)), line(12), theme.text_secondary, h);
        x += w;
    }
    fonts.pop();
    c.ImDrawList_AddLine(list, gui.vec2(at.x + 1, at.y + 1 + header_height - 0.5), gui.vec2(far.x - 1, at.y + 1 + header_height - 0.5), theme.imU32(theme.divider));

    // The rows.
    var remove: ?usize = null;
    for (own.pairs.items, 0..) |*p, i| {
        const top = at.y + 1 + header_height + row_height * @as(f32, @floatFromInt(i));
        const row_min = gui.vec2(at.x + 1, top);
        const row_max = gui.vec2(far.x - 1, top + row_height);
        c.ImGui_PushIDInt(@intCast(i));
        defer c.ImGui_PopID();

        // The Use cell toggles; the rest of the row selects the pair.
        const use_x = far.x - 1 - widths[4];
        c.ImGui_SetCursorScreenPos(row_min);
        if (c.ImGui_InvisibleButton("row", gui.vec2(use_x - row_min.x, row_height), 0)) state.pair = i;
        const row_hovered = c.ImGui_IsItemHovered(0);
        if (c.ImGui_BeginPopupContextItem()) {
            // Not while a fit runs: it would end up shown against a split it wasn't made from.
            if (c.ImGui_MenuItemEx(if (p.held_out) "Use to fit" else "Hold out to check the fit", null, false, state.job == null)) {
                p.held_out = !p.held_out;
                own.changed();
                own.save(ctx.gpa, ctx.io);
            }
            if (c.ImGui_MenuItemEx("Remove pair", null, false, state.job == null)) remove = i;
            c.ImGui_EndPopup();
        }
        c.ImGui_SetCursorScreenPos(gui.vec2(use_x, top));
        if (c.ImGui_InvisibleButton("use", gui.vec2(widths[4], row_height), 0) and state.job == null) {
            p.held_out = !p.held_out;
            own.changed();
            own.save(ctx.gpa, ctx.io);
        }
        const use_hovered = c.ImGui_IsItemHovered(0);
        if (use_hovered) c.ImGui_SetTooltip(if (p.held_out) "Held out: not fitted, to check the fit. Click to fit with it." else "Fitted with. Click to hold it out, to check the fit.");

        if (state.pair == i) {
            c.ImDrawList_AddRectFilled(list, row_min, row_max, theme.imU32(theme.raised));
        } else if (row_hovered or use_hovered) {
            c.ImDrawList_AddRectFilled(list, row_min, row_max, theme.imU32(theme.withAlpha(theme.raised, 0.5)));
        }
        if (i + 1 < n) c.ImDrawList_AddLine(list, gui.vec2(row_min.x, row_max.y - 0.5), gui.vec2(row_max.x, row_max.y - 0.5), theme.imU32(theme.raised));

        const text_top = top + gui.px(8);
        x = at.x + 1;
        for (std.enums.values(Column), widths) |column, w| {
            const cell = gui.vec2(x + gui.px(12), text_top);
            const room_in_cell = w - gui.px(24);
            switch (column) {
                .ours => textIn(list, cell, line(13), theme.text, gui.elideEnd(p.label, room_in_cell)),
                .theirs => {
                    fonts.pushSized(.mono, 12);
                    textIn(list, cell, line(13), theme.text_secondary, gui.elideStart(std.fs.path.basename(p.theirs), room_in_cell));
                    fonts.pop();
                },
                .stock => textIn(list, cell, line(13), theme.text_secondary, gui.elideEnd(stockName(p.stock), room_in_cell)),
                .registration => textIn(list, cell, line(13), theme.text_secondary, registrationText(own, i)),
                .use => textIn(list, cell, line(13), if (use_hovered) theme.text else theme.text_secondary, if (p.held_out) "Held out" else "Fit"),
            }
            x += w;
        }
        if (row_hovered and p.alignment != null) {
            const a = p.alignment.?;
            const turned = a.orientation.label();
            c.ImGui_SetTooltip(gui.print("{s}\nCorrelation {d:.2} where they overlap, up to 1; above {d:.1} lines up well.\nThe reference {s}{s}covers {d:.0}% of our scan's width.", .{
                p.theirs,
                a.quality,
                aligned_quality,
                turned,
                if (turned.len > 0) ", " else "",
                a.scale * 100,
            }));
        } else if (row_hovered) {
            c.ImGui_SetTooltip(gui.print("{s}\n{s}", .{ p.ours, p.theirs }));
        }
    }
    if (n == 0) {
        textIn(list, gui.vec2(at.x + 1 + gui.px(12), at.y + 1 + header_height + gui.px(8)), line(13), theme.text_tertiary, "Add pairs: our raw scans of negatives, and references of the same negatives.");
    }
    c.ImDrawList_AddRectEx(list, at, gui.vec2(far.x, at.y + box_height), theme.imU32(theme.divider), gui.px(6), 1, 0);
    c.ImGui_SetCursorScreenPos(gui.vec2(at.x, at.y + box_height));
    c.ImGui_Dummy(gui.vec2(0, 0));
    if (remove) |i| {
        own.remove(ctx.gpa, i);
        own.save(ctx.gpa, ctx.io);
        state.figures.release(ctx.gpu);
    }
    return at.y + box_height;
}

/// The stock as the table shows it: without the maker.
fn stockName(stock: ?[]const u8) []const u8 {
    const s = stock orelse return "None";
    for ([_][]const u8{ "Kodak ", "Fujifilm ", "Fuji ", "Ilford ", "Agfa ", "Lomography " }) |maker| {
        if (std.mem.startsWith(u8, s, maker)) return s[maker.len..];
    }
    return s;
}

fn registrationText(own: *const Own, index: usize) []const u8 {
    if (own.failed.items[index]) return "Can't read";
    const a = own.pairs.items[index].alignment orelse return "Not aligned yet";
    if (a.quality >= aligned_quality) return gui.print("Aligned · {d:.2}", .{a.quality});
    if (a.quality >= poor_quality) return gui.print("Check · {d:.2}", .{a.quality});
    return gui.print("Not aligned · {d:.2}", .{a.quality});
}

/// The selected pair: ours, the reference lined up, and their difference after the fit.
fn drawFigures(state: *State, own: *const Own, at: gui.Vec2, width: f32) void {
    const list = c.ImGui_GetWindowDrawList();
    const gap = gui.px(figure_gap);
    const figure_width = (width - 2 * gap) / 3;
    const figure_height = figure_width * figure_ratio;
    const pair = if (state.pair < own.pairs.items.len) own.pairs.items[state.pair] else null;
    const aligned = if (pair) |p| p.alignment != null else false;
    const f = &state.figures;
    const captions = [_][]const u8{
        "negscan, Neutral look",
        gui.print("{s}, {s}", .{ own.references.one(), if (aligned or pair == null) "aligned to ours" else "not aligned yet" }),
        if (f.median) |m| gui.print("Difference, ΔE2000 · median {d:.1}", .{m}) else "Difference, ΔE2000",
    };
    const textures = [_]?Texture{ f.neutral, f.reference, f.difference };
    for (captions, textures, 0..) |caption, texture, i| {
        const min = gui.vec2(at.x + (figure_width + gap) * @as(f32, @floatFromInt(i)), at.y);
        const max = gui.vec2(min.x + figure_width, min.y + figure_height);
        if (texture) |t| {
            c.ImDrawList_AddRectFilledEx(list, min, max, theme.imU32(theme.raised), gui.px(3), 0);
            gui.imageCover(list, t.ref(), t.width, t.height, min, max, gui.px(3));
        } else {
            c.ImDrawList_AddRectFilledEx(list, min, max, theme.imU32(theme.raised), gui.px(3), 0);
            if (i == 2) {
                const placeholder = if (own.result != null and !aligned) "[Not aligned yet]" else "[Difference map after fitting]";
                const size = c.ImGui_CalcTextSize(gui.print("{s}", .{placeholder}));
                textIn(list, gui.vec2((min.x + max.x - size.x) / 2, (min.y + max.y) / 2 - line(13) / 2), line(13), theme.text_tertiary, placeholder);
            }
        }
        textIn(list, gui.vec2(min.x, max.y + gui.px(6)), line(13), theme.text_secondary, gui.elideEnd(caption, figure_width));
    }
    c.ImGui_SetCursorScreenPos(gui.vec2(at.x, at.y + figure_height + gui.px(6) + line(13)));
    c.ImGui_Dummy(gui.vec2(0, 0));
}

// The model.

fn drawModel(state: *State, ctx: context.Context) void {
    const list = c.ImGui_GetWindowDrawList();
    const origin = c.ImGui_GetCursorScreenPos();
    const width = c.ImGui_GetContentRegionAvail().x;
    var y = origin.y;
    fonts.pushSized(.semibold, 12);
    textIn(list, gui.vec2(origin.x, y), line(12), theme.text_secondary, "MODEL");
    fonts.pop();
    y += line(12) + gui.px(12);

    const look = switch (state.selected) {
        .own => |i| i,
        .neutral => {
            y = drawStages(list, gui.vec2(origin.x, y), width, &.{
                .{ "Film base", "Density above the base, measured on each frame or picked" },
                .{ "Density matrix", "3 × 3, for crosstalk between channels; identity unless set in Develop" },
                .{ "Inversion curve", "Contrast, black and highlight roll-off, with each channel balanced" },
            });
            y += gui.px(12);
            y = drawChart(list, gui.vec2(origin.x, y), width, .neutral);
            return;
        },
        .frontier => {
            _ = drawStages(list, gui.vec2(origin.x, y), width, &.{
                .{ "Neutral", "Film base, density, balance and the inversion curve, as set in Develop" },
                .{ "Frontier colour LUT", "33³, on Neutral's sRGB output: the Frontier cube's colour at its standard saturation, with Neutral's lightness kept" },
            });
            return;
        },
        .imported => |i| {
            const resolved = ctx.library.looks.resolve(ctx.gpa, ctx.io, state.imported.items[i]);
            var buffer: [64]u8 = undefined;
            const size = if (resolved == .lut) resolved.lut.describe(&buffer) else "can't be read";
            _ = drawStages(list, gui.vec2(origin.x, y), width, &.{
                .{ "Neutral", "Film base, density, balance and the inversion curve, as set in Develop" },
                .{ "LUT", gui.print("{s}, on Neutral's sRGB output", .{size}) },
            });
            return;
        },
    };
    const own = &state.own.items[look];
    const busy = state.job != null;

    const options = [_]struct { *bool, []const u8, []const u8 }{
        .{ &own.options.balance, "Per-frame balance", gui.print("3 offsets per frame, for {s} own correction of each frame. Not part of the look.", .{own.references.corrector()}) },
        .{ &own.options.curves, "Channel curves", "R, G and B, monotone, 33 points each" },
        .{ &own.options.matrix, "Density matrix", "3 × 3, for crosstalk between channels" },
        .{ &own.options.lut, "3D LUT for what's left", lutNote(own) },
    };
    for (options, 0..) |option, i| {
        if (i > 0) y += gui.px(8);
        c.ImGui_PushIDInt(@intCast(i));
        if (modelOption(list, gui.vec2(origin.x, y), width, option[0], option[1], option[2], busy)) |h| {
            own.changed();
            own.save(ctx.gpa, ctx.io);
            y += h;
        } else y += optionHeight(width, option[2]);
        c.ImGui_PopID();
    }
    y += gui.px(12);

    const result: ?*const fit.Result = if (own.result) |*r| r else null;
    y = drawChart(list, gui.vec2(origin.x, y), width, if (result) |r| .{ .fitted = &r.model.curves } else .identity);
    y += gui.px(12);
    y = drawMatrix(list, gui.vec2(origin.x, y), width, if (result) |r| r.model.matrix else model.identity_matrix);
    y += gui.px(12);
    _ = drawMeasures(list, gui.vec2(origin.x, y), width, own);

    // The buttons at the bottom.
    const bottom = c.ImGui_GetWindowPos().y + c.ImGui_GetWindowHeight() - gui.px(model_padding);
    const save_top = bottom - gui.px(34);
    const fit_top = save_top - gui.px(8 + 40);
    c.ImGui_SetCursorScreenPos(gui.vec2(origin.x, fit_top));
    var fitted: usize = 0;
    for (own.pairs.items, own.prepared.items) |p, prepared| fitted += @intFromBool(!p.held_out and linedUp(p) and prepared != null);
    c.ImGui_BeginDisabled(busy or fitted == 0);
    if (gui.buttonOf(.primary, if (busy and state.doing == .fitting) "Fitting…" else "Fit look", gui.vec2(width / gui.scale, 40))) state.startFit(ctx, look);
    c.ImGui_EndDisabled();
    if (c.ImGui_IsItemHovered(c.ImGuiHoveredFlags_AllowWhenDisabled)) {
        c.ImGui_SetTooltip(if (fitted == 0) "Needs a pair lined up and not held out" else "Fits the curves, then the matrix, then the LUT if asked, and checks them on the held-out pairs");
    }
    c.ImGui_SetCursorScreenPos(gui.vec2(origin.x, save_top));
    if (gui.buttonOf(.outline, "Save as .cube and curves", gui.vec2(width / gui.scale, 34))) {
        if (result == null) ctx.notice.set("Fit the look first, then save it.", .{}) else saveLook(ctx, own);
    }
    if (c.ImGui_IsItemHovered(c.ImGuiHoveredFlags_AllowWhenDisabled)) {
        c.ImGui_SetTooltip(gui.print("Writes look.json (curves and matrix), look.cube (the whole look) and the LUT, if any, to Looks/{s} in the library", .{own.name}));
    }
}

fn saveLook(ctx: context.Context, own: *Own) void {
    const result = &(own.result orelse return);
    looks.saved.save(ctx.gpa, ctx.io, own.path, own.name, result) catch |err| {
        ctx.notice.set("Can't save {s}: {t}.", .{ own.name, err });
        return;
    };
    own.saved = true;
    own.kept = true;
    if (negscan.look.Id.ofFitted(std.fs.path.basename(own.path))) |id| ctx.library.lookChanged(ctx.gpa, id) else |_| {}
    ctx.notice.set("Saved {s}: look.json and look.cube{s} in Looks/{s}.", .{ own.name, if (result.lut != null) ", residual.cube" else "", own.name });
}

fn lutNote(own: *const Own) []const u8 {
    const r = own.result orelse return "33 × 33 × 33. Only if the residual shows structure.";
    return switch (r.report.lut) {
        .not_asked => "33 × 33 × 33. Only if the residual shows structure.",
        .kept => gui.print("33 × 33 × 33. Kept: out of fold it took away {d:.0}% of the error left.", .{r.report.lut_gain * 100}),
        .no_structure => "33 × 33 × 33. Left out: the residual is noise, out of fold.",
        .too_few_pairs => "33 × 33 × 33. Left out: trying it takes two fitted pairs.",
    };
}

/// The width the text of a model option wraps at, and its height.
fn optionHeight(width: f32, note: []const u8) f32 {
    return line(13) + paragraphHeight(width - gui.px(13 + 8), note);
}

/// A choice of the model: a check box, its name, and a note under it. Returns its height when
/// it was clicked.
fn modelOption(list: *c.ImDrawList, at: gui.Vec2, width: f32, checked: *bool, name: []const u8, note: []const u8, disabled: bool) ?f32 {
    const height = optionHeight(width, note);
    c.ImGui_SetCursorScreenPos(at);
    c.ImGui_BeginDisabled(disabled);
    const clicked = c.ImGui_InvisibleButton("option", gui.vec2(width, height), 0);
    c.ImGui_EndDisabled();
    const hovered = c.ImGui_IsItemHovered(0);
    if (clicked) checked.* = !checked.*;

    const box = gui.px(13);
    const min = gui.vec2(at.x, at.y + gui.px(3));
    const max = gui.vec2(min.x + box, min.y + box);
    if (checked.*) {
        c.ImDrawList_AddRectFilledEx(list, min, max, theme.imU32(theme.accent), gui.px(3), 0);
        const ink = theme.imU32(theme.on_accent);
        c.ImDrawList_AddLineEx(list, gui.vec2(min.x + gui.px(3), min.y + gui.px(6.5)), gui.vec2(min.x + gui.px(5.5), min.y + gui.px(9.5)), ink, gui.px(1.8));
        c.ImDrawList_AddLineEx(list, gui.vec2(min.x + gui.px(5.5), min.y + gui.px(9.5)), gui.vec2(min.x + gui.px(10), min.y + gui.px(3.5)), ink, gui.px(1.8));
    } else {
        c.ImDrawList_AddRectFilledEx(list, min, max, theme.imU32(if (hovered) theme.control_hover else theme.control), gui.px(3), 0);
        c.ImDrawList_AddRectEx(list, min, max, theme.imU32(theme.border), gui.px(3), 1, 0);
    }
    const x = at.x + box + gui.px(8);
    textIn(list, gui.vec2(x, at.y), line(13), theme.text, name);
    _ = paragraph(list, gui.vec2(x, at.y + line(13)), width - box - gui.px(8), theme.text_tertiary, note);
    return if (clicked) height else null;
}

/// What a built-in look is made of, as the model options are laid out, without check boxes.
/// Returns the y below.
fn drawStages(list: *c.ImDrawList, at: gui.Vec2, width: f32, stages: []const [2][]const u8) f32 {
    var y = at.y;
    for (stages, 0..) |stage, i| {
        if (i > 0) y += gui.px(8);
        const box = gui.px(13);
        c.ImDrawList_AddCircleFilled(list, gui.vec2(at.x + box / 2, y + gui.px(3) + box / 2), gui.px(2.5), theme.imU32(theme.text_tertiary), 12);
        const x = at.x + box + gui.px(8);
        textIn(list, gui.vec2(x, y), line(13), theme.text, stage[0]);
        y += line(13);
        y += paragraph(list, gui.vec2(x, y), width - box - gui.px(8), theme.text_tertiary, stage[1]);
    }
    return y;
}

/// What a chart of curves shows.
const Chart = union(enum) {
    /// Neutral's inversion curve with Develop's default settings.
    neutral,
    /// A fitted look's channel curves.
    fitted: *const [3]model.Curve,
    /// A look not fitted yet: the identity.
    identity,

    fn label(chart: Chart) []const u8 {
        return switch (chart) {
            .neutral => "default settings",
            .fitted => "fitted, 33 points each",
            .identity => "identity, not fitted",
        };
    }
};

/// `chart` as the design draws it: curves over density in, 300 × 180 units scaled to `width`.
/// Returns the y below.
fn drawChart(list: *c.ImDrawList, at: gui.Vec2, width: f32, chart: Chart) f32 {
    const k = width / 300;
    const height = 180 * k;
    const p = struct {
        fn at_(o: gui.Vec2, scale: f32, x: f32, y: f32) gui.Vec2 {
            return gui.vec2(o.x + x * scale, o.y + y * scale);
        }
    }.at_;
    c.ImDrawList_AddRectFilledEx(list, at, gui.vec2(at.x + width, at.y + height), theme.imU32(theme.histogram_ground), gui.px(4), 0);
    const axis = theme.imU32(theme.border);
    c.ImDrawList_AddLineEx(list, p(at, k, 30, 10), p(at, k, 30, 160), axis, k);
    c.ImDrawList_AddLineEx(list, p(at, k, 30, 160), p(at, k, 290, 160), axis, k);

    const plot = struct {
        fn point(o: gui.Vec2, scale: f32, x: f32, y: f32) gui.Vec2 {
            return gui.vec2(o.x + (30 + 260 * x) * scale, o.y + (160 - 150 * std.math.clamp(y, 0, 1)) * scale);
        }
    }.point;
    switch (chart) {
        .fitted => |cs| {
            const colours = [_]theme.Color{ theme.red, theme.green, theme.blue };
            for (cs, colours) |*cv, colour| {
                var points: [curve.points]gui.Vec2 = undefined;
                for (&points, cv, 0..) |*pt, v, i| pt.* = plot(at, k, @as(f32, @floatFromInt(i)) / (curve.points - 1), v);
                c.ImDrawList_AddPolyline(list, &points, points.len, theme.imU32(colour), 1.5 * k, 0);
            }
        },
        .neutral => {
            // Neutral's inversion curve with Develop's default settings, the film base at full
            // transmission.
            const prepared: negscan.develop.Prepared = .init(.{});
            var points: [65]gui.Vec2 = undefined;
            for (&points, 0..) |*pt, i| {
                const x = @as(f32, @floatFromInt(i)) / 64;
                const t = std.math.pow(f32, 10, -x * (negscan.develop.Settings{}).density_range);
                const raw: u16 = @intFromFloat(@round(t * negscan.image.full_scale));
                const out = negscan.develop.pixel(prepared, .{ raw, raw, raw });
                pt.* = plot(at, k, x, negscan.encode.srgb(out[1]));
            }
            c.ImDrawList_AddPolyline(list, &points, points.len, theme.imU32(theme.text_secondary), 1.5 * k, 0);
        },
        .identity => gui.dashedLine(list, p(at, k, 30, 160), p(at, k, 290, 10), theme.imU32(theme.text_tertiary), 1.5 * k, 4 * k, 4 * k),
    }

    fonts.pushSized(.mono, 10 * k);
    const small = theme.imU32(theme.text_tertiary);
    const baseline = ascent();
    const density_in = "density in";
    const size = c.ImGui_CalcTextSize(density_in);
    c.ImDrawList_AddText(list, gui.vec2(at.x + 160 * k - size.x / 2, at.y + 176 * k - baseline), small, density_in);
    // "out", turned to read upwards: drawn level, then its vertices turned about its anchor.
    const out_size = c.ImGui_CalcTextSize("out");
    const anchor = p(at, k, 12, 90);
    const first = list.*.VtxBuffer.Size;
    c.ImDrawList_AddText(list, gui.vec2(anchor.x - out_size.x / 2, anchor.y - baseline), small, "out");
    const vertices = list.*.VtxBuffer.Data;
    var i: c_int = first;
    while (i < list.*.VtxBuffer.Size) : (i += 1) {
        const v = &vertices[@intCast(i)];
        const dx = v.pos.x - anchor.x;
        const dy = v.pos.y - anchor.y;
        v.pos = gui.vec2(anchor.x + dy, anchor.y - dx);
    }
    fonts.pop();
    // The label at the top right, as the design has it, or at the top left, out of the fitted
    // curves' way.
    fonts.pushSized(.regular, 11 * k);
    const label = gui.print("{s}", .{chart.label()});
    const label_size = c.ImGui_CalcTextSize(label);
    const label_x = if (chart == .fitted) at.x + 40 * k else at.x + 286 * k - label_size.x;
    c.ImDrawList_AddText(list, gui.vec2(label_x, at.y + 24 * k - ascent()), theme.imU32(theme.text_secondary), label);
    fonts.pop();
    return at.y + height;
}

/// How far below the top of a line of text its baseline is, for placing text the way SVG does,
/// by its baseline: about 0.78 of the size for both fonts (ImGui's font data is opaque here).
fn ascent() f32 {
    return c.ImGui_GetFontSize() * 0.78;
}

/// The density matrix, three by three. Returns the y below.
fn drawMatrix(list: *c.ImDrawList, at: gui.Vec2, width: f32, matrix: model.Matrix) f32 {
    const gap = gui.px(4);
    const cell_width = (width - 2 * gap) / 3;
    const cell_height = gui.px(12) + line(12);
    fonts.pushSized(.mono, 12);
    defer fonts.pop();
    for (matrix, 0..) |row, r| {
        for (row, 0..) |v, col| {
            const min = gui.vec2(at.x + (cell_width + gap) * @as(f32, @floatFromInt(col)), at.y + (cell_height + gap) * @as(f32, @floatFromInt(r)));
            c.ImDrawList_AddRectFilledEx(list, min, gui.vec2(min.x + cell_width, min.y + cell_height), theme.imU32(theme.raised), gui.px(3), 0);
            const shown = if (v < -0.0005) gui.print("−{d:.3}", .{-v}) else gui.print("{d:.3}", .{@abs(v)});
            const size = c.ImGui_CalcTextSize(shown);
            textIn(list, gui.vec2(min.x + (cell_width - size.x) / 2, min.y + gui.px(6)), line(12), if (r == col) theme.text else theme.text_tertiary, shown);
        }
    }
    return at.y + 3 * cell_height + 2 * gap;
}

/// The held-out ΔE2000. Returns the y below.
fn drawMeasures(list: *c.ImDrawList, at: gui.Vec2, width: f32, own: *const Own) f32 {
    const rows = [_][]const u8{ "Held-out ΔE2000, median", "Held-out ΔE2000, 95th percentile" };
    var values: [2][]const u8 = .{ "[after fit]", "[after fit]" };
    if (own.result) |r| {
        if (r.report.median) |m| {
            values = .{ gui.print("{d:.2}", .{m}), gui.print("{d:.2}", .{r.report.p95.?}) };
        } else values = .{ "no pair held out", "no pair held out" };
    }
    const height = gui.px(20 + 6) + 2 * line(13);
    c.ImDrawList_AddRectFilledEx(list, at, gui.vec2(at.x + width, at.y + height), theme.imU32(theme.raised), gui.px(5), 0);
    for (rows, values, 0..) |label, value, i| {
        const y = at.y + gui.px(10) + (line(13) + gui.px(6)) * @as(f32, @floatFromInt(i));
        textIn(list, gui.vec2(at.x + gui.px(10), y), line(13), theme.text_secondary, label);
        fonts.push(.mono);
        const w = textWidth(value);
        textIn(list, gui.vec2(at.x + width - gui.px(10) - w, y), line(13), theme.text, value);
        fonts.pop();
    }
    if (own.result) |r| {
        if (own.stale) {
            _ = paragraph(list, gui.vec2(at.x, at.y + height + gui.px(6)), width, theme.text_tertiary, "The pairs or the model changed since this fit.");
        } else {
            const note = gui.print("{d} {s} fitted, {d} held out; fitted pairs' median {d:.2}.", .{ r.report.fitted_pairs, if (r.report.fitted_pairs == 1) "pair" else "pairs", r.report.held_out_pairs, r.report.fitted_median });
            _ = paragraph(list, gui.vec2(at.x, at.y + height + gui.px(6)), width, theme.text_tertiary, note);
        }
    }
    return at.y + height;
}

test {
    _ = looks;
}
