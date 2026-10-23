//! Checks a GitHub artifact attestation: the proof that a file came out of a given GitHub Actions
//! workflow. It's a Sigstore bundle, an in-toto statement that names the file and its SHA-256,
//! signed with a short-lived certificate that Sigstore's certificate authority (Fulcio) gave the
//! workflow, and recorded in Sigstore's public transparency log (Rekor). We check what
//! `gh attestation verify` checks, against Sigstore's public trusted root in `trusted_root.json`:
//!
//! - the statement names the file with its digest;
//! - the certificate's key signed the statement;
//! - the certificate chains to Fulcio's root, was valid when Rekor logged it, and was given to the
//!   workflow we expect, on GitHub Actions;
//! - Rekor's entry is for this signature and certificate, Rekor signed its time, and the entry is in
//!   the log, by an inclusion proof against a checkpoint Rekor signed.
//!
//! It handles Rekor's original log (`dsse` entries with a signed entry timestamp), which is what
//! GitHub's attestations for public repositories use. Anything else fails to verify.
//! `trusted_root.json` is Sigstore's public trusted root as `gh attestation trusted-root` prints it.
//! When Sigstore changes its keys, it needs updating.

const std = @import("std");
const Certificate = std.crypto.Certificate;
const Sha256 = std.crypto.hash.sha2.Sha256;
const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const EcdsaP384 = std.crypto.sign.ecdsa.EcdsaP384Sha384;

const trusted_root_json = @embedFile("trusted_root.json");

/// Who must have signed: the workflow, as Fulcio names it in the certificate, and who vouched for
/// the workflow's identity.
pub const Signer = struct {
    /// The workflow file at its ref, like
    /// `https://github.com/owner/repo/.github/workflows/release.yml@refs/heads/main`.
    workflow: []const u8,
    issuer: []const u8 = "https://token.actions.githubusercontent.com",
};

pub const Error = error{
    /// The attestation isn't in a form we can read.
    Malformed,
    /// It's in a form or for a log we don't handle.
    Unsupported,
    /// Its statement doesn't name the file with this digest.
    NotForThisFile,
    /// The signature on the statement doesn't match the certificate.
    BadSignature,
    /// The certificate doesn't chain to Sigstore's root at the time it was logged.
    UntrustedCertificate,
    /// The certificate was given to someone else.
    WrongSigner,
    /// The transparency log doesn't vouch for the entry.
    NotInLog,
    OutOfMemory,
};

const bundle_type = "application/vnd.dev.sigstore.bundle.v0.3";
const in_toto_type = "application/vnd.in-toto+json";
const statement_type = "https://in-toto.io/Statement/v1";
const provenance_type = "https://slsa.dev/provenance/v1";

/// Checks GitHub's attestations for a file, `response` being what GitHub's API answers for the
/// file's digest. Succeeds if one of them is for `name` with `digest`, signed by `signer`, and
/// otherwise returns the first one's problem.
pub fn verifyResponse(gpa: std.mem.Allocator, response: []const u8, name: []const u8, digest: [Sha256.digest_length]u8, signer: Signer) Error!void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Response = struct { attestations: []const struct { bundle: Bundle } };
    const parsed = parse(Response, arena, response) catch |err| return mapParse(err);
    if (parsed.attestations.len == 0) return error.NotForThisFile;
    const root = parse(TrustedRoot, arena, trusted_root_json) catch |err| return mapParse(err);
    var first: ?Error = null;
    for (parsed.attestations) |attestation| {
        verifyBundle(arena, root, attestation.bundle, name, digest, signer) catch |err| {
            if (err == error.OutOfMemory) return err;
            if (first == null) first = err;
            continue;
        };
        return;
    }
    return first.?;
}

const Bundle = struct {
    mediaType: []const u8,
    verificationMaterial: struct {
        certificate: ?struct { rawBytes: []const u8 } = null,
        tlogEntries: []const LogEntry = &.{},
    },
    dsseEnvelope: struct {
        payload: []const u8,
        payloadType: []const u8,
        signatures: []const struct { sig: []const u8 },
    },
};

const LogEntry = struct {
    logIndex: []const u8,
    logId: struct { keyId: []const u8 },
    kindVersion: struct { kind: []const u8, version: []const u8 },
    integratedTime: []const u8,
    inclusionPromise: ?struct { signedEntryTimestamp: []const u8 } = null,
    inclusionProof: ?struct {
        logIndex: []const u8,
        rootHash: []const u8,
        treeSize: []const u8,
        hashes: []const []const u8,
        checkpoint: struct { envelope: []const u8 },
    } = null,
    canonicalizedBody: []const u8,
};

/// Checks one bundle against the trusted root, allocating in `arena`.
fn verifyBundle(arena: std.mem.Allocator, root: TrustedRoot, bundle: Bundle, name: []const u8, digest: [Sha256.digest_length]u8, signer: Signer) Error!void {
    if (!std.mem.startsWith(u8, bundle.mediaType, bundle_type)) return error.Unsupported;

    // The statement names the file.
    const envelope = bundle.dsseEnvelope;
    if (!std.mem.eql(u8, envelope.payloadType, in_toto_type)) return error.Unsupported;
    const payload = try decode(arena, envelope.payload);
    const Statement = struct {
        _type: []const u8,
        predicateType: []const u8,
        subject: []const struct { name: []const u8 = "", digest: struct { sha256: []const u8 = "" } = .{} },
    };
    const statement = parse(Statement, arena, payload) catch |err| return mapParse(err);
    if (!std.mem.eql(u8, statement._type, statement_type) or !std.mem.eql(u8, statement.predicateType, provenance_type)) return error.Unsupported;
    const hex = std.fmt.bytesToHex(digest, .lower);
    for (statement.subject) |subject| {
        if (std.mem.eql(u8, subject.name, name) and std.mem.eql(u8, subject.digest.sha256, &hex)) break;
    } else return error.NotForThisFile;

    // The certificate's key signed it.
    const material = bundle.verificationMaterial;
    const certificate_der = try decode(arena, (material.certificate orelse return error.Unsupported).rawBytes);
    const leaf = try parseCertificate(certificate_der);
    if (envelope.signatures.len != 1) return error.Unsupported;
    const signature = try decode(arena, envelope.signatures[0].sig);
    try verifySignature(leaf.pub_key_algo, leaf.pubKey(), signature, try pae(arena, envelope.payloadType, payload), error.BadSignature);

    // Rekor logged this signature and certificate, at a time it vouches for.
    if (material.tlogEntries.len == 0) return error.NotInLog;
    const entry = material.tlogEntries[0];
    const log = try findLog(arena, root, try decode(arena, entry.logId.keyId));
    const time = std.fmt.parseInt(i64, entry.integratedTime, 10) catch return error.Malformed;
    const body = try decode(arena, entry.canonicalizedBody);
    try checkBody(arena, entry, body, payload, signature, certificate_der);
    try checkTimestamp(arena, entry, log, time);
    try checkInclusion(arena, entry, body, log);

    // The certificate was Fulcio's, valid then, and given to the signer.
    try checkChain(arena, root, leaf, time);
    try checkSigner(certificate_der, signer);
}

/// DSSE's pre-authentication encoding of a payload: what the signature is over.
fn pae(arena: std.mem.Allocator, payload_type: []const u8, payload: []const u8) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(arena, "DSSEv1 {d} {s} {d} {s}", .{ payload_type.len, payload_type, payload.len, payload });
}

/// Checks Rekor's entry is for this signature, by this certificate, on this payload.
fn checkBody(arena: std.mem.Allocator, entry: LogEntry, body: []const u8, payload: []const u8, signature: []const u8, certificate_der: []const u8) Error!void {
    if (!std.mem.eql(u8, entry.kindVersion.kind, "dsse") or !std.mem.eql(u8, entry.kindVersion.version, "0.0.1")) return error.Unsupported;
    const Body = struct {
        kind: []const u8,
        spec: struct {
            payloadHash: struct { algorithm: []const u8, value: []const u8 },
            signatures: []const struct { signature: []const u8, verifier: []const u8 },
        },
    };
    const parsed = parse(Body, arena, body) catch |err| return mapParse(err);
    if (!std.mem.eql(u8, parsed.kind, "dsse")) return error.Unsupported;
    var payload_hash: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(payload, &payload_hash, .{});
    const hex = std.fmt.bytesToHex(payload_hash, .lower);
    if (!std.mem.eql(u8, parsed.spec.payloadHash.algorithm, "sha256") or !std.mem.eql(u8, parsed.spec.payloadHash.value, &hex)) return error.NotInLog;
    for (parsed.spec.signatures) |logged| {
        if (!std.mem.eql(u8, try decode(arena, logged.signature), signature)) continue;
        if (std.mem.eql(u8, try pemCertificate(arena, try decode(arena, logged.verifier)), certificate_der)) return;
    }
    return error.NotInLog;
}

/// Checks Rekor's signed entry timestamp: its signature over the entry, its place in the log and
/// the time it was logged.
fn checkTimestamp(arena: std.mem.Allocator, entry: LogEntry, log: Log, time: i64) Error!void {
    const promise = entry.inclusionPromise orelse return error.NotInLog;
    const index = std.fmt.parseInt(u64, entry.logIndex, 10) catch return error.Malformed;
    const id = std.fmt.bytesToHex(log.id, .lower);
    // Rekor signs the entry as canonical JSON: keys in order, no spaces.
    const signed = try std.fmt.allocPrint(arena, "{{\"body\":\"{s}\",\"integratedTime\":{d},\"logID\":\"{s}\",\"logIndex\":{d}}}", .{ entry.canonicalizedBody, time, &id, index });
    try verifyP256(log.key, try decode(arena, promise.signedEntryTimestamp), signed, error.NotInLog);
}

/// Checks the entry is in the log: its inclusion proof leads to the root of a checkpoint that
/// Rekor signed.
fn checkInclusion(arena: std.mem.Allocator, entry: LogEntry, body: []const u8, log: Log) Error!void {
    const proof = entry.inclusionProof orelse return error.NotInLog;
    const index = std.fmt.parseInt(u64, proof.logIndex, 10) catch return error.Malformed;
    const size = std.fmt.parseInt(u64, proof.treeSize, 10) catch return error.Malformed;
    const root_hash = try decodeHash(arena, proof.rootHash);
    const hashes = try arena.alloc([Sha256.digest_length]u8, proof.hashes.len);
    for (hashes, proof.hashes) |*h, text| h.* = try decodeHash(arena, text);
    const found = rootFromProof(index, size, leafHash(body), hashes) orelse return error.NotInLog;
    if (!std.mem.eql(u8, &found, &root_hash)) return error.NotInLog;
    try checkCheckpoint(arena, proof.checkpoint.envelope, size, root_hash, log);
}

/// The Merkle tree hash of a leaf (RFC 9162).
fn leafHash(data: []const u8) [Sha256.digest_length]u8 {
    var h: Sha256 = .init(.{});
    h.update(&.{0});
    h.update(data);
    return h.finalResult();
}

/// The Merkle tree hash of two children (RFC 9162).
fn nodeHash(left: [Sha256.digest_length]u8, right: [Sha256.digest_length]u8) [Sha256.digest_length]u8 {
    var h: Sha256 = .init(.{});
    h.update(&.{1});
    h.update(&left);
    h.update(&right);
    return h.finalResult();
}

/// The root that an inclusion proof gives for leaf `index` of a tree of `size` leaves, or null if
/// the proof has the wrong length for them (RFC 9162, section 2.1.3.2).
fn rootFromProof(index: u64, size: u64, leaf: [Sha256.digest_length]u8, proof: []const [Sha256.digest_length]u8) ?[Sha256.digest_length]u8 {
    if (index >= size) return null;
    var f = index;
    var s = size - 1;
    var r = leaf;
    for (proof) |p| {
        if (s == 0) return null;
        if (f & 1 == 1 or f == s) {
            r = nodeHash(p, r);
            while (f & 1 == 0 and f != 0) {
                f >>= 1;
                s >>= 1;
            }
        } else r = nodeHash(r, p);
        f >>= 1;
        s >>= 1;
    }
    return if (s == 0) r else null;
}

/// Checks a checkpoint, a signed note: its origin is the log's, its size and root are the proof's,
/// and the log's key signed it.
fn checkCheckpoint(arena: std.mem.Allocator, envelope: []const u8, size: u64, root_hash: [Sha256.digest_length]u8, log: Log) Error!void {
    // The note's text, with its final line ending, is what's signed. A blank line separates it
    // from the signatures.
    const text_end = std.mem.indexOf(u8, envelope, "\n\n") orelse return error.Malformed;
    const text = envelope[0 .. text_end + 1];
    var lines = std.mem.splitScalar(u8, envelope[0..text_end], '\n');
    const origin = lines.next() orelse return error.Malformed;
    if (!std.mem.startsWith(u8, origin, log.host) or !std.mem.startsWith(u8, origin[log.host.len..], " - ")) return error.NotInLog;
    const noted_size = std.fmt.parseInt(u64, lines.next() orelse return error.Malformed, 10) catch return error.Malformed;
    const noted_root = try decodeHash(arena, lines.next() orelse return error.Malformed);
    if (noted_size != size or !std.mem.eql(u8, &noted_root, &root_hash)) return error.NotInLog;

    // Each signature line is an em dash, the signer's name, and the key's 4-byte hint followed by
    // the signature, in base64.
    const dash = "\u{2014} ";
    var signatures = std.mem.splitScalar(u8, envelope[text_end + 2 ..], '\n');
    while (signatures.next()) |line| {
        if (!std.mem.startsWith(u8, line, dash)) continue;
        const name, const encoded = std.mem.cutScalar(u8, line[dash.len..], ' ') orelse continue;
        if (!std.mem.eql(u8, name, log.host)) continue;
        const blob = decode(arena, encoded) catch continue;
        if (blob.len <= key_hint_length) continue;
        verifyP256(log.key, blob[key_hint_length..], text, error.NotInLog) catch continue;
        return;
    }
    return error.NotInLog;
}

/// A signed note's signature starts with this many bytes that hint at the key.
const key_hint_length = 4;

/// One of Rekor's logs, from the trusted root.
const Log = struct {
    /// The key's ID, the SHA-256 of its DER encoding.
    id: [Sha256.digest_length]u8,
    /// The host name, which the checkpoints use as their origin and signer.
    host: []const u8,
    key: EcdsaP256.PublicKey,
};

const TrustedRoot = struct {
    tlogs: []const struct {
        baseUrl: []const u8,
        publicKey: struct { rawBytes: []const u8, keyDetails: []const u8 },
        logId: struct { keyId: []const u8 },
    },
    certificateAuthorities: []const struct {
        certChain: struct { certificates: []const struct { rawBytes: []const u8 } },
        validFor: struct { start: []const u8, end: ?[]const u8 = null },
    },
};

/// The trusted root's Rekor log with key ID `id`, if it's one we can check.
fn findLog(arena: std.mem.Allocator, root: TrustedRoot, id: []const u8) Error!Log {
    for (root.tlogs) |tlog| {
        const tlog_id = try decode(arena, tlog.logId.keyId);
        if (tlog_id.len != Sha256.digest_length or !std.mem.eql(u8, tlog_id, id)) continue;
        // Rekor's original log signs with ECDSA on P-256. Its newer logs sign with Ed25519 and
        // write their entries another way, which we don't read yet.
        if (!std.mem.eql(u8, tlog.publicKey.keyDetails, "PKIX_ECDSA_P256_SHA_256")) return error.Unsupported;
        const host = std.mem.cutPrefix(u8, tlog.baseUrl, "https://") orelse return error.Malformed;
        const point = try publicKeyPoint(try decode(arena, tlog.publicKey.rawBytes));
        return .{
            .id = tlog_id[0..Sha256.digest_length].*,
            .host = host,
            .key = EcdsaP256.PublicKey.fromSec1(point) catch return error.Malformed,
        };
    }
    return error.NotInLog;
}

/// Checks `leaf` chains to one of the trusted root's certificate authorities at `time`.
fn checkChain(arena: std.mem.Allocator, root: TrustedRoot, leaf: Certificate.Parsed, time: i64) Error!void {
    for (root.certificateAuthorities) |authority| {
        const start = epochSeconds(authority.validFor.start) orelse return error.Malformed;
        if (time < start) continue;
        if (authority.validFor.end) |end| if (time > (epochSeconds(end) orelse return error.Malformed)) continue;
        var subject = leaf;
        for (authority.certChain.certificates) |certificate| {
            const issuer = try parseCertificate(try decode(arena, certificate.rawBytes));
            subject.verify(issuer, time) catch break;
            subject = issuer;
        } else return;
    }
    return error.UntrustedCertificate;
}

/// Fulcio's extensions for who the certificate is for. The issuer is in two forms: a DER string,
/// and before that, the bare string.
const san_oid = [_]u8{ 0x55, 0x1D, 0x11 };
const issuer_oid = [_]u8{ 0x2B, 0x06, 0x01, 0x04, 0x01, 0x83, 0xBF, 0x30, 0x01, 0x08 };
const legacy_issuer_oid = [_]u8{ 0x2B, 0x06, 0x01, 0x04, 0x01, 0x83, 0xBF, 0x30, 0x01, 0x01 };

/// Checks the certificate names the signer's workflow, as a URI in its subject alternative names,
/// and the signer's issuer.
fn checkSigner(certificate_der: []const u8, signer: Signer) Error!void {
    var workflow = false;
    var issuer = false;
    var extensions = try Extensions.of(certificate_der);
    while (try extensions.next()) |extension| {
        if (std.mem.eql(u8, extension.oid, &san_oid)) {
            const names = try Der.read(extension.value, 0);
            var at = names.start;
            while (at < names.end) {
                const general_name = try Der.read(extension.value, at);
                at = general_name.end;
                if (general_name.tag == @backingInt(Der.Tag.uri) and std.mem.eql(u8, extension.value[general_name.start..general_name.end], signer.workflow)) workflow = true;
            }
        } else if (std.mem.eql(u8, extension.oid, &issuer_oid)) {
            const string = try Der.read(extension.value, 0);
            if (std.mem.eql(u8, extension.value[string.start..string.end], signer.issuer)) issuer = true;
        } else if (std.mem.eql(u8, extension.oid, &legacy_issuer_oid)) {
            if (std.mem.eql(u8, extension.value, signer.issuer)) issuer = true;
        }
    }
    if (!workflow or !issuer) return error.WrongSigner;
}

/// The extensions in a certificate.
const Extensions = struct {
    bytes: []const u8,
    at: u32,
    end: u32,

    const Extension = struct { oid: []const u8, value: []const u8 };

    fn of(bytes: []const u8) Error!Extensions {
        const certificate = try Der.read(bytes, 0);
        const tbs = try Der.read(bytes, certificate.start);
        var at = tbs.start;
        while (at < tbs.end) {
            const element = try Der.read(bytes, at);
            at = element.end;
            if (element.tag != @backingInt(Der.Tag.extensions)) continue;
            const list = try Der.read(bytes, element.start);
            return .{ .bytes = bytes, .at = list.start, .end = list.end };
        }
        return .{ .bytes = bytes, .at = 0, .end = 0 };
    }

    fn next(e: *Extensions) Error!?Extension {
        if (e.at >= e.end) return null;
        const extension = try Der.read(e.bytes, e.at);
        e.at = extension.end;
        const oid = try Der.read(e.bytes, extension.start);
        var value = try Der.read(e.bytes, oid.end);
        // The critical flag is optional.
        if (value.tag == @backingInt(Der.Tag.boolean)) value = try Der.read(e.bytes, value.end);
        if (value.tag != @backingInt(Der.Tag.octet_string)) return error.Malformed;
        return .{ .oid = e.bytes[oid.start..oid.end], .value = e.bytes[value.start..value.end] };
    }
};

/// The EC point in a DER-encoded SubjectPublicKeyInfo.
fn publicKeyPoint(spki: []const u8) Error![]const u8 {
    const info = try Der.read(spki, 0);
    const algorithm = try Der.read(spki, info.start);
    const key = try Der.read(spki, algorithm.end);
    // A bit string starts with how many bits of its last byte are unused, which is 0 for a key.
    if (key.tag != @backingInt(Der.Tag.bit_string) or key.end - key.start < 2 or spki[key.start] != 0) return error.Malformed;
    return spki[key.start + 1 .. key.end];
}

/// One DER element, read with its bounds checked, since the certificates come from the network.
const Der = struct {
    tag: u8,
    start: u32,
    end: u32,

    /// The tags we look for.
    const Tag = enum(u8) {
        boolean = 0x01,
        bit_string = 0x03,
        octet_string = 0x04,
        /// A certificate's extensions, wrapped in context-specific tag 3.
        extensions = 0xA3,
        /// A uniformResourceIdentifier in a list of general names: context-specific tag 6.
        uri = 0x86,
    };
    /// A length's first byte has this bit set when the length's bytes follow it, and the rest of
    /// it counts them. Lengths of more than this many bytes are more than we read.
    const long_length = 0x80;
    const max_length_bytes = 4;
    /// A tag with this bit set holds other elements.
    const constructed = 0x20;

    fn read(bytes: []const u8, at: u32) Error!Der {
        if (at + 2 > bytes.len) return error.Malformed;
        const tag = bytes[at];
        var start = at + 2;
        var length: u32 = bytes[at + 1];
        if (length & long_length != 0) {
            const count = length & ~@as(u32, long_length);
            if (count == 0 or count > max_length_bytes or start + count > bytes.len) return error.Malformed;
            length = 0;
            for (bytes[start..][0..count]) |byte| length = (std.math.shlExact(u32, length, 8) catch return error.Malformed) | byte;
            start += count;
        }
        const end = std.math.add(u32, start, length) catch return error.Malformed;
        if (end > bytes.len) return error.Malformed;
        return .{ .tag = tag, .start = start, .end = end };
    }

    /// Whether every element in `bytes[start..end]`, and inside every constructed one, fits in
    /// its parent.
    fn wellFormed(bytes: []const u8, start: u32, end: u32, depth: u8) bool {
        if (depth > max_depth) return false;
        var at = start;
        while (at < end) {
            const element = read(bytes[0..end], at) catch return false;
            if (element.tag & constructed != 0 and !wellFormed(bytes, element.start, element.end, depth + 1)) return false;
            at = element.end;
        }
        return at == end;
    }

    /// No certificate nests this deep.
    const max_depth = 32;
};

/// Parses a certificate, after checking it's well-formed DER, since the standard library's parser
/// trusts the lengths it reads.
fn parseCertificate(bytes: []const u8) Error!Certificate.Parsed {
    if (bytes.len > std.math.maxInt(u32) or !Der.wellFormed(bytes, 0, @intCast(bytes.len), 0)) return error.Malformed;
    return Certificate.parse(.{ .buffer = bytes, .index = 0 }) catch error.Malformed;
}

/// Verifies an ECDSA signature by a certificate's key, on P-256 or P-384, returning `failure` if it
/// doesn't verify.
fn verifySignature(algorithm: Certificate.Parsed.PubKeyAlgo, key: []const u8, signature: []const u8, message: []const u8, comptime failure: Error) Error!void {
    switch (algorithm) {
        .X9_62_id_ecPublicKey => |curve| switch (curve) {
            .X9_62_prime256v1 => try verifyP256(EcdsaP256.PublicKey.fromSec1(key) catch return error.Malformed, signature, message, failure),
            .secp384r1 => {
                const public_key = EcdsaP384.PublicKey.fromSec1(key) catch return error.Malformed;
                const parsed = EcdsaP384.Signature.fromDer(signature) catch return failure;
                parsed.verify(message, public_key) catch return failure;
            },
            .secp521r1 => return error.Unsupported,
        },
        else => return error.Unsupported,
    }
}

fn verifyP256(key: EcdsaP256.PublicKey, signature: []const u8, message: []const u8, comptime failure: Error) Error!void {
    const parsed = EcdsaP256.Signature.fromDer(signature) catch return failure;
    parsed.verify(message, key) catch return failure;
}

/// The DER of the certificate in a PEM file.
fn pemCertificate(arena: std.mem.Allocator, pem: []const u8) Error![]u8 {
    const begin = "-----BEGIN CERTIFICATE-----";
    const end = "-----END CERTIFICATE-----";
    const start = (std.mem.indexOf(u8, pem, begin) orelse return error.Malformed) + begin.len;
    const stop = std.mem.indexOfPos(u8, pem, start, end) orelse return error.Malformed;
    var text: std.ArrayList(u8) = .empty;
    for (pem[start..stop]) |char| if (!std.ascii.isWhitespace(char)) try text.append(arena, char);
    return decode(arena, text.items);
}

/// Seconds since 1970 for an RFC 3339 time in UTC, like `2022-04-13T20:06:15Z` or with fractions
/// of a second.
fn epochSeconds(text: []const u8) ?i64 {
    if (text.len < "2000-01-01T00:00:00Z".len or text[4] != '-' or text[7] != '-' or text[10] != 'T' or text[13] != ':' or text[16] != ':' or text[text.len - 1] != 'Z') return null;
    const year = std.fmt.parseInt(i64, text[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, text[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, text[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, text[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, text[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, text[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    // Days from 1970-01-01 to the date, by Howard Hinnant's days_from_civil: count years from
    // March, so the leap day comes last, in 400-year eras of the Gregorian calendar.
    const years_per_era = 400;
    const days_per_era = 146097;
    // Days from 0000-03-01, where the eras start, to 1970-01-01.
    const days_to_1970 = 719468;
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, years_per_era);
    const year_of_era = y - era * years_per_era;
    const month_from_march: i64 = if (month > 2) month - 3 else month + 9;
    // The days before each month from March: 0, 31, 61, 92 and so on.
    const day_of_year = @divFloor(153 * month_from_march + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    const days = era * days_per_era + day_of_era - days_to_1970;
    return days * std.time.s_per_day + hour * std.time.s_per_hour + minute * std.time.s_per_min + second;
}

fn decode(arena: std.mem.Allocator, text: []const u8) Error![]u8 {
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(text) catch return error.Malformed;
    const out = try arena.alloc(u8, size);
    decoder.decode(out, text) catch return error.Malformed;
    return out;
}

fn decodeHash(arena: std.mem.Allocator, text: []const u8) Error![Sha256.digest_length]u8 {
    const bytes = try decode(arena, text);
    if (bytes.len != Sha256.digest_length) return error.Malformed;
    return bytes[0..Sha256.digest_length].*;
}

fn parse(comptime T: type, arena: std.mem.Allocator, json: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, arena, json, .{ .ignore_unknown_fields = true });
}

fn mapParse(err: anyerror) Error {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.Malformed;
}

// Tests use GitHub's real attestation for 0.3.1's Mac build for Apple silicon.
const test_response = @embedFile("testdata/attestation-v0.3.1-macos-aarch64.json");
const test_name = "minilab-v0.3.1-macos-aarch64.tar.gz";
const test_digest = digestOf("aa29f494889f3674d57213d15e5baa191707bbd6102cd42ab3347dcc12329998");
const test_signer: Signer = .{ .workflow = "https://github.com/vdmkenny/minilab/.github/workflows/release.yml@refs/heads/main" };

fn digestOf(comptime hex: []const u8) [Sha256.digest_length]u8 {
    var out: [Sha256.digest_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

test "GitHub's attestation for a release build verifies" {
    try verifyResponse(std.testing.allocator, test_response, test_name, test_digest, test_signer);
}

test "an attestation doesn't vouch for another file, digest or workflow" {
    const gpa = std.testing.allocator;
    var other_digest = test_digest;
    other_digest[0] ^= 1;
    try std.testing.expectError(error.NotForThisFile, verifyResponse(gpa, test_response, test_name, other_digest, test_signer));
    try std.testing.expectError(error.NotForThisFile, verifyResponse(gpa, test_response, "minilab-v0.3.1-linux-x86_64.tar.gz", test_digest, test_signer));
    try std.testing.expectError(error.WrongSigner, verifyResponse(gpa, test_response, test_name, test_digest, .{ .workflow = "https://github.com/someone/else/.github/workflows/release.yml@refs/heads/main" }));
}

test "a changed log entry doesn't verify" {
    const gpa = std.testing.allocator;
    // Moving the time Rekor logged it breaks its signed timestamp.
    const moved = try std.mem.replaceOwned(u8, gpa, test_response, "\"integratedTime\": \"1792764039\"", "\"integratedTime\": \"1792764040\"");
    defer gpa.free(moved);
    try std.testing.expect(!std.mem.eql(u8, moved, test_response));
    try std.testing.expectError(error.NotInLog, verifyResponse(gpa, moved, test_name, test_digest, test_signer));
}

/// A copy of `text` with one base64 character changed, `offset` characters after `marker`.
fn tampered(gpa: std.mem.Allocator, text: []const u8, marker: []const u8, offset: usize) ![]u8 {
    const copy = try gpa.dupe(u8, text);
    const at = (std.mem.indexOf(u8, copy, marker) orelse return error.TestMarkerMissing) + marker.len + offset;
    copy[at] = if (copy[at] == 'A') 'B' else 'A';
    return copy;
}

test "every part of the attestation is checked" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { marker: []const u8, offset: usize, expected: ?Error }{
        // The statement's signature.
        .{ .marker = "\"sig\": \"", .offset = 20, .expected = error.BadSignature },
        // The tree root the inclusion proof leads to.
        .{ .marker = "\"rootHash\": \"", .offset = 10, .expected = error.NotInLog },
        // Rekor's signature on the checkpoint.
        .{ .marker = "rekor.sigstore.dev wNI9", .offset = 20, .expected = error.NotInLog },
        // The logged entry, and the certificate: either breaks something, whichever comes first.
        .{ .marker = "\"canonicalizedBody\": \"", .offset = 200, .expected = null },
        .{ .marker = "\"rawBytes\": \"", .offset = 300, .expected = null },
    };
    for (cases) |case| {
        const changed = try tampered(gpa, test_response, case.marker, case.offset);
        defer gpa.free(changed);
        const result = verifyResponse(gpa, changed, test_name, test_digest, test_signer);
        if (case.expected) |expected| try std.testing.expectError(expected, result) else try std.testing.expect(std.meta.isError(result));
    }
}

test "the certificate is only trusted while it was valid, and only for its signer" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Response = struct { attestations: []const struct { bundle: Bundle } };
    const bundle = (try parse(Response, arena, test_response)).attestations[0].bundle;
    const certificate_der = try decode(arena, bundle.verificationMaterial.certificate.?.rawBytes);
    const leaf = try parseCertificate(certificate_der);
    const logged = try std.fmt.parseInt(i64, bundle.verificationMaterial.tlogEntries[0].integratedTime, 10);
    const root = try parse(TrustedRoot, arena, trusted_root_json);
    try checkChain(arena, root, leaf, logged);
    try std.testing.expectError(error.UntrustedCertificate, checkChain(arena, root, leaf, logged + std.time.s_per_day));
    try std.testing.expectError(error.WrongSigner, checkSigner(certificate_der, .{ .workflow = test_signer.workflow, .issuer = "https://accounts.google.com" }));
}

test "an inclusion proof leads to the tree's root" {
    // A tree of three leaves: root = H(H(a, b), c).
    const a = leafHash("a");
    const b = leafHash("b");
    const c = leafHash("c");
    const ab = nodeHash(a, b);
    const root = nodeHash(ab, c);
    try std.testing.expectEqual(root, rootFromProof(0, 3, a, &.{ b, c }).?);
    try std.testing.expectEqual(root, rootFromProof(2, 3, c, &.{ab}).?);
    try std.testing.expectEqual(@as(?[Sha256.digest_length]u8, null), rootFromProof(2, 3, c, &.{ ab, a }));
    try std.testing.expectEqual(@as(?[Sha256.digest_length]u8, null), rootFromProof(3, 3, c, &.{ab}));
}

test "RFC 3339 times become seconds since 1970" {
    try std.testing.expectEqual(@as(?i64, 0), epochSeconds("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(?i64, 1649880375), epochSeconds("2022-04-13T20:06:15Z"));
    try std.testing.expectEqual(@as(?i64, 1672531199), epochSeconds("2022-12-31T23:59:59.999Z"));
    try std.testing.expectEqual(@as(?i64, null), epochSeconds("yesterday"));
}

test "badly formed DER is caught before it's read" {
    try std.testing.expectError(error.Malformed, parseCertificate(&.{ 0x30, 0x82, 0xff, 0xff, 0x00 }));
    try std.testing.expectError(error.Malformed, parseCertificate(&.{ 0x30, 0x03, 0x30, 0x05, 0x00 }));
}
