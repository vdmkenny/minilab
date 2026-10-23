//! Updates: finds the latest release on GitHub, then downloads this platform's build of it, checks
//! it against the release's checksums and GitHub's build attestation, and installs it over the
//! running one. Only the release builds look for updates (`-Dupdates`), so a build from source
//! leaves itself alone.
//!
//! Installing swaps the release archive's files into the program's folder. The files it replaces
//! go into `.previous`, which the next start deletes. A running program can be renamed on every
//! system, which is what lets it replace itself.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
pub const sigstore = @import("sigstore.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const repository = "vdmkenny/minilab";
/// The workflow that builds the releases, which their attestations have to name.
pub const signer: sigstore.Signer = .{ .workflow = "https://github.com/" ++ repository ++ "/.github/workflows/release.yml@refs/heads/main" };
const api = "https://api.github.com/repos/" ++ repository;

/// This build's name in the release's file names, like `macos-aarch64`, or null where there's no
/// release build for this system.
pub const platform: ?[]const u8 = platformName(builtin.os.tag, builtin.cpu.arch);

fn platformName(comptime os: std.Target.Os.Tag, comptime arch: std.Target.Cpu.Arch) ?[]const u8 {
    const system = switch (os) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => return null,
    };
    const cpu = switch (arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return null,
    };
    return system ++ "-" ++ cpu;
}

pub const archive_extension = if (builtin.os.tag == .windows) ".zip" else ".tar.gz";
pub const program_name = if (builtin.os.tag == .windows) "minilab.exe" else "minilab";
/// Where installing unpacks the new release, and where it keeps the files it replaced.
const staging_folder = ".update";
const previous_folder = ".previous";

/// The most an answer from GitHub's API can be, and the most a release archive can be.
const max_answer_bytes = 4 * 1024 * 1024;
const max_archive_bytes = 512 * 1024 * 1024;

/// A release that's newer than this build, with what installing it takes.
pub const Release = struct {
    arena: std.heap.ArenaAllocator,
    version: []const u8,
    /// Its page on GitHub.
    page: []const u8,
    notes: []const Note,
    archive: Asset,
    checksums: Asset,

    pub fn deinit(release: *Release) void {
        release.arena.deinit();
    }
};

pub const Asset = struct { name: []const u8, url: []const u8, size: u64 };

/// A line of release notes: a section's heading, or one change.
pub const Note = struct { kind: enum { heading, change }, text: []const u8 };

pub const CheckError = error{ BadAnswer, OutOfMemory } || FetchError;

/// Asks GitHub for the latest release, and returns it if it's newer than `current` and has a build
/// for this system. Errors mean GitHub couldn't be asked, as when there's no internet.
pub fn newerRelease(gpa: std.mem.Allocator, client: *std.http.Client, current: []const u8) CheckError!?Release {
    const name = platform orelse return null;
    const installed = std.SemanticVersion.parse(current) catch return null;
    var answer: std.ArrayList(u8) = .empty;
    defer answer.deinit(gpa);
    try fetch(gpa, client, api ++ "/releases/latest", "application/vnd.github+json", max_answer_bytes, &answer, null, null);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const Latest = struct {
        tag_name: []const u8,
        html_url: []const u8,
        body: ?[]const u8 = null,
        assets: []const struct { name: []const u8, browser_download_url: []const u8, size: u64 },
    };
    // The release outlives the answer, so its strings are copied out of it.
    const latest = std.json.parseFromSliceLeaky(Latest, a, answer.items, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.BadAnswer;
    const version = std.mem.cutPrefix(u8, latest.tag_name, "v") orelse latest.tag_name;
    const offered = std.SemanticVersion.parse(version) catch return error.BadAnswer;
    if (offered.order(installed) != .gt) {
        arena.deinit();
        return null;
    }
    const archive_name = try std.fmt.allocPrint(a, "minilab-{s}-{s}{s}", .{ latest.tag_name, name, archive_extension });
    const checksums_name = try std.fmt.allocPrint(a, "minilab-{s}-sha256sums.txt", .{latest.tag_name});
    var archive: ?Asset = null;
    var checksums: ?Asset = null;
    for (latest.assets) |asset| {
        const found: Asset = .{ .name = asset.name, .url = asset.browser_download_url, .size = asset.size };
        if (std.mem.eql(u8, asset.name, archive_name)) archive = found;
        if (std.mem.eql(u8, asset.name, checksums_name)) checksums = found;
    }
    return .{
        .arena = arena,
        .version = version,
        .page = latest.html_url,
        .notes = try notesOf(a, latest.body orelse ""),
        .archive = archive orelse return error.BadAnswer,
        .checksums = checksums orelse return error.BadAnswer,
    };
}

/// The changes in Release Please's notes, as headings and changes without their Markdown: the
/// first line (the version and its date) goes, a `### Fixes` heading becomes `Fixes`, and a
/// change keeps its text but not its links to the pull request and the commit.
pub fn notesOf(arena: std.mem.Allocator, body: []const u8) error{OutOfMemory}![]Note {
    var notes: std.ArrayList(Note) = .empty;
    var lines = std.mem.tokenizeAny(u8, body, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (std.mem.cutPrefix(u8, line, "### ")) |heading| {
            try notes.append(arena, .{ .kind = .heading, .text = heading });
        } else if (std.mem.cutPrefix(u8, line, "* ") orelse std.mem.cutPrefix(u8, line, "- ")) |change| {
            try notes.append(arena, .{ .kind = .change, .text = try withoutLinks(arena, change) });
        }
    }
    return notes.toOwnedSlice(arena);
}

/// `text` with Markdown links in brackets, like ` ([#41](url))`, taken out, and other links
/// reduced to their text.
fn withoutLinks(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    while (at < text.len) {
        if (std.mem.startsWith(u8, text[at..], " ([")) {
            if (std.mem.indexOfPos(u8, text, at, "))")) |close| {
                at = close + 2;
                continue;
            }
        }
        if (text[at] == '[') {
            if (std.mem.indexOfPos(u8, text, at, "](")) |middle| {
                if (std.mem.indexOfScalarPos(u8, text, middle, ')')) |close| {
                    try out.appendSlice(arena, text[at + 1 .. middle]);
                    at = close + 1;
                    continue;
                }
            }
        }
        try out.append(arena, text[at]);
        at += 1;
    }
    return std.mem.trim(u8, out.items, " ");
}

/// The SHA-256 the release's checksums give for `name`.
pub fn checksumOf(checksums: []const u8, name: []const u8) ?[Sha256.digest_length]u8 {
    var lines = std.mem.tokenizeAny(u8, checksums, "\r\n");
    while (lines.next()) |line| {
        const hex, const file = std.mem.cutScalar(u8, line, ' ') orelse continue;
        // sha256sum puts two spaces, or a space and a `*` for binary mode, before the name.
        const file_name = std.mem.trimStart(u8, file, " *");
        if (!std.mem.eql(u8, file_name, name)) continue;
        var digest: [Sha256.digest_length]u8 = undefined;
        if (hex.len != 2 * digest.len) return null;
        _ = std.fmt.hexToBytes(&digest, hex) catch return null;
        return digest;
    }
    return null;
}

pub const DownloadError = error{ ChecksumMissing, ChecksumMismatch, OutOfMemory } || FetchError || sigstore.Error;

/// Downloads the release's archive and checks it: its SHA-256 has to be the one the release's
/// checksums give, and GitHub's attestation for it has to show the release workflow built it.
/// `progress` counts the bytes downloaded, and setting `cancel` stops the download.
pub fn download(gpa: std.mem.Allocator, client: *std.http.Client, release: *const Release, progress: *std.atomic.Value(u64), cancel: *const std.atomic.Value(bool)) DownloadError![]u8 {
    var checksums: std.ArrayList(u8) = .empty;
    defer checksums.deinit(gpa);
    try fetch(gpa, client, release.checksums.url, "application/octet-stream", max_answer_bytes, &checksums, null, cancel);
    const expected = checksumOf(checksums.items, release.archive.name) orelse return error.ChecksumMissing;

    var archive: std.ArrayList(u8) = .empty;
    errdefer archive.deinit(gpa);
    try fetch(gpa, client, release.archive.url, "application/octet-stream", max_archive_bytes, &archive, progress, cancel);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(archive.items, &digest, .{});
    if (!std.mem.eql(u8, &digest, &expected)) return error.ChecksumMismatch;

    const hex = std.fmt.bytesToHex(digest, .lower);
    var attestations: std.ArrayList(u8) = .empty;
    defer attestations.deinit(gpa);
    try fetch(gpa, client, api ++ "/attestations/sha256:" ++ hex, "application/vnd.github+json", max_answer_bytes, &attestations, null, cancel);
    try sigstore.verifyResponse(gpa, attestations.items, release.archive.name, digest, signer);
    return archive.toOwnedSlice(gpa);
}

pub const FetchError = error{ Offline, BadStatus, TooLarge, Cancelled, OutOfMemory };

/// GETs `url` into `out`, following redirects, which release downloads go through. Network
/// failures all come back as `Offline`: there's nothing to do about them but try again later.
fn fetch(gpa: std.mem.Allocator, client: *std.http.Client, url: []const u8, accept: []const u8, limit: usize, out: *std.ArrayList(u8), progress: ?*std.atomic.Value(u64), cancel: ?*const std.atomic.Value(bool)) FetchError!void {
    const uri = std.Uri.parse(url) catch return error.BadStatus;
    var request = client.request(.GET, uri, .{
        .headers = .{ .user_agent = .{ .override = "minilab" }, .accept_encoding = .{ .override = "identity" } },
        .extra_headers = &.{.{ .name = "accept", .value = accept }},
    }) catch return error.Offline;
    defer request.deinit();
    request.sendBodiless() catch return error.Offline;
    var redirects: [8 * 1024]u8 = undefined;
    var response = request.receiveHead(&redirects) catch return error.Offline;
    if (response.head.status != .ok) return error.BadStatus;
    var transfer: [64 * 1024]u8 = undefined;
    const body = response.reader(&transfer);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        if (cancel) |c| if (c.load(.acquire)) return error.Cancelled;
        const n = body.readSliceShort(&chunk) catch return error.Offline;
        if (n == 0) break;
        if (out.items.len + n > limit) return error.TooLarge;
        try out.appendSlice(gpa, chunk[0..n]);
        if (progress) |p| p.store(out.items.len, .release);
        if (n < chunk.len) break;
    }
}

pub const InstallError = error{ NotWritable, NotABuild, BadArchive, OutOfMemory } || Io.Dir.RenameError;

/// Whether the program's folder can take an update.
pub fn writable(io: Io, folder: []const u8) bool {
    var dir = Io.Dir.openDirAbsolute(io, folder, .{}) catch return false;
    defer dir.close(io);
    const probe = staging_folder ++ "-probe";
    dir.deleteTree(io, probe) catch {};
    dir.createDir(io, probe, .default_dir) catch return false;
    dir.deleteDir(io, probe) catch {};
    return true;
}

/// Installs a release archive's files into `folder`, the program's folder. The files they replace
/// go into `.previous`. If a swap fails partway, the ones already made are undone.
pub fn install(gpa: std.mem.Allocator, io: Io, archive: []const u8, folder: []const u8) InstallError!void {
    var dir = Io.Dir.openDirAbsolute(io, folder, .{ .iterate = true }) catch return error.NotWritable;
    defer dir.close(io);
    dir.deleteTree(io, staging_folder) catch return error.NotWritable;
    var staging = dir.createDirPathOpen(io, staging_folder, .{ .open_options = .{ .iterate = true } }) catch return error.NotWritable;
    defer {
        staging.close(io);
        dir.deleteTree(io, staging_folder) catch {};
    }
    var unpacked = try unpack(io, archive, staging);
    defer unpacked.close(io);
    unpacked.access(io, program_name, .{}) catch return error.NotABuild;

    dir.deleteTree(io, previous_folder) catch return error.NotWritable;
    var previous = dir.createDirPathOpen(io, previous_folder, .{}) catch return error.NotWritable;
    defer previous.close(io);

    // Swap each of the archive's top-level files and folders in, keeping the old one.
    var moved: std.ArrayList(struct { name: []const u8, had_old: bool }) = .empty;
    var names: std.heap.ArenaAllocator = .init(gpa);
    defer names.deinit();
    defer moved.deinit(gpa);
    errdefer for (moved.items) |m| {
        Io.Dir.rename(dir, m.name, unpacked, m.name, io) catch {};
        if (m.had_old) Io.Dir.rename(previous, m.name, dir, m.name, io) catch {};
    };
    // List them first: moving files out of a folder while going through it can skip some.
    var listed: std.ArrayList([]const u8) = .empty;
    defer listed.deinit(gpa);
    var entries = unpacked.iterate();
    while (entries.next(io) catch return error.BadArchive) |entry| try listed.append(gpa, try names.allocator().dupe(u8, entry.name));
    for (listed.items) |name| {
        var had_old = true;
        Io.Dir.rename(dir, name, previous, name, io) catch |err| switch (err) {
            error.FileNotFound => had_old = false,
            else => return err,
        };
        Io.Dir.rename(unpacked, name, dir, name, io) catch |err| {
            if (had_old) Io.Dir.rename(previous, name, dir, name, io) catch {};
            return err;
        };
        try moved.append(gpa, .{ .name = name, .had_old = had_old });
    }
}

/// Unpacks a release archive into `staging`, returning its top folder, where the files are.
fn unpack(io: Io, archive: []const u8, staging: Io.Dir) InstallError!Io.Dir {
    if (builtin.os.tag == .windows) {
        staging.writeFile(io, .{ .sub_path = "archive.zip", .data = archive }) catch return error.NotWritable;
        var file = staging.openFile(io, "archive.zip", .{}) catch return error.NotWritable;
        defer file.close(io);
        var buffer: [16 * 1024]u8 = undefined;
        var reader = file.reader(io, &buffer);
        var files = staging.createDirPathOpen(io, "files", .{ .open_options = .{ .iterate = true } }) catch return error.NotWritable;
        defer files.close(io);
        std.zip.extract(files, &reader, .{}) catch return error.BadArchive;
        return onlyFolder(io, files);
    }
    var input: Io.Reader = .fixed(archive);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var gzip: std.compress.flate.Decompress = .init(&input, .gzip, &window);
    var files = staging.createDirPathOpen(io, "files", .{ .open_options = .{ .iterate = true } }) catch return error.NotWritable;
    errdefer files.close(io);
    std.tar.extract(io, files, &gzip.reader, .{ .strip_components = 1, .mode_mode = .executable_bit_only }) catch return error.BadArchive;
    return files;
}

/// The one folder in `dir`, which a zip archive's files are in.
fn onlyFolder(io: Io, dir: Io.Dir) InstallError!Io.Dir {
    var entries = dir.iterate();
    const first = (entries.next(io) catch return error.BadArchive) orelse return error.BadArchive;
    if (first.kind != .directory or (entries.next(io) catch return error.BadArchive) != null) return error.BadArchive;
    return dir.openDir(io, first.name, .{ .iterate = true }) catch error.BadArchive;
}

/// Deletes what the last update left behind: the replaced files, and an unpacked archive if it
/// didn't finish.
pub fn cleanUp(io: Io, folder: []const u8) void {
    var dir = Io.Dir.openDirAbsolute(io, folder, .{}) catch return;
    defer dir.close(io);
    dir.deleteTree(io, previous_folder) catch {};
    dir.deleteTree(io, staging_folder) catch {};
}

/// Starts the program in `folder` again with `argv`, once the app has closed. On macOS and Linux
/// the new program takes this process over. On Windows it starts on its own and this one ends.
pub fn restart(io: Io, folder: []const u8, argv: []const []const u8) !void {
    var dir = try Io.Dir.openDirAbsolute(io, folder, .{});
    defer dir.close(io);
    const exe: std.process.ReplaceOptions.Exe = .{ .explicit = .{ .dir = dir, .path = program_name } };
    if (builtin.os.tag == .windows) {
        _ = try std.process.spawn(io, .{ .exe = exe, .argv = argv });
        return;
    }
    return std.process.replace(io, .{ .exe = exe, .argv = argv });
}

/// The command that takes macOS's quarantine off the files in `folder`, for when it won't open an
/// unsigned build.
pub fn unquarantineCommand(arena: std.mem.Allocator, folder: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "xattr -dr com.apple.quarantine \"{s}\"", .{folder});
}

/// Whether the program at `path` carries a Developer ID signature, which macOS opens without
/// complaint. `codesign` reports the signing authority on standard error.
pub fn developerIdSigned(gpa: std.mem.Allocator, io: Io, path: []const u8) bool {
    if (builtin.os.tag != .macos) return true;
    const result = std.process.run(gpa, io, .{ .argv = &.{ "/usr/bin/codesign", "-dv", "--verbose=2", path } }) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return std.mem.indexOf(u8, result.stderr, "Authority=Developer ID Application") != null;
}

test "the platform names match the release's" {
    try std.testing.expectEqualStrings("macos-aarch64", platformName(.macos, .aarch64).?);
    try std.testing.expectEqualStrings("windows-x86_64", platformName(.windows, .x86_64).?);
    try std.testing.expectEqualStrings("linux-aarch64", platformName(.linux, .aarch64).?);
    try std.testing.expectEqual(@as(?[]const u8, null), platformName(.freebsd, .x86_64));
}

test "release notes lose their Markdown and links" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const body =
        \\## [0.3.1](https://github.com/vdmkenny/minilab/compare/v0.3.0...v0.3.1) (2026-10-23)
        \\
        \\
        \\### Fixes
        \\
        \\* Film type locked for finished scans ([#41](https://github.com/vdmkenny/minilab/issues/41)) ([8751788](https://github.com/vdmkenny/minilab/commit/8751788))
        \\* The [built-in LUT](https://example.com) keeps LF line endings
        \\
        \\### Documentation
        \\
        \\* README opens with a summary
    ;
    const notes = try notesOf(arena.allocator(), body);
    try std.testing.expectEqual(@as(usize, 5), notes.len);
    try std.testing.expectEqualStrings("Fixes", notes[0].text);
    try std.testing.expectEqualStrings("Film type locked for finished scans", notes[1].text);
    try std.testing.expectEqualStrings("The built-in LUT keeps LF line endings", notes[2].text);
    try std.testing.expect(notes[3].kind == .heading and notes[4].kind == .change);
}

test "a checksum is found by its file's name" {
    const sums =
        \\6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e  libjpeg-turbo-3.2.0.tar.gz
        \\aa29f494889f3674d57213d15e5baa191707bbd6102cd42ab3347dcc12329998  minilab-v0.3.1-macos-aarch64.tar.gz
        \\
    ;
    const digest = checksumOf(sums, "minilab-v0.3.1-macos-aarch64.tar.gz").?;
    try std.testing.expectEqual(@as(u8, 0xaa), digest[0]);
    try std.testing.expectEqual(@as(?[Sha256.digest_length]u8, null), checksumOf(sums, "minilab-v0.3.1-linux-x86_64.tar.gz"));
}

/// A release-style .tar.gz holding `minilab-test/` with a program whose contents are `version`
/// (or no program), and a folder.
fn testArchive(gpa: std.mem.Allocator, version: []const u8, with_program: bool) ![]u8 {
    var tar_bytes: Io.Writer.Allocating = .init(gpa);
    defer tar_bytes.deinit();
    var tar: std.tar.Writer = .{ .underlying_writer = &tar_bytes.writer };
    try tar.setRoot("minilab-test");
    if (with_program) try tar.writeFileBytes(program_name, version, .{ .mode = 0o755 });
    try tar.writeDir("sane", .{});
    try tar.writeFileBytes("sane/libsane.1.dylib", version, .{});
    try tar.finishPedantically();
    var gzip_bytes: Io.Writer.Allocating = .init(gpa);
    errdefer gzip_bytes.deinit();
    var buffer: [16 * 1024]u8 = undefined;
    var raw: std.compress.flate.Compress.Raw = try .init(&gzip_bytes.writer, &buffer, .gzip);
    try raw.writer.writeAll(tar_bytes.written());
    try raw.finish();
    return gzip_bytes.toOwnedSlice();
}

test "installing swaps the files in and keeps the old ones until the next start" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = program_name, .data = "0.3.0" });
    try tmp.dir.createDirPath(io, "sane");
    try tmp.dir.writeFile(io, .{ .sub_path = "sane/libsane.1.dylib", .data = "0.3.0" });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "mine" });
    const folder = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(folder);

    const archive = try testArchive(gpa, "0.3.1", true);
    defer gpa.free(archive);
    try std.testing.expect(writable(io, folder));
    try install(gpa, io, archive, folder);

    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0.3.1", try tmp.dir.readFile(io, program_name, &buffer));
    try std.testing.expectEqualStrings("0.3.1", try tmp.dir.readFile(io, "sane/libsane.1.dylib", &buffer));
    try std.testing.expectEqualStrings("0.3.0", try tmp.dir.readFile(io, previous_folder ++ "/" ++ program_name, &buffer));
    // Files the release doesn't have stay where they are.
    try std.testing.expectEqualStrings("mine", try tmp.dir.readFile(io, "notes.txt", &buffer));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, staging_folder, .{}));

    cleanUp(io, folder);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, previous_folder, .{}));
}

test "a broken archive, or one without the program, changes nothing" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = program_name, .data = "0.3.0" });
    const folder = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(folder);
    var broken: [8]u8 = @splat(0);
    try std.testing.expectError(error.BadArchive, install(gpa, io, &broken, folder));
    const empty = try testArchive(gpa, "0.3.1", false);
    defer gpa.free(empty);
    try std.testing.expectError(error.NotABuild, install(gpa, io, empty, folder));
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0.3.0", try tmp.dir.readFile(io, program_name, &buffer));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, staging_folder, .{}));
}

test {
    std.testing.refAllDecls(@This());
}
