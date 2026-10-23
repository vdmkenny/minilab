//! The Looks workspace: the looks a frame can be developed with, and making your own look from
//! pairs of images. Each pair is our raw scan of a negative and a reference rendering of the same
//! negative, such as a lab's Frontier or Noritsu scan. See the design's Looks.dc.html.
//!
//! The work itself is in src/looks. Reading, lining up and fitting run off the page's thread
//! (`looks.work`): the page starts a job, shows how far it's got, and picks up the results when
//! it's done.

const std = @import("std");
const c = @import("c");
const minilab = @import("minilab");
const gui = @import("../ui/gui.zig");
const theme = @import("../ui/theme.zig");
const fonts = @import("../ui/fonts.zig");
const context = @import("context.zig");
const shortcuts = @import("shortcuts.zig");
const labels = @import("labels.zig");
const Texture = @import("../platform/texture.zig").Texture;
const Library = @import("library.zig").Library;
const bundled = minilab.bundled_looks;
const looks = minilab.looks;

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
/// The width of the label column next to a collection's credit and licence.
const pack_label_width = 90;
/// How long the longer side of the Develop frame is in the previews.
const preview_longest = 360;
/// The tallest a single look's preview is drawn.
const preview_max_height = 320;
/// How many previews to render each frame, so a collection's previews fill in without holding up
/// the page.
const previews_per_frame = 3;
/// The narrowest and the tallest tile in a collection's grid of previews.
const tile_min_width = 150;
const tile_max_height = 170;
/// The height of the buttons under a look's preview.
const use_button_height = 30;
/// The gap between preview tiles.
const tile_gap = 10;
/// The figures are 3:2.
const figure_ratio = 2.0 / 3.0;
/// The figures' images are at most this many pixels across.
const view_longest = 640;

/// A registration at least this good counts as lined up, and one below the second value as not
/// lined up.
const aligned_quality = 0.8;
const poor_quality = 0.5;

/// Which look is shown.
const Selected = union(enum) {
    neutral,
    frontier,
    /// A collection of bundled looks.
    pack: bundled.Pack,
    /// An imported LUT, as an index into `State.imported`.
    imported: usize,
    own: usize,
};

/// One of the user's own looks, in the library's Looks folder.
const Own = struct {
    name: []u8,
    path: []u8,
    /// Whether look.json exists, so Develop can use the look.
    saved: bool,
    /// Holds the pairs' strings.
    arena: std.heap.ArenaAllocator,
    references: draft.Source = .frontier_software,
    options: fit.Options = .{},
    pairs: std.ArrayList(draft.Pair) = .empty,
    /// Each pair once it's been read (`prepared`), and whether it couldn't be read (`failed`).
    prepared: std.ArrayList(?*pairs.Prepared) = .empty,
    failed: std.ArrayList(bool) = .empty,
    /// Each pair's balance offsets from the last fit.
    balance: std.ArrayList([3]f32) = .empty,
    result: ?fit.Result = null,
    /// Whether the pairs or the choices have changed since the fit.
    stale: bool = false,
    /// Whether the current fit is the one that's saved.
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

    /// Adds `pair`, with copies of its strings.
    fn append(own: *Own, gpa: std.mem.Allocator, pair: draft.Pair) !void {
        const a = own.arena.allocator();
        var copy = pair;
        copy.ours = try a.dupe(u8, pair.ours);
        copy.label = try a.dupe(u8, pair.label);
        copy.theirs = try a.dupe(u8, pair.theirs);
        copy.stock = if (pair.stock) |s| try a.dupe(u8, s) else null;
        // The four lists stay in step, so make room in all of them first.
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

    /// Holds pair `index` out of the fit, or uses it again, and saves the look.
    fn toggleHeldOut(own: *Own, ctx: context.Context, index: usize) void {
        const pair = &own.pairs.items[index];
        pair.held_out = !pair.held_out;
        own.changed();
        own.save(ctx);
    }

    /// Writes the look's file. A failure goes in the header's notice, since every edit relies on
    /// this.
    fn save(own: *const Own, ctx: context.Context) void {
        draft.save(ctx.gpa, ctx.io, own.path, .{ .references = own.references, .options = own.options, .pairs = own.pairs.items }) catch |err| {
            std.log.err("can't save the look {s}: {t}", .{ own.name, err });
            ctx.notice.set("{s} not saved · {t}", .{ own.name, err });
        };
    }

    fn heldOut(own: *const Own) usize {
        var n: usize = 0;
        for (own.pairs.items) |p| n += @intFromBool(p.held_out);
        return n;
    }

    /// How many pairs haven't been read yet but can be.
    fn unread(own: *const Own) usize {
        var n: usize = 0;
        for (own.prepared.items, own.failed.items) |p, f| n += @intFromBool(p == null and !f);
        return n;
    }

    /// The badge: Saved once look.json holds the current fit, Fitted when there's a fit that isn't
    /// saved yet, and Draft before that (or once the fit is out of date).
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
    /// The pair's median ΔE2000 after the fit, when there is a fit.
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

/// The frame that's open in Develop, rendered with Neutral and the selected look, or with each
/// look in the selected collection. They show what a look does to a picture before you use it.
const Previews = struct {
    key: ?Key = null,
    /// A reduced copy of the frame, and its settings in Develop.
    small: ?minilab.image.Scan = null,
    settings: minilab.develop.Settings = .{},
    /// The looks shown, Neutral first, and their renders as they're made.
    ids: std.ArrayList(minilab.look.Id) = .empty,
    tiles: std.ArrayList(Tile) = .empty,

    /// What the previews were made from. When it changes, they're made again.
    const Key = struct {
        selected: Selected,
        pixels: [*]const [3]u16,
        width: usize,
        height: usize,
        settings: minilab.develop.Settings,
    };

    const Tile = union(enum) { waiting, ready: Texture, failed };

    fn start(p: *Previews, gpa: std.mem.Allocator, key: Key, preview: minilab.image.Scan, ids: []const minilab.look.Id) !void {
        p.key = key;
        p.small = try minilab.image.downscale(gpa, preview, preview_longest);
        p.settings = key.settings;
        try p.ids.appendSlice(gpa, ids);
        try p.tiles.appendNTimes(gpa, .waiting, ids.len);
    }

    /// Renders the next few looks.
    fn renderSome(p: *Previews, ctx: context.Context) void {
        const small = p.small orelse return;
        var made: usize = 0;
        for (p.ids.items, p.tiles.items) |id, *tile| {
            if (tile.* != .waiting) continue;
            if (made == previews_per_frame) return;
            made += 1;
            tile.* = if (renderPreview(ctx, small, p.settings, id)) |made_texture| .{ .ready = made_texture } else |err| failed: {
                std.log.err("can't preview the look {s}: {t}", .{ id.label(), err });
                break :failed .failed;
            };
        }
    }

    /// The render of `ids[index]`, once it's made.
    fn texture(p: *const Previews, index: usize) ?Texture {
        return switch (p.tiles.items[index]) {
            .ready => |t| t,
            .waiting, .failed => null,
        };
    }

    fn release(p: *Previews, gpa: std.mem.Allocator, gpu: *c.SDL_GPUDevice) void {
        for (p.tiles.items) |*tile| switch (tile.*) {
            .ready => |*t| t.release(gpu),
            .waiting, .failed => {},
        };
        p.tiles.clearRetainingCapacity();
        p.ids.clearRetainingCapacity();
        if (p.small) |*s| s.deinit(gpa);
        p.small = null;
        p.key = null;
    }

    fn deinit(p: *Previews, gpa: std.mem.Allocator, gpu: *c.SDL_GPUDevice) void {
        p.release(gpa, gpu);
        p.ids.deinit(gpa);
        p.tiles.deinit(gpa);
    }
};

/// Renders `small` with `settings` and the look `id`, and puts the result on the GPU.
fn renderPreview(ctx: context.Context, small: minilab.image.Scan, settings: minilab.develop.Settings, id: minilab.look.Id) !Texture {
    const gpa = ctx.gpa;
    var linear = try minilab.look.render(gpa, small, settings, try ctx.library.looks.resolve(gpa, ctx.io, id));
    defer linear.deinit(gpa);
    const rgba = try gpa.alloc([4]u8, linear.pixels.len);
    defer gpa.free(rgba);
    minilab.encode.toRgba8(linear, rgba);
    return .upload(ctx.gpu, @intCast(small.width), @intCast(small.height), rgba);
}

const file_dialog = @import("../platform/file_dialog.zig");
const Dialog = file_dialog.Dialog;

/// The file types "Add pairs" lets you pick.
const pair_files = [_]c.SDL_DialogFileFilter{
    .{ .name = "Scans and references (PPM, JPEG, TIFF)", .pattern = "ppm;jpg;jpeg;tif;tiff" },
};

/// What a job is doing, for the line under the references.
const Doing = enum { reading, matching, fitting };

pub const State = struct {
    loaded: bool = false,
    own: std.ArrayList(Own) = .empty,
    /// The LUTs imported into the library's Looks folder.
    imported: std.ArrayList(minilab.look.Id) = .empty,
    cube_dialog: Dialog = .{ .filters = &file_dialog.cube_files, .many = true },
    selected: Selected = .neutral,
    /// The selected pair of the selected look.
    pair: usize = 0,
    job: ?*work.Job = null,
    /// The look the job is working on, and what it's doing.
    job_look: usize = 0,
    doing: Doing = .reading,
    /// For a fit: each pair's place in the job's list.
    job_pairs: std.ArrayList(usize) = .empty,
    dialog: Dialog = .{ .filters = &pair_files, .many = true },
    figures: Figures = .{},
    previews: Previews = .{},
    /// Counts fits, so the figures know when to work out the difference again.
    generation: u32 = 0,
    rename: [128:0]u8 = @splat(0),

    pub fn deinit(state: *State, gpa: std.mem.Allocator, gpu: *c.SDL_GPUDevice) void {
        state.imported.deinit(gpa);
        state.cube_dialog.deinit(gpa);
        if (state.job) |j| j.finish(true);
        state.job = null;
        state.job_pairs.deinit(gpa);
        state.figures.release(gpu);
        state.previews.deinit(gpa, gpu);
        for (state.own.items) |*o| o.deinit(gpa);
        state.own.deinit(gpa);
        state.dialog.deinit(gpa);
    }

    /// Whether previews are still waiting to be rendered, a few each frame.
    pub fn rendering(state: *const State) bool {
        for (state.previews.tiles.items) |tile| if (tile == .waiting) return true;
        return false;
    }

    /// Whether everything on the page has loaded. A screenshot waits for this.
    pub fn settled(state: *const State) bool {
        if (!state.loaded or state.job != null or state.rendering()) return false;
        const own = state.current() orelse return true;
        if (own.unread() > 0) return false;
        if (state.pair >= own.pairs.items.len) return true;
        if (own.prepared.items[state.pair] == null) return true;
        return state.figures.key != null;
    }

    /// Adds `paths` (scans and references) to the selected look as pairs. It's for files dropped
    /// on the window while this page is showing. Our raw scans are PPM files, and references are
    /// JPEG or TIFF. References without a scan are matched to the frames of the roll open in
    /// Develop, or of the whole library.
    pub fn addFiles(state: *State, ctx: context.Context, paths: []const []const u8) void {
        const index = switch (state.selected) {
            .own => |i| i,
            else => {
                ctx.notice.set("Not a look of your own", .{});
                return;
            },
        };
        if (state.job != null) {
            ctx.notice.set("Busy", .{});
            return;
        }
        var ours: std.ArrayList([]const u8) = .empty;
        defer ours.deinit(ctx.gpa);
        var theirs: std.ArrayList([]const u8) = .empty;
        defer theirs.deinit(ctx.gpa);
        for (paths) |p| {
            if (minilab.input.Kind.of(p) == .pnm) {
                ours.append(ctx.gpa, p) catch return;
            } else if (isReference(p)) {
                theirs.append(ctx.gpa, p) catch return;
            }
        }
        if (theirs.items.len == 0) {
            ctx.notice.set("No references · JPEG or TIFF", .{});
            return;
        }
        const own = &state.own.items[index];
        if (ours.items.len > 0) {
            if (ours.items.len != theirs.items.len) {
                ctx.notice.set("{d} scans, {d} references · counts differ", .{ ours.items.len, theirs.items.len });
                return;
            }
            // Pair them up in name order.
            std.mem.sort([]const u8, ours.items, {}, byName);
            std.mem.sort([]const u8, theirs.items, {}, byName);
            var added: usize = 0;
            for (ours.items, theirs.items) |o, t| {
                const where = findFrame(ctx.library, o);
                own.append(ctx.gpa, .{
                    .ours = o,
                    .label = if (where) |w| w.label else std.fs.path.basename(o),
                    .theirs = t,
                    .stock = if (where) |w| w.stock else null,
                    .held_out = draft.heldOutByDefault(own.pairs.items.len),
                    .placement = if (where) |w| w.placement else null,
                }) catch |err| {
                    ctx.notice.set("Added {d} of {d} pairs · {t}", .{ added, ours.items.len, err });
                    break;
                };
                added += 1;
            } else ctx.notice.set("Added {d} pairs to {s}", .{ added, own.name });
            // Keep what was added, even when the rest wasn't.
            if (added > 0) own.save(ctx);
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
        // The page opens on the user's own looks, since that's where the work is.
        if (state.own.items.len > 0) state.selected = .{ .own = 0 };
    }

    /// Reads the list of imported LUTs again.
    fn listImported(state: *State, ctx: context.Context) void {
        state.imported.clearRetainingCapacity();
        // Whatever happens below, a selected LUT that's no longer on the list gets unselected.
        defer if (state.selected == .imported and state.selected.imported >= state.imported.items.len) {
            state.selected = .neutral;
        };
        var choices = ctx.library.looks.choices(ctx.gpa, ctx.io) catch return;
        defer choices.deinit(ctx.gpa);
        for (choices.items) |choice| {
            if (choice.group == .imported) state.imported.append(ctx.gpa, choice.id) catch return;
        }
    }

    /// Imports the chosen .cube files, and selects the last one.
    fn importCubes(state: *State, ctx: context.Context, paths: []const []const u8) void {
        const id = ctx.importCubes(paths) orelse return;
        state.listImported(ctx);
        for (state.imported.items, 0..) |*i, n| if (i.eql(&id)) select(state, .{ .imported = n });
        ctx.notice.set("Imported {s}", .{id.label()});
    }

    /// Deletes the selected imported LUT from the library.
    fn removeImported(state: *State, ctx: context.Context, index: usize) void {
        const id = state.imported.items[index];
        ctx.library.looks.remove(ctx.gpa, ctx.io, id) catch |err| {
            ctx.notice.set("Can't remove {s} · {t}", .{ id.label(), err });
            return;
        };
        ctx.library.lookChanged(ctx.gpa, id);
        ctx.notice.set("Removed {s}", .{id.label()});
        state.listImported(ctx);
        state.selected = .neutral;
    }

    /// Picks up a finished job's results, and starts reading the selected look's pairs if they
    /// haven't been read yet.
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
                    // Skip items left unset because memory ran out.
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
                if (aligned) own.save(ctx);
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
                if (added > 0) own.save(ctx);
                if (task.failure) |err| {
                    ctx.notice.set("Matching stopped · {t}", .{err});
                } else if (added == task.references.len) {
                    ctx.notice.set("Found frames for all {d} references", .{added});
                } else {
                    ctx.notice.set("Found frames for {d} of {d} references", .{ added, task.references.len });
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
                    ctx.notice.set("Fit failed · {t}", .{err});
                }
            },
        }
    }

    /// Finds the frames that `references` show, among the frames of the roll open in Develop, or
    /// of every roll if none is open.
    fn startMatch(state: *State, ctx: context.Context, look: usize, references: []const []const u8) void {
        const library = ctx.library;
        const open = ctx.develop.rollIndex(library);
        var count: usize = 0;
        for (library.rolls.items, 0..) |r, i| {
            if (open == null or open == i) count += r.frames.items.len;
        }
        if (count == 0) {
            ctx.notice.set("No frames to match", .{});
            return;
        }
        var task = work.Match.init(ctx.gpa, references, count) catch |err| {
            ctx.notice.set("Can't match · {t}", .{err});
            return;
        };
        var n: usize = 0;
        for (library.rolls.items, 0..) |*r, i| {
            if (open != null and open != i) continue;
            for (0..r.frames.items.len) |f| {
                const path = r.scanPath(ctx.gpa, f) catch continue;
                defer ctx.gpa.free(path);
                const thumbnail = r.thumbnailPath(ctx.gpa, f) catch continue;
                defer ctx.gpa.free(thumbnail);
                task.setFrame(ctx.gpa, n, path, thumbnail, labels.rollFrame(r.info.name, f), r.info.stock, placementOf(r, f)) catch continue;
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

    /// Makes a new look, "Look N", with no pairs yet, and selects it.
    /// Adds an empty look called `name` to the list, with its folder in the library's Looks.
    fn makeLook(state: *State, ctx: context.Context, name: []const u8) !*Own {
        const root = try looks.saved.folderOf(ctx.gpa, ctx.library.path);
        defer ctx.gpa.free(root);
        const path = try std.fs.path.join(ctx.gpa, &.{ root, name });
        defer ctx.gpa.free(path);
        var own = try Own.open(ctx.gpa, ctx.io, .{ .name = @constCast(name), .path = path, .saved = false });
        errdefer own.deinit(ctx.gpa);
        try state.own.append(ctx.gpa, own);
        return &state.own.items[state.own.items.len - 1];
    }

    fn newLook(state: *State, ctx: context.Context) void {
        var number: usize = state.own.items.len + 1;
        const name = while (true) : (number += 1) {
            const candidate = gui.print("Look {d}", .{number});
            for (state.own.items) |o| {
                if (std.ascii.eqlIgnoreCase(o.name, candidate)) break;
            } else break candidate;
        };
        const own = state.makeLook(ctx, name) catch |err| {
            std.log.err("can't make the look {s}: {t}", .{ name, err });
            ctx.notice.set("Can't make a look · {t}", .{err});
            return;
        };
        own.save(ctx);
        state.selected = .{ .own = state.own.items.len - 1 };
        state.pair = 0;
        ctx.notice.set("Made {s}", .{name});
    }

    fn renameLook(state: *State, ctx: context.Context, index: usize, name: []const u8) void {
        const own = &state.own.items[index];
        if (name.len == 0 or std.mem.eql(u8, name, own.name)) return;
        if (std.mem.indexOfAny(u8, name, "/\\:") != null) {
            ctx.notice.set("Invalid name", .{});
            return;
        }
        const parent = std.fs.path.dirname(own.path) orelse return;
        const path = std.fs.path.join(ctx.gpa, &.{ parent, name }) catch return;
        const cwd = std.Io.Dir.cwd();
        cwd.rename(own.path, cwd, path, ctx.io) catch |err| {
            ctx.gpa.free(path);
            ctx.notice.set("Can't rename the look · {t}", .{err});
            return;
        };
        const old_id = minilab.look.Id.ofFitted(std.fs.path.basename(own.path)) catch null;
        ctx.gpa.free(own.path);
        own.path = path;
        const copy = ctx.gpa.dupe(u8, name) catch return;
        ctx.gpa.free(own.name);
        own.name = copy;
        // Frames refer to their look by its folder name, so they're updated to the new name.
        const old = old_id orelse return;
        const new = minilab.look.Id.ofFitted(name) catch return;
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

    /// Puts the selected pair's images on the GPU when they've changed.
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

    /// Starts the previews over when the selection or the frame in Develop has changed, and
    /// renders the next few. A fitted look shows its pairs instead.
    fn refreshPreviews(state: *State, ctx: context.Context) void {
        ctx.develop.ensureFrame(ctx.gpa, ctx.io, ctx.library);
        const frame = if (ctx.develop.frame) |*f| f else return state.previews.release(ctx.gpa, ctx.gpu);
        var buffer: [bundled.looks.len + 1]minilab.look.Id = undefined;
        const ids = state.previewIds(&buffer);
        if (ids.len == 0) return state.previews.release(ctx.gpa, ctx.gpu);
        const key: Previews.Key = .{
            .selected = state.selected,
            .pixels = frame.preview.pixels.ptr,
            .width = frame.preview.width,
            .height = frame.preview.height,
            .settings = frame.settings,
        };
        const same = if (state.previews.key) |k| std.meta.eql(k, key) else false;
        if (!same) {
            state.previews.release(ctx.gpa, ctx.gpu);
            state.previews.start(ctx.gpa, key, frame.preview, ids) catch |err| {
                std.log.err("can't preview the looks: {t}", .{err});
                return state.previews.release(ctx.gpa, ctx.gpu);
            };
        }
        state.previews.renderSome(ctx);
    }

    /// The looks to preview for the selection, Neutral first. A fitted look has none.
    fn previewIds(state: *const State, buffer: []minilab.look.Id) []minilab.look.Id {
        buffer[0] = .neutral;
        var n: usize = 1;
        switch (state.selected) {
            .neutral => {},
            .frontier => {
                buffer[n] = .frontier;
                n += 1;
            },
            .imported => |i| {
                buffer[n] = state.imported.items[i];
                n += 1;
            },
            .pack => |pack| for (bundled.looks, 0..) |b, i| if (b.pack == pack) {
                buffer[n] = .ofBundled(i);
                n += 1;
            },
            .own => return buffer[0..0],
        }
        return buffer[0..n];
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
    // Only count where the reference covers our frame. Elsewhere there's nothing to compare.
    var covered: usize = 0;
    for (errors, v.reference) |e, r| if (r[3] != 0) {
        errors[covered] = e;
        covered += 1;
    };
    state.figures.median = minilab.stats.median(errors[0..covered]);
}

/// A colour for a ΔE2000 value: near black where the look matches, through grey and amber, to
/// red from about 12 upwards.
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

/// Whether `path` is a lab's reference picture: a JPEG or a TIFF.
fn isReference(path: []const u8) bool {
    return switch (minilab.input.Kind.of(path)) {
        .jpeg, .tiff => true,
        .pnm, .camera_raw => false,
    };
}

/// Whether the pair's reference lined up well enough to fit from. A poor registration would
/// compare our colours with the wrong parts of theirs.
fn linedUp(pair: draft.Pair) bool {
    const alignment = pair.alignment orelse return false;
    return alignment.quality >= poor_quality;
}

/// Sorts by file name, comparing numbers by their value, so `fr_2.jpg` comes before `fr_10.jpg`
/// just as `02.ppm` comes before `10.ppm`.
fn byName(_: void, a: []const u8, b: []const u8) bool {
    return minilab.input.naturalLess({}, std.fs.path.basename(a), std.fs.path.basename(b));
}

/// What the Use column says for `pair`.
fn useLabel(pair: draft.Pair) []const u8 {
    return if (pair.held_out) "Held out" else "Fit";
}

/// Finds the roll frame whose raw scan is at `path`, with the name the table uses for it.
fn findFrame(library: *Library, path: []const u8) ?struct { label: []const u8, stock: ?[]const u8, placement: draft.Placement } {
    for (library.rolls.items) |*r| {
        if (!std.mem.startsWith(u8, path, r.path)) continue;
        for (0..r.frames.items.len) |i| {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
            const scan = r.scanPath(fixed.allocator(), i) catch continue;
            if (std.mem.eql(u8, scan, path)) return .{ .label = labels.rollFrame(r.info.name, i), .stock = r.info.stock, .placement = placementOf(r, i) };
        }
    }
    return null;
}

/// Where frame `index` of `r` sits on its scan, and its film base, as the roll records them.
fn placementOf(r: *const minilab.roll.Roll, index: usize) draft.Placement {
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
    state.refreshPreviews(ctx);

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

fn textWidth(value: []const u8) f32 {
    return c.ImGui_CalcTextSize(gui.print("{s}", .{value})).x;
}

// The list of looks.

fn drawList(state: *State, ctx: context.Context) void {
    const list = c.ImGui_GetWindowDrawList();
    const origin = c.ImGui_GetCursorScreenPos();
    const width = c.ImGui_GetContentRegionAvail().x;
    var y = origin.y;

    // In groups, the same as Develop's Look menu.
    y = groupHeading(list, origin.x, y, origin.y, "BUILT IN");
    const item_height = gui.px(8 + 8 + 1) + gui.lineFor(13) + gui.lineFor(12) + 2;
    const built_in = [_]struct { Selected, []const u8, []const u8 }{
        .{ .neutral, "Neutral", "Inversion curve" },
        .{ .frontier, "Frontier emulation", "Color LUT, 33³" },
    };
    for (built_in, 0..) |b, i| {
        c.ImGui_PushIDInt(@intCast(i));
        if (lookItem(list, gui.vec2(origin.x, y), width, item_height, b[1], b[2], std.meta.eql(state.selected, b[0]))) select(state, b[0]);
        c.ImGui_PopID();
        y += item_height + gui.px(6);
    }
    y = groupHeading(list, origin.x, y, origin.y, "FILM LOOKS");
    const packs = comptime std.enums.values(bundled.Pack);
    for (packs, 0..) |pack, i| {
        c.ImGui_PushIDInt(@intCast(i + built_in.len));
        const info = pack.info();
        const source = gui.print("{d} looks · {s}", .{ packLooks(pack), info.licence });
        if (lookItem(list, gui.vec2(origin.x, y), width, item_height, info.name, source, std.meta.eql(state.selected, .{ .pack = pack }))) select(state, .{ .pack = pack });
        c.ImGui_PopID();
        y += item_height + gui.px(6);
    }
    if (state.imported.items.len > 0) y = groupHeading(list, origin.x, y, origin.y, "IMPORTED LUTS");
    for (state.imported.items, 0..) |*id, i| {
        c.ImGui_PushIDInt(@intCast(i + built_in.len + packs.len));
        const selected = switch (state.selected) {
            .imported => |s| s == i,
            else => false,
        };
        // Out of memory shows as a look that can't be read, which is what it is for now.
        const resolved = ctx.library.looks.resolve(ctx.gpa, ctx.io, id.*) catch .neutral;
        var buffer: [64]u8 = undefined;
        const size = if (resolved == .lut) resolved.lut.describe(&buffer) else "Can't be read";
        if (lookItem(list, gui.vec2(origin.x, y), width, item_height, id.label(), size, selected)) select(state, .{ .imported = i });
        c.ImGui_PopID();
        y += item_height + gui.px(6);
    }
    if (state.own.items.len > 0) y = groupHeading(list, origin.x, y, origin.y, "FITTED LOOKS");
    for (state.own.items, 0..) |*own, i| {
        c.ImGui_PushIDInt(@intCast(i + built_in.len + packs.len + state.imported.items.len));
        const source = gui.print("{s} · {s}", .{ own.status(), own.references.short() });
        const selected = switch (state.selected) {
            .own => |s| s == i,
            else => false,
        };
        if (lookItem(list, gui.vec2(origin.x, y), width, item_height, own.name, source, selected)) select(state, .{ .own = i });
        c.ImGui_PopID();
        y += item_height + gui.px(6);
    }

    // New look from references, and Import .cube.
    y += gui.px(6);
    const height = gui.px(32);
    if (addButton(list, gui.vec2(origin.x, y), width, height, "New look from references", "Fitted from pairs")) state.newLook(ctx);
    y += height + gui.px(6);
    if (addButton(list, gui.vec2(origin.x, y), width, height, "Import .cube LUT", "3D or 1D · sRGB or Rec. 709")) state.cube_dialog.show(ctx.gpa, ctx.io);
}

/// Draws a button at `at` for adding to the list: a dashed outline, a plus sign and `label`.
/// Returns true when it's clicked.
fn addButton(list: *c.ImDrawList, at: gui.Vec2, width: f32, height: f32, label: [:0]const u8, tooltip: [:0]const u8) bool {
    const far = gui.vec2(at.x + width, at.y + height);
    c.ImGui_SetCursorScreenPos(at);
    const clicked = c.ImGui_InvisibleButton(label, gui.vec2(width, height), 0);
    const hovered = c.ImGui_IsItemHovered(0);
    if (hovered) c.ImDrawList_AddRectFilledEx(list, at, far, theme.imU32(theme.control), gui.px(5), 0);
    gui.dashedRoundedRect(list, at, far, theme.imU32(theme.border), gui.px(5));
    const ink = if (hovered) theme.text else theme.text_secondary;
    gui.plus(list, gui.vec2(at.x + gui.px(10 + 6), at.y + height / 2), gui.px(4.5), gui.px(1.6), ink);
    gui.textIn(list, at.x + gui.px(10 + 12 + 6), at.y, height, ink, label);
    if (hovered) c.ImGui_SetTooltip(tooltip);
    return clicked;
}

/// Draws a group's heading in the list at `y`, with space above it unless it's at the top of the
/// list (`first`). Returns the y below it.
fn groupHeading(list: *c.ImDrawList, x: f32, y: f32, first: f32, label: []const u8) f32 {
    const top = if (y > first) y + gui.px(8) else y;
    fonts.pushSized(.semibold, 12);
    gui.textIn(list, x, top, gui.lineFor(12), theme.text_secondary, label);
    fonts.pop();
    return top + gui.lineFor(12) + gui.px(8);
}

/// Draws one look in the list: its name and where it comes from. Returns true when it's clicked.
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
    // The design's medium weight. Semibold is the nearest weight the app has.
    fonts.push(.semibold);
    gui.textIn(list, x, y, gui.lineFor(13), theme.text, gui.elideEnd(name, width - gui.px(20) - 2));
    fonts.pop();
    y += gui.lineFor(13) + gui.px(1);
    fonts.pushSized(.regular, 12);
    gui.textIn(list, x, y, gui.lineFor(12), theme.text_tertiary, gui.elideEnd(source, width - gui.px(20) - 2));
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
        .neutral => .{ "Neutral", "Built in", "minilab's inversion · film base, density matrix, inversion curve · no added color" },
        .frontier => .{ "Frontier emulation", "Built in", "Fujifilm Frontier color, over Neutral" },
        .pack => |p| .{ p.info().name, "Film looks", p.info().about },
        .imported => |i| .{ state.imported.items[i].label(), "Imported LUT", "LUT over Neutral's sRGB output" },
        .own => |i| .{ state.own.items[i].name, state.own.items[i].status(), switch (state.own.items[i].references) {
            .frontier_software => "Fitted to Frontier software output",
            .lab_scans => "Fitted to lab scans",
        } },
    };

    // The title and its badge, on the same baseline.
    fonts.pushSized(.semibold, 18);
    const title_height = gui.lineFor(18);
    const title_width = textWidth(title);
    gui.textIn(list, origin.x, y, title_height, theme.text, title);
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
    const badge_max = gui.vec2(badge_min.x + badge_width, badge_min.y + gui.lineFor(12) + gui.px(2) + 2);
    c.ImDrawList_AddRectEx(list, badge_min, badge_max, theme.imU32(theme.border), gui.px(10), 1, 0);
    gui.textIn(list, badge_min.x + gui.px(8) + 1, badge_min.y + gui.px(1) + 1, gui.lineFor(12), theme.text_secondary, badge);
    fonts.pop();
    y += title_height + gui.px(4);
    y += gui.paragraphAt(list, origin.x, y, width, theme.text_secondary, description);

    const look = switch (state.selected) {
        .own => |i| i,
        .pack => |p| {
            y += gui.px(14);
            y = drawPack(list, gui.vec2(origin.x, y), width, p);
            y += gui.px(14);
            _ = drawPreviews(state, ctx, gui.vec2(origin.x, y), width);
            return;
        },
        .imported => |i| {
            y += gui.px(14);
            y = drawPreviews(state, ctx, gui.vec2(origin.x, y), width);
            _ = drawUseButton(ctx, gui.vec2(origin.x, y), previewedLook(state));
            if (gui.buttonOf(.normal, "Remove from library", gui.vec2(0, use_button_height))) state.removeImported(ctx, i);
            if (c.ImGui_IsItemHovered(0)) c.ImGui_SetTooltip("Removes the library's copy");
            return;
        },
        .neutral, .frontier => {
            y += gui.px(14);
            y = drawPreviews(state, ctx, gui.vec2(origin.x, y), width);
            _ = drawUseButton(ctx, gui.vec2(origin.x, y), previewedLook(state));
            return;
        },
    };
    const own = &state.own.items[look];
    // A saved look can be used as it is. Drafts and fits that aren't saved yet can't.
    if (own.saved) if (minilab.look.Id.ofFitted(std.fs.path.basename(own.path))) |id| {
        y += gui.px(10);
        y = drawUseButton(ctx, gui.vec2(origin.x, y), id);
    } else |_| {};
    y += gui.px(14);
    y = drawReferences(state, ctx, own, look, gui.vec2(origin.x, y));
    y += gui.px(14);
    y = drawTable(state, ctx, own, gui.vec2(origin.x, y), width);
    y += gui.px(14);
    drawFigures(state, own, gui.vec2(origin.x, y), width);
}

/// How many looks the collection `pack` has.
fn packLooks(pack: bundled.Pack) usize {
    var count: usize = 0;
    for (bundled.looks) |b| count += @intFromBool(b.pack == pack);
    return count;
}

/// Draws a collection's credit, licence, source and changes. Returns the y below them.
fn drawPack(list: *c.ImDrawList, at: gui.Vec2, width: f32, pack: bundled.Pack) f32 {
    const info = pack.info();
    var y = at.y;
    const label_width = gui.px(pack_label_width);
    const rows = [_][2][]const u8{
        .{ "Credit", info.credit },
        .{ "License", info.licence },
        .{ "Source", info.url },
        .{ "Changes", info.changes },
    };
    for (rows) |row| {
        gui.textIn(list, at.x, y, gui.lineFor(13), theme.text_secondary, row[0]);
        y += @max(gui.lineFor(13), gui.paragraphAt(list, at.x + label_width, y + (gui.lineFor(13) - gui.lineHeight()) / 2, width - label_width, theme.text, row[1]));
        y += gui.px(4);
    }
    return y;
}

/// Draws the frame open in Develop with the selected look next to Neutral, and a button to use the
/// look there. For a collection, it draws a tile for each look, and clicking a tile uses that
/// look. Returns the y below them.
fn drawPreviews(state: *State, ctx: context.Context, at: gui.Vec2, width: f32) f32 {
    const list = c.ImGui_GetWindowDrawList();
    var y = at.y;
    defer {
        c.ImGui_SetCursorScreenPos(gui.vec2(at.x, y));
        c.ImGui_Dummy(gui.vec2(0, 0));
    }
    const frame = if (ctx.develop.frame) |*f| f else {
        y += gui.paragraphAt(list, at.x, y, width, theme.text_tertiary, "No frame open in Develop");
        return y;
    };
    const previews = &state.previews;
    // The previews may still show the selection from before a click this frame. They're made
    // again next frame.
    const key = previews.key orelse return y;
    if (!std.meta.eql(key.selected, state.selected)) return y;
    const ids = previews.ids.items;
    const pack = state.selected == .pack;

    const where = if (ctx.develop.rollIndex(ctx.library)) |r| gui.print("{s} of {s}", .{ frame.name, ctx.library.rolls.items[r].info.name }) else frame.name;
    const intro = if (pack) gui.print("On {s} · Develop's settings", .{where}) else gui.print("On {s} · Develop's settings", .{where});
    y += gui.paragraphAt(list, at.x, y, width, theme.text_secondary, intro);
    y += gui.px(10);

    const small = previews.small.?;
    const aspect = @as(f32, @floatFromInt(small.height)) / @as(f32, @floatFromInt(small.width));
    const gap = gui.px(tile_gap);
    const caption = gui.px(6) + gui.lineFor(13);
    if (!pack) {
        // Neutral and the look, side by side, no taller than `preview_max_height`.
        var w = (width - gap) / 2;
        if (w * aspect > gui.px(preview_max_height)) w = gui.px(preview_max_height) / aspect;
        const h = w * aspect;
        for (ids, 0..) |id, i| {
            const min = gui.vec2(at.x + (w + gap) * @as(f32, @floatFromInt(i)), y);
            _ = previewTile(list, min, gui.vec2(min.x + w, min.y + h), previews.texture(i), id.label(), false, false);
        }
        y += h + caption + gui.px(10);
        return y;
    }

    // A grid for Neutral, then one for each film the collection's looks emulate. Tiles are no
    // taller than `tile_max_height`, so a portrait frame's tiles fit just as many to a row.
    const narrowest = @min(gui.px(tile_min_width), gui.px(tile_max_height) / aspect);
    const columns: usize = @max(1, @as(usize, @intFromFloat((width + gap) / (narrowest + gap))));
    const w = @min((width - gap * @as(f32, @floatFromInt(columns - 1))) / @as(f32, @floatFromInt(columns)), gui.px(tile_max_height) / aspect);
    const h = w * aspect;
    var from: usize = 0;
    while (from < ids.len) {
        const film: ?bundled.Film = if (from == 0) null else bundled.looks[ids[from].kind().bundled].film;
        var to = from + 1;
        while (film != null and to < ids.len and bundled.looks[ids[to].kind().bundled].film == film.?) to += 1;
        fonts.pushSized(.semibold, 12);
        gui.textIn(list, at.x, y, gui.lineFor(12), theme.text_secondary, if (film) |f| gui.print("{s} · {d}", .{ f.label(), to - from }) else "Neutral");
        fonts.pop();
        y += gui.lineFor(12) + gui.px(6);
        for (from..to) |i| {
            const column: f32 = @floatFromInt((i - from) % columns);
            const row: f32 = @floatFromInt((i - from) / columns);
            const min = gui.vec2(at.x + (w + gap) * column, y + (h + caption + gap) * row);
            const name = if (i == 0) "Neutral" else bundled.looks[ids[i].kind().bundled].name;
            c.ImGui_PushIDInt(@intCast(i));
            if (previewTile(list, min, gui.vec2(min.x + w, min.y + h), previews.texture(i), name, ids[i].eql(&frame.look), true)) ctx.develop.useLook(ctx.io, ctx.library, ids[i]);
            if (c.ImGui_IsItemHovered(0)) c.ImGui_SetTooltip("Use on %s", gui.print("{s}", .{frame.name}).ptr);
            c.ImGui_PopID();
        }
        const rows = (to - from + columns - 1) / columns;
        y += (h + caption + gap) * @as(f32, @floatFromInt(rows)) + gui.px(6);
        from = to;
    }
    return y;
}

/// The look the previews show next to Neutral, once they're showing the current selection.
fn previewedLook(state: *const State) ?minilab.look.Id {
    const key = state.previews.key orelse return null;
    if (!std.meta.eql(key.selected, state.selected)) return null;
    const ids = state.previews.ids.items;
    return ids[ids.len - 1];
}

/// Draws the "Use on Frame 3" button, which gives the frame open in Develop the look `id`. It's
/// disabled when the frame already uses the look. Leaves the cursor next to it, for another button
/// on the same line. Returns the y below it.
fn drawUseButton(ctx: context.Context, at: gui.Vec2, look_id: ?minilab.look.Id) f32 {
    const frame = if (ctx.develop.frame) |*f| f else return at.y;
    const id = look_id orelse return at.y;
    const in_use = id.eql(&frame.look);
    c.ImGui_SetCursorScreenPos(at);
    c.ImGui_BeginDisabled(in_use);
    const label = if (in_use) gui.print("In use on {s}", .{frame.name}) else gui.print("Use on {s}", .{frame.name});
    if (gui.buttonOf(.normal, label, gui.vec2(0, use_button_height))) ctx.develop.useLook(ctx.io, ctx.library, id);
    c.ImGui_EndDisabled();
    c.ImGui_SameLine();
    return at.y + gui.px(use_button_height);
}

/// Draws a look's preview in `min`..`max`, with its name underneath, outlined when it's the
/// frame's look. Returns true when it's clicked, if `clickable`.
fn previewTile(list: *c.ImDrawList, min: gui.Vec2, max: gui.Vec2, texture: ?Texture, name: []const u8, current: bool, clickable: bool) bool {
    const caption_top = max.y + gui.px(6);
    var clicked = false;
    var hovered = false;
    if (clickable) {
        c.ImGui_SetCursorScreenPos(min);
        clicked = c.ImGui_InvisibleButton("tile", gui.vec2(max.x - min.x, caption_top + gui.lineFor(13) - min.y), 0);
        hovered = c.ImGui_IsItemHovered(0);
    }
    c.ImDrawList_AddRectFilledEx(list, min, max, theme.imU32(theme.raised), gui.px(3), 0);
    if (texture) |t| gui.imageCover(list, t.ref(), t.width, t.height, min, max, gui.px(3));
    if (current or hovered) {
        const outline = gui.px(if (current) 2 else 1);
        c.ImDrawList_AddRectEx(list, gui.vec2(min.x - outline, min.y - outline), gui.vec2(max.x + outline, max.y + outline), theme.imU32(if (current) theme.accent else theme.border), gui.px(4), outline, 0);
    }
    gui.textIn(list, min.x, caption_top, gui.lineFor(13), if (current) theme.text else theme.text_secondary, gui.elideEnd(name, max.x - min.x));
    return clicked;
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

/// Draws the references section: where they come from, Add pairs, and the count. Returns the y
/// below.
fn drawReferences(state: *State, ctx: context.Context, own: *Own, look: usize, at: gui.Vec2) f32 {
    const height = gui.px(32);
    const list = c.ImGui_GetWindowDrawList();
    var x = at.x;
    gui.textIn(list, x, at.y, height, theme.text_secondary, "References");
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
    if (gui.combo("references", &names, gui.indexIn(draft.Source, sources, own.references), combo_width / gui.scale)) |picked| {
        own.references = sources[picked];
        own.save(ctx);
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
        c.ImGui_SetTooltip("References (JPEG, TIFF) · with our scans (PPM)");
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
    gui.textIn(list, x, at.y, height, theme.text_tertiary, status);
    return at.y + height;
}

/// The pairs table's columns.
const Column = enum {
    ours,
    theirs,
    stock,
    registration,
    use,

    fn header(column: Column, own: *const Own) []const u8 {
        return switch (column) {
            .ours => "Our raw scan",
            .theirs => own.references.one(),
            .stock => "Stock",
            .registration => "Registration",
            .use => "Use",
        };
    }

    /// What the column shows for pair `index`.
    fn text(column: Column, own: *const Own, index: usize) []const u8 {
        const pair = own.pairs.items[index];
        return switch (column) {
            .ours => pair.label,
            .theirs => std.fs.path.basename(pair.theirs),
            .stock => stockName(pair.stock),
            .registration => registrationText(own, index),
            .use => useLabel(pair),
        };
    }

    /// The file names are in the monospaced font.
    fn mono(column: Column) bool {
        return switch (column) {
            .theirs => true,
            .ours, .stock, .registration, .use => false,
        };
    }
};

/// Draws the table of pairs. Returns the y below.
fn drawTable(state: *State, ctx: context.Context, own: *Own, at: gui.Vec2, available: f32) f32 {
    const list = c.ImGui_GetWindowDrawList();
    const n = own.pairs.items.len;
    const header_height = gui.px(16) + gui.lineFor(12) + 1;
    const row_height = gui.px(16) + gui.lineFor(13) + 1;
    const width = @max(available, gui.px(table_min_width));
    const height = header_height + row_height * @as(f32, @floatFromInt(n)) + 2;
    const far = gui.vec2(at.x + width, at.y + height);
    // With no pairs, there's a row for the hint.
    const box_height = if (n == 0) height + row_height else height;
    c.ImDrawList_AddRectFilledEx(list, at, gui.vec2(far.x, at.y + box_height), theme.imU32(theme.panel), gui.px(6), 0);

    // Column widths work like a browser's automatic table layout: each column gets its widest
    // content, then the room that's left is shared out in proportion.
    const columns = std.enums.values(Column);
    var widths: std.EnumArray(Column, f32) = .initUndefined();
    fonts.pushSized(.semibold, 12);
    for (columns) |column| widths.set(column, textWidth(column.header(own)));
    fonts.pop();
    for (0..n) |i| for (columns) |column| {
        if (column.mono()) fonts.pushSized(.mono, 12);
        defer if (column.mono()) fonts.pop();
        widths.set(column, @max(widths.get(column), textWidth(column.text(own, i))));
    };
    var total: f32 = 0;
    for (&widths.values) |*w| {
        w.* += gui.px(24);
        total += w.*;
    }
    const room = width - 2 - total;
    for (&widths.values) |*w| w.* += room * w.* / total;

    // The header, in the design's medium weight.
    fonts.pushSized(.semibold, 12);
    var x = at.x + 1;
    for (columns) |column| {
        gui.textIn(list, x + gui.px(12), at.y + 1 + gui.px(8), gui.lineFor(12), theme.text_secondary, column.header(own));
        x += widths.get(column);
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

        // The Use cell toggles, and the rest of the row selects the pair.
        const use_x = far.x - 1 - widths.get(.use);
        c.ImGui_SetCursorScreenPos(row_min);
        if (c.ImGui_InvisibleButton("row", gui.vec2(use_x - row_min.x, row_height), 0)) state.pair = i;
        const row_hovered = c.ImGui_IsItemHovered(0);
        if (c.ImGui_BeginPopupContextItem()) {
            // Not while a fit is running, or the fit would end up shown against a split it wasn't
            // made from.
            if (c.ImGui_MenuItemEx(if (p.held_out) "Use to fit" else "Hold out to check the fit", null, false, state.job == null)) own.toggleHeldOut(ctx, i);
            if (c.ImGui_MenuItemEx("Remove pair", null, false, state.job == null)) remove = i;
            c.ImGui_EndPopup();
        }
        c.ImGui_SetCursorScreenPos(gui.vec2(use_x, top));
        if (c.ImGui_InvisibleButton("use", gui.vec2(widths.get(.use), row_height), 0) and state.job == null) own.toggleHeldOut(ctx, i);
        const use_hovered = c.ImGui_IsItemHovered(0);
        if (use_hovered) c.ImGui_SetTooltip(if (p.held_out) "Held out to check the fit · click to fit with it" else "Used in the fit · click to hold out");

        if (state.pair == i) {
            c.ImDrawList_AddRectFilled(list, row_min, row_max, theme.imU32(theme.raised));
        } else if (row_hovered or use_hovered) {
            c.ImDrawList_AddRectFilled(list, row_min, row_max, theme.imU32(theme.withAlpha(theme.raised, 0.5)));
        }
        if (i + 1 < n) c.ImDrawList_AddLine(list, gui.vec2(row_min.x, row_max.y - 0.5), gui.vec2(row_max.x, row_max.y - 0.5), theme.imU32(theme.raised));

        const text_top = top + gui.px(8);
        x = at.x + 1;
        for (columns) |column| {
            const w = widths.get(column);
            const room_in_cell = w - gui.px(24);
            const value = column.text(own, i);
            // File names lose their start, which says the least, and the rest lose their end.
            const shown = switch (column) {
                .ours, .stock => gui.elideEnd(value, room_in_cell),
                .theirs => gui.elideStart(value, room_in_cell),
                .registration, .use => value,
            };
            const ink = switch (column) {
                .ours => theme.text,
                .use => if (use_hovered) theme.text else theme.text_secondary,
                .theirs, .stock, .registration => theme.text_secondary,
            };
            if (column.mono()) fonts.pushSized(.mono, 12);
            gui.textIn(list, x + gui.px(12), text_top, gui.lineFor(13), ink, shown);
            if (column.mono()) fonts.pop();
            x += w;
        }
        if (row_hovered and p.alignment != null) {
            const a = p.alignment.?;
            const turned = a.orientation.label();
            c.ImGui_SetTooltip(gui.print("{s}\nCorrelation {d:.2} of 1 · good above {d:.1}\nReference {s}{s}covers {d:.0}% of our scan's width", .{
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
        gui.textIn(list, at.x + 1 + gui.px(12), at.y + 1 + header_height + gui.px(8), gui.lineFor(13), theme.text_tertiary, "No pairs");
    }
    c.ImDrawList_AddRectEx(list, at, gui.vec2(far.x, at.y + box_height), theme.imU32(theme.divider), gui.px(6), 1, 0);
    c.ImGui_SetCursorScreenPos(gui.vec2(at.x, at.y + box_height));
    c.ImGui_Dummy(gui.vec2(0, 0));
    if (remove) |i| {
        own.remove(ctx.gpa, i);
        own.save(ctx);
        state.figures.release(ctx.gpu);
    }
    return at.y + box_height;
}

/// The stock as the table shows it, without the maker.
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

/// Draws the selected pair: our scan, the reference lined up with it, and their difference after
/// the fit.
fn drawFigures(state: *State, own: *const Own, at: gui.Vec2, width: f32) void {
    const list = c.ImGui_GetWindowDrawList();
    const gap = gui.px(figure_gap);
    const figure_width = (width - 2 * gap) / 3;
    const figure_height = figure_width * figure_ratio;
    const pair = if (state.pair < own.pairs.items.len) own.pairs.items[state.pair] else null;
    const aligned = if (pair) |p| p.alignment != null else false;
    const f = &state.figures;
    const captions = [_][]const u8{
        "minilab, Neutral look",
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
                gui.textIn(list, (min.x + max.x - size.x) / 2, (min.y + max.y) / 2 - gui.lineFor(13) / 2, gui.lineFor(13), theme.text_tertiary, placeholder);
            }
        }
        gui.textIn(list, min.x, max.y + gui.px(6), gui.lineFor(13), theme.text_secondary, gui.elideEnd(caption, figure_width));
    }
    c.ImGui_SetCursorScreenPos(gui.vec2(at.x, at.y + figure_height + gui.px(6) + gui.lineFor(13)));
    c.ImGui_Dummy(gui.vec2(0, 0));
}

// The model.

fn drawModel(state: *State, ctx: context.Context) void {
    const list = c.ImGui_GetWindowDrawList();
    const origin = c.ImGui_GetCursorScreenPos();
    const width = c.ImGui_GetContentRegionAvail().x;
    var y = origin.y;
    fonts.pushSized(.semibold, 12);
    gui.textIn(list, origin.x, y, gui.lineFor(12), theme.text_secondary, "MODEL");
    fonts.pop();
    y += gui.lineFor(12) + gui.px(12);

    const look = switch (state.selected) {
        .own => |i| i,
        .neutral => {
            y = drawStages(list, gui.vec2(origin.x, y), width, &.{
                .{ "Film base", "Measured on each frame, or picked" },
                .{ "Density matrix", "3 × 3, for crosstalk between channels" },
                .{ "Inversion curve", "Contrast, black and highlight roll-off" },
            });
            y += gui.px(12);
            y = drawChart(list, gui.vec2(origin.x, y), width, .neutral);
            return;
        },
        .frontier => {
            _ = drawStages(list, gui.vec2(origin.x, y), width, &.{
                .{ "Neutral", "As set in Develop" },
                .{ "Frontier color LUT", "33³, on Neutral's sRGB output" },
            });
            return;
        },
        .pack => |p| {
            _ = drawStages(list, gui.vec2(origin.x, y), width, &.{
                .{ "Neutral", "As set in Develop" },
                .{ gui.print("{s} LUT", .{p.info().name}), gui.print("{d}³, on Neutral's sRGB output", .{bundled.size}) },
            });
            return;
        },
        .imported => |i| {
            const resolved = ctx.library.looks.resolve(ctx.gpa, ctx.io, state.imported.items[i]) catch .neutral;
            var buffer: [64]u8 = undefined;
            const size = if (resolved == .lut) resolved.lut.describe(&buffer) else "can't be read";
            _ = drawStages(list, gui.vec2(origin.x, y), width, &.{
                .{ "Neutral", "As set in Develop" },
                .{ "LUT", gui.print("{s}, on Neutral's sRGB output", .{size}) },
            });
            return;
        },
    };
    const own = &state.own.items[look];
    const busy = state.job != null;

    const options = [_]struct { *bool, []const u8, []const u8 }{
        .{ &own.options.balance, "Per-frame balance", gui.print("3 offsets per frame, for {s} own correction · not part of the look", .{own.references.corrector()}) },
        .{ &own.options.curves, "Channel curves", "R, G and B, monotone, 33 points each" },
        .{ &own.options.matrix, "Density matrix", "3 × 3, for crosstalk between channels" },
        .{ &own.options.lut, "3D LUT for what's left", lutNote(own) },
    };
    for (options, 0..) |option, i| {
        if (i > 0) y += gui.px(8);
        c.ImGui_PushIDInt(@intCast(i));
        if (modelOption(list, gui.vec2(origin.x, y), width, option[0], option[1], option[2], busy)) |h| {
            own.changed();
            own.save(ctx);
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
        c.ImGui_SetTooltip(if (fitted == 0) "No pair to fit" else "Checked on held-out pairs");
    }
    c.ImGui_SetCursorScreenPos(gui.vec2(origin.x, save_top));
    if (gui.buttonOf(.outline, "Save as .cube and curves", gui.vec2(width / gui.scale, 34))) {
        if (result == null) ctx.notice.set("Nothing to save", .{}) else saveLook(ctx, own);
    }
    if (c.ImGui_IsItemHovered(c.ImGuiHoveredFlags_AllowWhenDisabled)) {
        c.ImGui_SetTooltip(gui.print("To Looks/{s}", .{own.name}));
    }
}

fn saveLook(ctx: context.Context, own: *Own) void {
    const result = &(own.result orelse return);
    looks.saved.save(ctx.gpa, ctx.io, own.path, own.name, result) catch |err| {
        ctx.notice.set("Can't save {s} · {t}", .{ own.name, err });
        return;
    };
    own.saved = true;
    own.kept = true;
    if (minilab.look.Id.ofFitted(std.fs.path.basename(own.path))) |id| ctx.library.lookChanged(ctx.gpa, id) else |_| {}
    ctx.notice.set("Saved {s} · look.json, look.cube{s} in Looks/{s}", .{ own.name, if (result.lut != null) ", residual.cube" else "", own.name });
}

fn lutNote(own: *const Own) []const u8 {
    const r = own.result orelse return "33³ · only if the residual shows structure";
    return switch (r.report.lut) {
        .not_asked => "33³ · only if the residual shows structure",
        .kept => gui.print("33³ · kept, removed {d:.0}% of the remaining error out of fold", .{r.report.lut_gain * 100}),
        .no_structure => "33³ · left out, residual is noise",
        .too_few_pairs => "33³ · left out, needs two fitted pairs",
    };
}

/// The height of a model option `width` wide, with `note` wrapped under its name.
fn optionHeight(width: f32, note: []const u8) f32 {
    return gui.lineFor(13) + gui.paragraphHeight(note, width - gui.px(13 + 8));
}

/// Draws one of the model's choices: a check box, its name and a note under it. Returns its height
/// if it was clicked, or null if not.
fn modelOption(list: *c.ImDrawList, at: gui.Vec2, width: f32, checked: *bool, name: []const u8, note: []const u8, disabled: bool) ?f32 {
    const height = optionHeight(width, note);
    c.ImGui_SetCursorScreenPos(at);
    c.ImGui_BeginDisabled(disabled);
    const clicked = c.ImGui_InvisibleButton("option", gui.vec2(width, height), 0);
    c.ImGui_EndDisabled();
    const hovered = c.ImGui_IsItemHovered(0);
    if (clicked) checked.* = !checked.*;

    const box = gui.px(13);
    gui.checkBox(list, gui.vec2(at.x, at.y + gui.px(3)), box, checked.*, hovered);
    const x = at.x + box + gui.px(8);
    gui.textIn(list, x, at.y, gui.lineFor(13), theme.text, name);
    _ = gui.paragraphAt(list, x, at.y + gui.lineFor(13), width - box - gui.px(8), theme.text_tertiary, note);
    return if (clicked) height else null;
}

/// Draws what a built-in look is made of, laid out like the model options but without check
/// boxes. Returns the y below.
fn drawStages(list: *c.ImDrawList, at: gui.Vec2, width: f32, stages: []const [2][]const u8) f32 {
    var y = at.y;
    for (stages, 0..) |stage, i| {
        if (i > 0) y += gui.px(8);
        const box = gui.px(13);
        c.ImDrawList_AddCircleFilled(list, gui.vec2(at.x + box / 2, y + gui.px(3) + box / 2), gui.px(2.5), theme.imU32(theme.text_tertiary), 12);
        const x = at.x + box + gui.px(8);
        gui.textIn(list, x, y, gui.lineFor(13), theme.text, stage[0]);
        y += gui.lineFor(13);
        y += gui.paragraphAt(list, x, y, width - box - gui.px(8), theme.text_tertiary, stage[1]);
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

/// Draws `chart` the way the design does: curves against density in, 300 × 180 units scaled to
/// `width`. Returns the y below.
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
            // Neutral's inversion curve with Develop's default settings, and the film base at full
            // transmission.
            const prepared: minilab.develop.Prepared = .init(.{});
            var points: [65]gui.Vec2 = undefined;
            for (&points, 0..) |*pt, i| {
                const x = @as(f32, @floatFromInt(i)) / 64;
                const t = std.math.pow(f32, 10, -x * (minilab.develop.Settings{}).density_range);
                const raw: u16 = @intFromFloat(@round(t * minilab.image.full_scale));
                const out = minilab.develop.pixel(prepared, .{ raw, raw, raw });
                pt.* = plot(at, k, x, minilab.encode.srgb(out[1]));
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
    // The "out" label, turned to read upwards: it's drawn level, then its vertices are turned
    // around its anchor.
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
    // The label goes at the top right, as in the design, or at the top left to keep it out of the
    // fitted curves' way.
    fonts.pushSized(.regular, 11 * k);
    const label = gui.print("{s}", .{chart.label()});
    const label_size = c.ImGui_CalcTextSize(label);
    const label_x = if (chart == .fitted) at.x + 40 * k else at.x + 286 * k - label_size.x;
    c.ImDrawList_AddText(list, gui.vec2(label_x, at.y + 24 * k - ascent()), theme.imU32(theme.text_secondary), label);
    fonts.pop();
    return at.y + height;
}

/// How far the baseline sits below the top of a line of text, so we can place text by its
/// baseline the way SVG does. It's about 0.78 of the size for both fonts (ImGui's font data is
/// opaque here).
fn ascent() f32 {
    return c.ImGui_GetFontSize() * 0.78;
}

/// Draws the density matrix, three by three. Returns the y below.
fn drawMatrix(list: *c.ImDrawList, at: gui.Vec2, width: f32, matrix: model.Matrix) f32 {
    const gap = gui.px(4);
    const cell_width = (width - 2 * gap) / 3;
    const cell_height = gui.px(12) + gui.lineFor(12);
    fonts.pushSized(.mono, 12);
    defer fonts.pop();
    for (matrix, 0..) |row, r| {
        for (row, 0..) |v, col| {
            const min = gui.vec2(at.x + (cell_width + gap) * @as(f32, @floatFromInt(col)), at.y + (cell_height + gap) * @as(f32, @floatFromInt(r)));
            c.ImDrawList_AddRectFilledEx(list, min, gui.vec2(min.x + cell_width, min.y + cell_height), theme.imU32(theme.raised), gui.px(3), 0);
            const shown = gui.formatSigned("{d:.3}", v);
            const size = c.ImGui_CalcTextSize(shown);
            gui.textIn(list, min.x + (cell_width - size.x) / 2, min.y + gui.px(6), gui.lineFor(12), if (r == col) theme.text else theme.text_tertiary, shown);
        }
    }
    return at.y + 3 * cell_height + 2 * gap;
}

/// Draws the ΔE2000 figures for the held-out pairs. Returns the y below.
fn drawMeasures(list: *c.ImDrawList, at: gui.Vec2, width: f32, own: *const Own) f32 {
    const rows = [_][]const u8{ "Held-out ΔE2000, median", "Held-out ΔE2000, 95th percentile" };
    var values: [2][]const u8 = .{ "[after fit]", "[after fit]" };
    if (own.result) |r| {
        if (r.report.median) |m| {
            values = .{ gui.print("{d:.2}", .{m}), gui.print("{d:.2}", .{r.report.p95.?}) };
        } else values = .{ "no pair held out", "no pair held out" };
    }
    const height = gui.px(20 + 6) + 2 * gui.lineFor(13);
    c.ImDrawList_AddRectFilledEx(list, at, gui.vec2(at.x + width, at.y + height), theme.imU32(theme.raised), gui.px(5), 0);
    for (rows, values, 0..) |label, value, i| {
        const y = at.y + gui.px(10) + (gui.lineFor(13) + gui.px(6)) * @as(f32, @floatFromInt(i));
        gui.textIn(list, at.x + gui.px(10), y, gui.lineFor(13), theme.text_secondary, label);
        fonts.push(.mono);
        const w = textWidth(value);
        gui.textIn(list, at.x + width - gui.px(10) - w, y, gui.lineFor(13), theme.text, value);
        fonts.pop();
    }
    if (own.result) |r| {
        if (own.stale) {
            _ = gui.paragraphAt(list, at.x, at.y + height + gui.px(6), width, theme.text_tertiary, "Out of date");
        } else {
            const note = gui.print("{d} {s} fitted · {d} held out · fitted median {d:.2}", .{ r.report.fitted_pairs, if (r.report.fitted_pairs == 1) "pair" else "pairs", r.report.held_out_pairs, r.report.fitted_median });
            _ = gui.paragraphAt(list, at.x, at.y + height + gui.px(6), width, theme.text_tertiary, note);
        }
    }
    return at.y + height;
}

test {
    _ = looks;
}
