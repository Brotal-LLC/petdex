//! Fetch-merge-writeback staging for remote agents.
//!
//! The desktop cannot run its installers against a remote home, and a
//! blind overwrite would clobber the remote user's existing hooks. The
//! compromise: stage a FAKE HOME in a local temp dir, fetch the files
//! the installer merges (ssh cat, done by the caller via fx.spawn),
//! run the exact local installer against the fake home, then hand back
//! the list of files to push (ssh write spawns, also the caller's).
//! Merge logic stays in agent_hooks.zig, untwinned; this module only
//! knows which files each agent reads and writes.

const std = @import("std");
const agent_hooks = @import("agent_hooks.zig");
const remote_ssh = @import("remote_ssh.zig");
const plat = @import("plat.zig");

const AgentKind = agent_hooks.AgentKind;

/// The remote hook script, embedded like the opencode plugin. Pushed
/// to ~/.petdex/bin/petdex-hook on the remote for every shell-exec
/// agent (codex, hermes); opencode's plugin POSTs directly and never
/// execs it.
pub const hook_script: []const u8 = @embedFile("assets/petdex-remote-hook.sh");

/// One file to push: `rel` under the fake home, `remote` as the
/// `~/`-relative path on the remote, bytes read back after the
/// installer ran.
pub const Output = struct {
    rel: []const u8,
    remote: []const u8,
    bytes: []u8,
    executable: bool,
};

/// The files each remote-capable agent's installer reads (for merge)
/// and writes (for pushback), as fake-home-relative paths. The remote
/// path is always "~/" ++ rel, which is what keeps this table the
/// single place that mapping can drift.
const opencode_files = [_][]const u8{".config/opencode/plugins/petdex.js"};
const codex_files = [_][]const u8{ ".codex/hooks.json", ".codex/config.toml" };
const hermes_files = [_][]const u8{ ".hermes/config.yaml", ".hermes/shell-hooks-allowlist.json" };

fn filesFor(kind: AgentKind) ?[]const []const u8 {
    return switch (kind) {
        .opencode => &opencode_files,
        .codex => &codex_files,
        .hermes => &hermes_files,
        else => null,
    };
}

/// Public read view of the per-agent file table: the runtime fetch
/// loop walks these rel paths, one ssh cat each.
pub fn filesOf(kind: AgentKind) []const []const u8 {
    return filesFor(kind) orelse &.{};
}

/// True when this agent's remote config execs the hook binary, so the
/// sh script must be pushed alongside its files.
fn needsHookScript(kind: AgentKind) bool {
    return switch (kind) {
        .codex, .hermes => true,
        else => false,
    };
}

/// Stage one fetched remote file into the fake home. Null bytes mean
/// the remote file does not exist (ssh cat failed) — nothing staged,
/// and the installer treats it as a fresh install.
pub fn stageFetched(fake_home: []const u8, rel: []const u8, bytes: ?[]const u8) bool {
    const content = bytes orelse return true;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ fake_home, rel }) catch return false;
    var dir_buf: [512]u8 = undefined;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return false;
    const dir = std.fmt.bufPrint(&dir_buf, "{s}", .{path[0..slash]}) catch return false;
    plat.makeDir(dir);
    return plat.writeFile(path, content);
}

/// Run the agent's own installer against the fake home — the same
/// merge, consent, and validation rules as a local connect. Parent
/// dirs are pre-created for every file the agent touches: locally the
/// agent's own install created them, but a fresh fake home (or a fresh
/// remote) has nothing, and not every installer mkdirs its own root.
pub fn runInstaller(allocator: std.mem.Allocator, kind: AgentKind, fake_home: []const u8) bool {
    for (filesOf(kind)) |rel| {
        var dir_buf: [512]u8 = undefined;
        const slash = std.mem.lastIndexOfScalar(u8, rel, '/') orelse continue;
        const dir = std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ fake_home, rel[0..slash] }) catch return false;
        plat.makeDir(dir);
    }
    return switch (kind) {
        .opencode => agent_hooks.installOpencode(allocator, fake_home),
        .codex => agent_hooks.installCodex(allocator, fake_home),
        .hermes => agent_hooks.installHermes(allocator, fake_home),
        else => false,
    };
}

/// Read back everything a push must carry: the agent's files, plus the
/// hook script for shell-exec agents. Null on any read failure — a
/// partial push set would leave the remote half-configured.
pub fn collectOutputs(allocator: std.mem.Allocator, kind: AgentKind, fake_home: []const u8) ?[]Output {
    const files = filesFor(kind) orelse return null;
    const extra: usize = if (needsHookScript(kind)) 1 else 0;
    var out = allocator.alloc(Output, files.len + extra) catch return null;
    for (files, 0..) |rel, i| {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ fake_home, rel }) catch return null;
        const bytes = plat.readFileAlloc(allocator, path, 1024 * 1024) orelse return null;
        var remote_buf: [512]u8 = undefined;
        const remote = std.fmt.bufPrint(&remote_buf, "~/{s}", .{rel}) catch return null;
        out[i] = .{
            .rel = allocator.dupe(u8, rel) catch return null,
            .remote = allocator.dupe(u8, remote) catch return null,
            .bytes = bytes,
            .executable = false,
        };
    }
    if (needsHookScript(kind)) {
        out[files.len] = .{
            .rel = ".petdex/bin/petdex-hook",
            .remote = remote_ssh.remote_hook_script,
            .bytes = allocator.dupe(u8, hook_script) catch return null,
            .executable = true,
        };
    }
    return out;
}

// -------------------------------------------------------------- tests

const t = std.testing;

test "codex writeback merges a fetched remote hooks.json" {
    if (@import("builtin").os.tag == .windows) return;
    const fake = ".zig-cache/petdex-wb-codex";
    plat.makeDir(fake);

    // The remote already has a user hook; fetch staged it.
    try t.expect(stageFetched(fake, ".codex/hooks.json",
        \\{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"my-own"}]}]}}
    ));
    // config.toml absent remotely: stageFetched(null) stages nothing.
    try t.expect(stageFetched(fake, ".codex/config.toml", null));

    try t.expect(runInstaller(t.allocator, .codex, fake));

    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const outs = collectOutputs(arena.allocator(), .codex, fake).?;
    try t.expectEqual(@as(usize, 3), outs.len);
    try t.expectEqualStrings(".codex/hooks.json", outs[0].rel);
    try t.expectEqualStrings("~/.codex/hooks.json", outs[0].remote);
    try t.expect(std.mem.indexOf(u8, outs[0].bytes, "my-own") != null);
    try t.expect(std.mem.indexOf(u8, outs[0].bytes, "petdex-hook") != null);
    try t.expect(std.mem.indexOf(u8, outs[1].bytes, "hooks = true") != null);
    // The sh script rides along, executable, at the shared hook path.
    try t.expectEqualStrings(remote_ssh.remote_hook_script, outs[2].remote);
    try t.expect(outs[2].executable);
    try t.expect(std.mem.indexOf(u8, outs[2].bytes, "petdex-update-token") != null);
}

test "hermes writeback preserves foreign YAML and allowlist entries" {
    if (@import("builtin").os.tag == .windows) return;
    const fake = ".zig-cache/petdex-wb-hermes";
    plat.makeDir(fake);

    try t.expect(stageFetched(fake, ".hermes/config.yaml",
        \\model: some-model
        \\hooks:
        \\  pre_tool_call:
        \\    - my-own-linter
        \\
    ));
    try t.expect(stageFetched(fake, ".hermes/shell-hooks-allowlist.json",
        \\{"approvals":[{"event":"pre_tool_call","command":"my-own-linter"}]}
    ));

    try t.expect(runInstaller(t.allocator, .hermes, fake));

    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const outs = collectOutputs(arena.allocator(), .hermes, fake).?;
    try t.expectEqual(@as(usize, 3), outs.len);
    try t.expect(std.mem.indexOf(u8, outs[0].bytes, "my-own-linter") != null);
    try t.expect(std.mem.indexOf(u8, outs[0].bytes, "petdex-hook") != null);
    try t.expect(std.mem.indexOf(u8, outs[1].bytes, "my-own-linter") != null);
    try t.expect(outs[2].executable);
}

test "opencode writeback is the plugin alone, no hook script" {
    if (@import("builtin").os.tag == .windows) return;
    const fake = ".zig-cache/petdex-wb-opencode";
    plat.makeDir(fake);

    try t.expect(runInstaller(t.allocator, .opencode, fake));

    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const outs = collectOutputs(arena.allocator(), .opencode, fake).?;
    try t.expectEqual(@as(usize, 1), outs.len);
    try t.expectEqualStrings("~/.config/opencode/plugins/petdex.js", outs[0].remote);
    try t.expect(std.mem.indexOf(u8, outs[0].bytes, "HOOK_SERVER_URL") != null);
    try t.expect(!outs[0].executable);
}

test "non-remote-capable kinds stage nothing" {
    try t.expect(filesFor(.claude_code) == null);
    try t.expect(!needsHookScript(.opencode));
    try t.expect(!runInstaller(t.allocator, .claude_code, ".zig-cache/petdex-wb-none"));
}
