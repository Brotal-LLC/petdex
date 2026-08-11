//! SSH transport for remote agents: pure argv builders for every ssh
//! invocation the tunnel supervisor and the writeback installer need.
//!
//! Everything here returns argv for `fx.spawn`; nothing spawns, so the
//! whole module is unit-testable without a network. The rules that keep
//! the transport safe live here exactly once:
//!
//!   - BatchMode=yes: ssh must never block on a password prompt inside
//!     an effect worker; auth failure is an exit code, not a hang.
//!   - The destination is one argv element and every remote path is
//!     single-quoted inside the remote command string, so a hostile
//!     config value cannot become a remote shell injection.
//!   - Remote paths use `~/` prefixes, expanded by the remote login
//!     shell — the remote's home is never guessed from the desktop's.
//!
//! fx.spawn budget (16 argv elements / 2048 argv bytes / 4096 stdin
//! bytes) shapes the write path: a file that fits stdin goes in one
//! `cat >` spawn, anything larger is chunked by the caller into one
//! `cat >` plus `cat >>` appends (see stdin_chunk).

const std = @import("std");
const builtin = @import("builtin");
const remote_agents = @import("remote_agents.zig");
const plat = @import("plat.zig");

const Remote = remote_agents.Remote;

pub const max_argv = 16;

/// Largest stdin payload one write spawn carries. Under the fx.spawn
/// 4096 cap with margin; the caller sequences `cat >` then `cat >>`.
pub const stdin_chunk = 3072;

/// Remote-side locations, always `~/`-relative so the remote shell
/// resolves them against the account that actually logged in.
///
/// The remote hook script deliberately lands at the SAME path the
/// desktop's hook binary occupies locally: the merged hook configs
/// (codex hooks.json, hermes config.yaml) name this path, so one
/// config works on both sides of the tunnel — a symlinked Zig binary
/// on the desktop, a POSIX sh script on the remote.
pub const remote_hook_script = "~/.petdex/bin/petdex-hook";
pub const remote_token_file = "~/.petdex/runtime/update-token";
pub const remote_opencode_plugin = "~/.config/opencode/plugins/petdex.js";
pub const remote_codex_hooks = "~/.codex/hooks.json";
pub const remote_hermes_config = "~/.hermes/config.yaml";
pub const remote_hermes_allowlist = "~/.hermes/shell-hooks-allowlist.json";

/// The desktop hook server the tunnel exposes on the remote's
/// loopback. Remote hook payloads post to 127.0.0.1:7777 there and ssh
/// delivers them to 127.0.0.1:7777 here.
pub const tunnel_spec = "127.0.0.1:7777:127.0.0.1:7777";

/// Absolute paths first so a hijacked PATH cannot substitute ssh,
/// matching installer's downloader probing.
const ssh_candidates = [_][]const u8{ "/usr/bin/ssh", "/bin/ssh" };

/// Path to a usable ssh client, null when none exists (Windows remotes
/// are out of scope for v1; a desktop without ssh cannot manage
/// remotes at all).
pub fn detect() ?[]const u8 {
    if (builtin.os.tag == .windows) return null;
    for (ssh_candidates) |path| {
        if (plat.fileExists(path)) return path;
    }
    return null;
}

/// Scratch storage for formatted port numbers, quoted paths, and the
/// remote command string. One per spawn; builders null on overflow.
pub const Scratch = struct {
    port: [12]u8 = undefined,
    identity: [384]u8 = undefined,
    quote_a: [512]u8 = undefined,
    quote_b: [512]u8 = undefined,
    cmd: [1024]u8 = undefined,
};

/// Quote one path for the remote shell: wrapped in single quotes, any
/// embedded quote becoming the classic '\'' sequence. Paths we invent
/// never contain quotes, but a config-provided prefix could, and an
/// unquoted metacharacter here is a remote command injection.
pub fn shQuote(buf: []u8, path: []const u8) ?[]const u8 {
    var n: usize = 0;
    if (n >= buf.len) return null;
    buf[n] = '\'';
    n += 1;
    for (path) |c| {
        if (c == '\'') {
            if (n + 4 > buf.len) return null;
            buf[n .. n + 4][0..4].* = "'\\''".*;
            n += 4;
        } else {
            if (n >= buf.len) return null;
            buf[n] = c;
            n += 1;
        }
    }
    if (n >= buf.len) return null;
    buf[n] = '\'';
    n += 1;
    return buf[0..n];
}

/// The directory part of a `~/a/b/c` path (`~/a/b`), for mkdir -p.
fn dirname(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[0..slash];
}

/// Shared SSH option prefix. Returns the next free argv index without
/// writing the `-- <destination>` tail, because the reverse tunnel has
/// additional SSH options that must precede the destination too.
fn appendOptions(buf: *[max_argv][]const u8, scratch: *Scratch, remote: *const Remote) ?usize {
    const ssh = detect() orelse return null;
    var n: usize = 0;
    buf[n] = ssh;
    n += 1;
    for ([_][]const u8{
        "-oBatchMode=yes",
        "-oConnectTimeout=8",
        "-oServerAliveInterval=15",
        "-oServerAliveCountMax=3",
        // TOFU: a never-seen host key is accepted and pinned; a CHANGED
        // one still hard-fails. Bare BatchMode would fail every first
        // connect on the host-key prompt nobody can answer.
        "-oStrictHostKeyChecking=accept-new",
    }) |arg| {
        buf[n] = arg;
        n += 1;
    }
    if (remote.port != 22) {
        buf[n] = std.fmt.bufPrint(&scratch.port, "-p{d}", .{remote.port}) catch return null;
        n += 1;
    }
    if (remote.identity_file) |identity| {
        buf[n] = std.fmt.bufPrint(scratch.identity[0..], "-i{s}", .{identity}) catch return null;
        n += 1;
    }
    return n;
}

/// Append the option terminator and destination after all SSH switches.
fn appendDestination(buf: *[max_argv][]const u8, n: usize, remote: *const Remote) ?usize {
    if (n + 2 > max_argv) return null;
    buf[n] = "--";
    buf[n + 1] = remote.host;
    return n + 2;
}

/// Shared connection prefix for commands that do not need further SSH
/// options. The destination is always its own argv element, never embedded
/// in a remote command string.
fn appendBase(buf: *[max_argv][]const u8, scratch: *Scratch, remote: *const Remote) ?usize {
    const n = appendOptions(buf, scratch, remote) orelse return null;
    return appendDestination(buf, n, remote);
}

/// Long-lived reverse tunnel: remote 127.0.0.1:7777 back to the
/// desktop hook server. -N -T because no command runs and no pty is
/// wanted; ExitOnForwardFailure turns a taken port into a fast exit so
/// the supervisor's backoff sees a real failure instead of a silent
/// half-open tunnel.
pub fn tunnelArgv(buf: *[max_argv][]const u8, scratch: *Scratch, remote: *const Remote) ?[]const []const u8 {
    const n = appendOptions(buf, scratch, remote) orelse return null;
    if (n + 8 > max_argv) return null;
    buf[n] = "-N";
    buf[n + 1] = "-T";
    buf[n + 2] = "-o";
    buf[n + 3] = "ExitOnForwardFailure=yes";
    buf[n + 4] = "-R";
    buf[n + 5] = tunnel_spec;
    const end = appendDestination(buf, n + 6, remote) orelse return null;
    return buf[0..end];
}

/// Cheap reachability check: auth, network, and shell in one round
/// trip. Exit 0 means the remote is manageable.
pub fn probeArgv(buf: *[max_argv][]const u8, scratch: *Scratch, remote: *const Remote) ?[]const []const u8 {
    const n = appendBase(buf, scratch, remote) orelse return null;
    if (n + 1 > max_argv) return null;
    buf[n] = "true";
    return buf[0 .. n + 1];
}

/// `cat -- '<path>'` on the remote; stdout is collected by the spawn.
pub fn readArgv(buf: *[max_argv][]const u8, scratch: *Scratch, remote: *const Remote, path: []const u8) ?[]const []const u8 {
    const n = appendBase(buf, scratch, remote) orelse return null;
    if (n + 1 > max_argv) return null;
    const quoted = shQuote(&scratch.quote_a, path) orelse return null;
    buf[n] = std.fmt.bufPrint(&scratch.cmd, "cat -- {s}", .{quoted}) catch return null;
    return buf[0 .. n + 1];
}

/// Write spawn: the first chunk mkdirs and truncates, later chunks
/// append. Bytes ride stdin, never argv, so content cannot be read as
/// flags and binary bytes survive untouched. Executable files (the
/// remote hook script) get their chmod folded into the first chunk so
/// a partial write never leaves an executable-bit-less script that a
/// merged config already points at... which is still harmless, but
/// one spawn fewer.
pub fn writeArgv(
    buf: *[max_argv][]const u8,
    scratch: *Scratch,
    remote: *const Remote,
    path: []const u8,
    first_chunk: bool,
    executable: bool,
) ?[]const []const u8 {
    const n = appendBase(buf, scratch, remote) orelse return null;
    if (n + 1 > max_argv) return null;
    const quoted = shQuote(&scratch.quote_a, path) orelse return null;
    if (first_chunk) {
        const dir = shQuote(&scratch.quote_b, dirname(path)) orelse return null;
        if (executable) {
            buf[n] = std.fmt.bufPrint(&scratch.cmd, "mkdir -p {s} && cat > {s} && chmod 755 {s}", .{ dir, quoted, quoted }) catch return null;
        } else {
            buf[n] = std.fmt.bufPrint(&scratch.cmd, "mkdir -p {s} && cat > {s}", .{ dir, quoted }) catch return null;
        }
    } else {
        buf[n] = std.fmt.bufPrint(&scratch.cmd, "cat >> {s}", .{quoted}) catch return null;
    }
    return buf[0 .. n + 1];
}

/// Push the hook-server update token after every hook_server.start()
/// and tunnel reconnect: the remote hook script authenticates its
/// posts with it. umask before cat so the file lands 0600 even on a
/// permissive remote default.
pub fn tokenArgv(buf: *[max_argv][]const u8, scratch: *Scratch, remote: *const Remote) ?[]const []const u8 {
    const n = appendBase(buf, scratch, remote) orelse return null;
    if (n + 1 > max_argv) return null;
    const quoted = shQuote(&scratch.quote_a, remote_token_file) orelse return null;
    const dir = shQuote(&scratch.quote_b, dirname(remote_token_file)) orelse return null;
    buf[n] = std.fmt.bufPrint(&scratch.cmd, "umask 077; mkdir -p {s} && cat > {s}", .{ dir, quoted }) catch return null;
    return buf[0 .. n + 1];
}

/// How many write spawns a file of `total` bytes needs.
pub fn chunkCount(total: usize) usize {
    if (total == 0) return 1;
    return (total + stdin_chunk - 1) / stdin_chunk;
}

// -------------------------------------------------------------- tests

const t = std.testing;

const test_remote = Remote{
    .name = "rogue",
    .host = "shakib@rogue.lan",
    .port = 2222,
    .identity_file = "~/.ssh/id_ed25519",
};

fn joined(argv: []const []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    for (argv) |arg| {
        if (n > 0) {
            buf[n] = ' ';
            n += 1;
        }
        @memcpy(buf[n .. n + arg.len], arg);
        n += arg.len;
    }
    return buf[0..n];
}

test "appendBase puts safety flags before a quoted-free destination" {
    if (detect() == null) return;
    var buf: [max_argv][]const u8 = undefined;
    var scratch: Scratch = .{};
    var line: [1024]u8 = undefined;
    const argv = probeArgv(&buf, &scratch, &test_remote).?;
    const text = joined(argv, &line);
    try t.expect(std.mem.indexOf(u8, text, "BatchMode=yes") != null);
    try t.expect(std.mem.indexOf(u8, text, "ConnectTimeout=8") != null);
    try t.expect(std.mem.indexOf(u8, text, "StrictHostKeyChecking=accept-new") != null);
    try t.expect(std.mem.indexOf(u8, text, "-p2222") != null);
    try t.expect(std.mem.indexOf(u8, text, "-i~/.ssh/id_ed25519") != null);
    // Destination is its own argv element, immediately before the
    // remote command, and never quoted into it.
    try t.expectEqualStrings("shakib@rogue.lan", argv[argv.len - 2]);
    try t.expectEqualStrings("true", argv[argv.len - 1]);
}

test "appendBase omits -p and -i at their defaults" {
    if (detect() == null) return;
    const plain = Remote{ .name = "r", .host = "10.0.0.8" };
    var buf: [max_argv][]const u8 = undefined;
    var scratch: Scratch = .{};
    const argv = probeArgv(&buf, &scratch, &plain).?;
    for (argv) |arg| {
        try t.expect(!std.mem.startsWith(u8, arg, "-p"));
        try t.expect(!std.mem.startsWith(u8, arg, "-i"));
    }
}

test "tunnelArgv requests the reverse forward with fast failure" {
    if (detect() == null) return;
    var buf: [max_argv][]const u8 = undefined;
    var scratch: Scratch = .{};
    const argv = tunnelArgv(&buf, &scratch, &test_remote).?;
    try t.expectEqualStrings("--", argv[argv.len - 2]);
    try t.expectEqualStrings(test_remote.host, argv[argv.len - 1]);
    try t.expectEqualStrings(tunnel_spec, argv[argv.len - 3]);
    var line: [1024]u8 = undefined;
    const text = joined(argv, &line);
    try t.expect(std.mem.indexOf(u8, text, "-N") != null);
    try t.expect(std.mem.indexOf(u8, text, "-T") != null);
    try t.expect(std.mem.indexOf(u8, text, "ExitOnForwardFailure=yes") != null);
    try t.expect(std.mem.indexOf(u8, text, "-R") != null);
}

test "read and write quote remote paths for the remote shell" {
    if (detect() == null) return;
    var buf: [max_argv][]const u8 = undefined;
    var scratch: Scratch = .{};
    const rd = readArgv(&buf, &scratch, &test_remote, remote_codex_hooks).?;
    try t.expectEqualStrings("cat -- '~/.codex/hooks.json'", rd[rd.len - 1]);

    var scratch2: Scratch = .{};
    const wr = writeArgv(&buf, &scratch2, &test_remote, remote_opencode_plugin, true, false).?;
    try t.expectEqualStrings(
        "mkdir -p '~/.config/opencode/plugins' && cat > '~/.config/opencode/plugins/petdex.js'",
        wr[wr.len - 1],
    );

    var scratch3: Scratch = .{};
    const app = writeArgv(&buf, &scratch3, &test_remote, remote_opencode_plugin, false, false).?;
    try t.expectEqualStrings("cat >> '~/.config/opencode/plugins/petdex.js'", app[app.len - 1]);

    var scratch4: Scratch = .{};
    const exe = writeArgv(&buf, &scratch4, &test_remote, remote_hook_script, true, true).?;
    try t.expectEqualStrings(
        "mkdir -p '~/.petdex/bin' && cat > '~/.petdex/bin/petdex-hook' && chmod 755 '~/.petdex/bin/petdex-hook'",
        exe[exe.len - 1],
    );
}

test "shQuote escapes embedded quotes instead of trusting the path" {
    var qb: [512]u8 = undefined;
    try t.expectEqualStrings("'~/x/y'", shQuote(&qb, "~/x/y").?);
    try t.expectEqualStrings("'a'\\''b'", shQuote(&qb, "a'b").?);
    // No silent truncation: an over-long path is null, not a cut string.
    try t.expect(shQuote(qb[0..4], "~/x/y") == null);
}

test "tokenArgv lands the token 0600 under ~/.petdex" {
    if (detect() == null) return;
    var buf: [max_argv][]const u8 = undefined;
    var scratch: Scratch = .{};
    const argv = tokenArgv(&buf, &scratch, &test_remote).?;
    try t.expectEqualStrings(
        "umask 077; mkdir -p '~/.petdex/runtime' && cat > '~/.petdex/runtime/update-token'",
        argv[argv.len - 1],
    );
}

test "chunkCount splits at the stdin budget" {
    try t.expectEqual(@as(usize, 1), chunkCount(0));
    try t.expectEqual(@as(usize, 1), chunkCount(stdin_chunk));
    try t.expectEqual(@as(usize, 2), chunkCount(stdin_chunk + 1));
    // The opencode plugin must stay chunkable: the whole reason the
    // append form exists.
    try t.expectEqual(@as(usize, 3), chunkCount(8301));
}
