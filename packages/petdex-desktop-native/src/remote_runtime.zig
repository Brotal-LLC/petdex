//! Remote runtime driver: the per-remote state machine that sequences
//! probe -> fetch-merge-writeback -> token push -> tunnel, plus tunnel
//! reconnect backoff. Pure of SDK types: it returns Actions and main.zig
//! turns them into fx.spawn / fx.startTimer calls, so the whole flow is
//! unit-testable with fixture homes and no effects runtime.
//!
//! One writeback pass runs per remote per app run (boot or a Settings
//! sync action); the tunnel then runs for the app's lifetime, respawned
//! with backoff when it dies. fs work (staging fetched bytes, running
//! the local installers against the fake home) happens inside the
//! driver via plat, not in main.zig.

const std = @import("std");
const agent_hooks = @import("agent_hooks.zig");
const remote_agents = @import("remote_agents.zig");
const remote_ssh = @import("remote_ssh.zig");
const remote_writeback = @import("remote_writeback.zig");
const plat = @import("plat.zig");

const AgentKind = agent_hooks.AgentKind;

pub const max_remotes = 8;

/// Spawn kinds a slot can have in flight. Key derivation tags the
/// slot's key with these; backoff rides a timer tag instead.
pub const Op = enum { none, probe, fetch, push, token, tunnel };

/// Key space far above the hand-numbered single-digit keys main.zig
/// uses for its own effects. 16 tags per slot leaves room.
pub const key_base: u64 = @as(u64, 1) << 40;

fn opTag(op: Op) u64 {
    return switch (op) {
        .none => 0,
        .probe => 1,
        .fetch => 2,
        .push => 3,
        .token => 4,
        .tunnel => 5,
    };
}

const backoff_tag: u64 = 15;

pub fn keyFor(slot_idx: usize, op: Op) u64 {
    return key_base + @as(u64, slot_idx) * 16 + opTag(op);
}

pub fn backoffKey(slot_idx: usize) u64 {
    return key_base + @as(u64, slot_idx) * 16 + backoff_tag;
}

/// Decode a spawn key back to (slot, op); null for foreign keys.
pub fn slotOpFromKey(key: u64) ?struct { slot: usize, op: Op } {
    if (key < key_base) return null;
    const off = key - key_base;
    const tag = off % 16;
    const slot = off / 16;
    if (slot >= max_remotes) return null;
    inline for ([_]Op{ .probe, .fetch, .push, .token, .tunnel }) |op| {
        if (opTag(op) == tag) return .{ .slot = slot, .op = op };
    }
    return null;
}

pub fn slotFromBackoffKey(key: u64) ?usize {
    if (key < key_base) return null;
    const off = key - key_base;
    if (off % 16 != backoff_tag) return null;
    const slot = off / 16;
    return if (slot < max_remotes) slot else null;
}

/// POD per-remote state, embedded in the Model. Strings are fixed
/// buffers; heap content (fetched bytes, push payloads) lives in the
/// module-level stores below, never in the Model.
pub const Slot = struct {
    active: bool = false,
    name: [33]u8 = @splat(0),
    name_len: usize = 0,
    host: [256]u8 = @splat(0),
    host_len: usize = 0,
    port: u16 = 22,
    identity: [384]u8 = @splat(0),
    identity_len: usize = 0,
    kinds: [3]AgentKind = undefined,
    kind_count: usize = 0,
    op: Op = .none,
    probe_failed: bool = false,
    wb_failed: bool = false,
    kind_idx: usize = 0,
    file_idx: usize = 0,
    output_idx: usize = 0,
    chunk_idx: usize = 0,
    backoff_ms: u32 = 0,

    pub fn nameSlice(self: *const Slot) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Heap stores indexed by slot, kept out of the Model: the collected
/// push outputs for the agent currently being written back, and the
/// token stdin bytes (the exit Msg's slices die with the update call,
/// so anything a later spawn needs must live here).
var outputs: [max_remotes]?[]remote_writeback.Output = .{null} ** max_remotes;
var token_bufs: [max_remotes][128]u8 = undefined;
var token_lens: [max_remotes]usize = .{0} ** max_remotes;

/// One arena for every writeback's staged bytes and output lists.
/// Bounded per app run (remotes x agents x files), never reset: the
/// alternative — freeing mid-cursor — is how a push chunk's stdin
/// points at freed memory.
var wb_arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const wb_arena = wb_arena_state.allocator();

/// What main.zig should do next for a slot. Slices in .spawn point at
/// static tables or the slot's heap store, both of which outlive the
/// update call.
pub const Action = union(enum) {
    none,
    spawn: Spawn,
    backoff: u32,
};

pub const Spawn = struct {
    op: Op,
    /// Remote path for .fetch (cat) and .push (write); "" otherwise.
    path: []const u8 = "",
    stdin: []const u8 = "",
    first_chunk: bool = false,
    executable: bool = false,
};

/// Fill slots from a loaded config, skipping invalid remotes (logged,
/// not fatal — one bad entry must not cost the rest). Returns how many
/// slots went active.
pub fn fillFromConfig(slots: *[max_remotes]Slot, cfg: *const remote_agents.Config) usize {
    var n: usize = 0;
    for (cfg.remotes) |*r| {
        if (!r.enabled) continue;
        if (n >= max_remotes) {
            std.debug.print("petdex: more than {d} remotes configured; ignoring the rest\n", .{max_remotes});
            break;
        }
        if (remote_agents.validateRemote(r)) |why| {
            std.debug.print("petdex: remote '{s}' skipped: {s}\n", .{ r.name, why });
            continue;
        }
        var slot = &slots[n];
        slot.* = .{};
        @memcpy(slot.name[0..r.name.len], r.name);
        slot.name_len = r.name.len;
        @memcpy(slot.host[0..r.host.len], r.host);
        slot.host_len = r.host.len;
        slot.port = r.port;
        if (r.identity_file) |identity| {
            if (identity.len <= slot.identity.len) {
                @memcpy(slot.identity[0..identity.len], identity);
                slot.identity_len = identity.len;
            }
        }
        var kinds: [3]AgentKind = undefined;
        slot.kind_count = remote_agents.enabledAgents(r, &kinds);
        @memcpy(slot.kinds[0..slot.kind_count], kinds[0..slot.kind_count]);
        slot.active = true;
        n += 1;
    }
    return n;
}

/// Rebuild the config-shaped Remote a slot carries, for the argv
/// builders. Identity slice points into the slot — valid for the call.
pub fn remoteFor(slot: *const Slot) remote_agents.Remote {
    return .{
        .name = slot.nameSlice(),
        .host = slot.host[0..slot.host_len],
        .port = slot.port,
        .identity_file = if (slot.identity_len > 0) slot.identity[0..slot.identity_len] else null,
    };
}

/// The fake home one remote's writeback stages into.
pub fn fakeHome(buf: []u8, home: []const u8, slot: *const Slot) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/.petdex/runtime/remote-wb/{s}", .{ home, slot.nameSlice() }) catch null;
}

/// Boot action for a slot: probe first.
pub fn startAction(slot: *Slot) Action {
    slot.op = .probe;
    return .{ .spawn = .{ .op = .probe } };
}

fn fetchAction(slot: *Slot) Action {
    const files = remote_writeback.filesOf(slot.kinds[slot.kind_idx]);
    slot.op = .fetch;
    return .{ .spawn = .{ .op = .fetch, .path = files[slot.file_idx] } };
}

fn tokenAction(slot: *Slot, slot_idx: usize, home: []const u8) Action {
    var path_buf: [512]u8 = undefined;
    const token_path = std.fmt.bufPrint(&path_buf, "{s}/.petdex/runtime/update-token", .{home}) catch return .none;
    const bytes = plat.readFile(token_path, &token_bufs[slot_idx]) orelse return .none;
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    token_lens[slot_idx] = trimmed.len;
    if (trimmed.len == 0) return .none;
    slot.op = .token;
    return .{ .spawn = .{ .op = .token, .path = remote_ssh.remote_token_file, .stdin = token_bufs[slot_idx][0..token_lens[slot_idx]] } };
}

fn tunnelAction(slot: *Slot) Action {
    slot.op = .tunnel;
    slot.backoff_ms = 0;
    return .{ .spawn = .{ .op = .tunnel } };
}

/// Advance after the current agent's last fetch staged: run the local
/// installer against the fake home and start pushing outputs. Falls
/// through to the next agent when the installer or collection fails
/// (marked, never silent).
fn beginPushOrNextKind(slot: *Slot, slot_idx: usize, home: []const u8) Action {
    var home_buf: [512]u8 = undefined;
    const fake = fakeHome(&home_buf, home, slot) orelse return nextKind(slot, slot_idx, home);
    if (!remote_writeback.runInstaller(wb_arena, slot.kinds[slot.kind_idx], fake)) {
        std.debug.print("petdex: remote '{s}': writeback install failed for {s}\n", .{ slot.nameSlice(), slot.kinds[slot.kind_idx].hookAgentName() });
        slot.wb_failed = true;
        return nextKind(slot, slot_idx, home);
    }
    outputs[slot_idx] = remote_writeback.collectOutputs(wb_arena, slot.kinds[slot.kind_idx], fake);
    if (outputs[slot_idx] == null) {
        slot.wb_failed = true;
        return nextKind(slot, slot_idx, home);
    }
    slot.output_idx = 0;
    slot.chunk_idx = 0;
    return pushAction(slot, slot_idx);
}

fn pushAction(slot: *Slot, slot_idx: usize) Action {
    const outs = outputs[slot_idx].?;
    const out = outs[slot.output_idx];
    const start = slot.chunk_idx * remote_ssh.stdin_chunk;
    const end = @min(start + remote_ssh.stdin_chunk, out.bytes.len);
    slot.op = .push;
    return .{ .spawn = .{
        .op = .push,
        .path = out.remote,
        .stdin = out.bytes[start..end],
        .first_chunk = slot.chunk_idx == 0,
        .executable = out.executable,
    } };
}

fn nextKind(slot: *Slot, slot_idx: usize, home: []const u8) Action {
    slot.kind_idx += 1;
    slot.file_idx = 0;
    slot.output_idx = 0;
    slot.chunk_idx = 0;
    if (slot.kind_idx < slot.kind_count) return fetchAction(slot);
    // No token on disk means no hook server: still bring the tunnel
    // up so it exists when the server appears.
    return tokenOrTunnel(slot, slot_idx, home);
}

fn tokenOrTunnel(slot: *Slot, slot_idx: usize, home: []const u8) Action {
    const act = tokenAction(slot, slot_idx, home);
    if (act != .none) return act;
    return tunnelAction(slot);
}

/// Drive one slot past a finished spawn. `output` is the collected
/// stdout (valid only during this call — staging copies it to disk
/// before returning).
pub fn onSpawnExit(slot: *Slot, slot_idx: usize, op: Op, code: i32, output: []const u8, home: []const u8) Action {
    switch (op) {
        .probe => {
            if (code != 0) {
                // Auth/network is broken; writeback would fail the same
                // way. Still bring the tunnel up: it retries with
                // backoff and the remote may simply be asleep.
                slot.probe_failed = true;
                std.debug.print("petdex: remote '{s}': probe failed (ssh exit {d}); tunnel will retry\n", .{ slot.nameSlice(), code });
                return tokenOrTunnel(slot, slot_idx, home);
            }
            slot.kind_idx = 0;
            slot.file_idx = 0;
            if (slot.kind_count == 0) return tokenOrTunnel(slot, slot_idx, home);
            return fetchAction(slot);
        },
        .fetch => {
            const files = remote_writeback.filesOf(slot.kinds[slot.kind_idx]);
            const rel = files[slot.file_idx];
            var home_buf: [512]u8 = undefined;
            const fake = fakeHome(&home_buf, home, slot) orelse return .none;
            if (code == 0 and output.len > 0) {
                _ = remote_writeback.stageFetched(fake, rel, output);
            } else {
                // No remote file: a fresh install. Remove any staged
                // copy from a previous run so it cannot merge stale.
                var stale_buf: [512]u8 = undefined;
                if (std.fmt.bufPrint(&stale_buf, "{s}/{s}", .{ fake, rel })) |stale| {
                    plat.deleteFile(stale);
                } else |_| {}
            }
            slot.file_idx += 1;
            if (slot.file_idx < files.len) return fetchAction(slot);
            return beginPushOrNextKind(slot, slot_idx, home);
        },
        .push => {
            if (code != 0) {
                std.debug.print("petdex: remote '{s}': push failed (ssh exit {d})\n", .{ slot.nameSlice(), code });
                slot.wb_failed = true;
                return nextKindAfterAbort(slot, slot_idx, home);
            }
            const outs = outputs[slot_idx].?;
            const out = outs[slot.output_idx];
            const chunks = remote_ssh.chunkCount(out.bytes.len);
            slot.chunk_idx += 1;
            if (slot.chunk_idx < chunks) return pushAction(slot, slot_idx);
            slot.output_idx += 1;
            slot.chunk_idx = 0;
            if (slot.output_idx < outs.len) return pushAction(slot, slot_idx);
            return nextKind(slot, slot_idx, home);
        },
        .token => return tunnelAction(slot),
        .tunnel => {
            // Any tunnel exit is a reconnect: ssh only exits when the
            // connection dropped (ExitOnForwardFailure makes a taken
            // port a fast exit too).
            slot.op = .none;
            if (slot.backoff_ms == 0) {
                slot.backoff_ms = 5000;
            } else {
                slot.backoff_ms = @min(slot.backoff_ms * 3, 60000);
            }
            return .{ .backoff = slot.backoff_ms };
        },
        .none => return .none,
    }
}

/// Skip the rest of the writeback after a push failure, straight to
/// token + tunnel.
fn nextKindAfterAbort(slot: *Slot, slot_idx: usize, home: []const u8) Action {
    slot.kind_idx = slot.kind_count;
    return tokenOrTunnel(slot, slot_idx, home);
}

/// Backoff timer fired: re-push the token, whose completion spawns the
/// tunnel. If the token push itself cannot read a token (hook server
/// gone), spawn the tunnel directly.
pub fn onBackoff(slot: *Slot, slot_idx: usize, home: []const u8) Action {
    return tokenOrTunnel(slot, slot_idx, home);
}

/// One-line status for the Settings row. Failures win over progress:
/// a tunnel that is up while the sync failed must not read as
/// "Connected".
pub fn statusCaption(slot: *const Slot) []const u8 {
    return switch (slot.op) {
        .probe => "Connecting…",
        .fetch, .push => "Syncing agent hooks…",
        .token => "Finishing setup…",
        .tunnel => if (slot.probe_failed or slot.wb_failed) "Tunnel up; sync failed" else "Connected",
        .none => if (slot.backoff_ms > 0) "Reconnecting…" else "Idle",
    };
}

// -------------------------------------------------------------- tests

const t = std.testing;

fn testSlot() Slot {
    var slot: Slot = .{};
    @memcpy(slot.name[0..5], "rogue");
    slot.name_len = 5;
    @memcpy(slot.host[0..8], "10.0.0.5");
    slot.host_len = 8;
    slot.kinds[0] = .opencode;
    slot.kinds[1] = .codex;
    slot.kind_count = 2;
    slot.active = true;
    return slot;
}

test "statusCaption puts failures ahead of progress" {
    var slot = testSlot();
    slot.op = .probe;
    try t.expectEqualStrings("Connecting…", statusCaption(&slot));
    slot.op = .fetch;
    try t.expectEqualStrings("Syncing agent hooks…", statusCaption(&slot));
    slot.op = .tunnel;
    try t.expectEqualStrings("Connected", statusCaption(&slot));
    slot.wb_failed = true;
    try t.expectEqualStrings("Tunnel up; sync failed", statusCaption(&slot));
    slot.op = .none;
    try t.expectEqualStrings("Idle", statusCaption(&slot));
    slot.backoff_ms = 5000;
    try t.expectEqualStrings("Reconnecting…", statusCaption(&slot));
}

test "key derivation round-trips and rejects foreign keys" {
    const key = keyFor(3, .push);
    const decoded = slotOpFromKey(key).?;
    try t.expectEqual(@as(usize, 3), decoded.slot);
    try t.expectEqual(Op.push, decoded.op);
    try t.expect(slotOpFromKey(42) == null);
    try t.expectEqual(@as(usize, 2), slotFromBackoffKey(backoffKey(2)).?);
    try t.expect(slotFromBackoffKey(keyFor(2, .tunnel)) == null);
}

test "fillFromConfig copies valid remotes and skips the rest" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var remotes = std.array_list.Managed(remote_agents.Remote).init(a);
    var good: remote_agents.Remote = .{ .name = "rogue", .host = "h", .port = 2222 };
    good.agents.codex.enabled = true;
    remotes.append(good) catch unreachable;
    var bad: remote_agents.Remote = .{ .name = "has space", .host = "h" };
    bad.agents.codex.enabled = true;
    remotes.append(bad) catch unreachable;
    var off: remote_agents.Remote = .{ .name = "off", .host = "h", .enabled = false };
    off.agents.codex.enabled = true;
    remotes.append(off) catch unreachable;
    const cfg: remote_agents.Config = .{ .remotes = remotes.items };

    var slots: [max_remotes]Slot = .{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    try t.expectEqual(@as(usize, 1), fillFromConfig(&slots, &cfg));
    try t.expectEqualStrings("rogue", slots[0].nameSlice());
    try t.expectEqual(@as(u16, 2222), slots[0].port);
    try t.expectEqual(@as(usize, 1), slots[0].kind_count);
    try t.expectEqual(AgentKind.codex, slots[0].kinds[0]);
}

test "driver walks probe -> fetch -> push -> token -> tunnel -> backoff" {
    const home = ".zig-cache/petdex-rt-home";
    plat.makeDir(home);
    plat.makeDir(home ++ "/.petdex/runtime");
    var tb: [512]u8 = undefined;
    const token_path = std.fmt.bufPrint(&tb, "{s}/.petdex/runtime/update-token", .{home}) catch unreachable;
    try t.expect(plat.writeFile(token_path, "tok-abc\n"));

    var slot = testSlot();
    const idx = 0;

    // Probe failure jumps to token, flags it, never spins a fetch.
    var probe_failed_slot = testSlot();
    var act = onSpawnExit(&probe_failed_slot, idx, .probe, 255, "", home);
    try t.expect(act == .spawn and act.spawn.op == .token);
    try t.expect(probe_failed_slot.probe_failed);

    // Happy path: probe -> fetch of opencode's single file.
    act = onSpawnExit(&slot, idx, .probe, 0, "", home);
    try t.expect(act == .spawn and act.spawn.op == .fetch);
    try t.expectEqualStrings(".config/opencode/plugins/petdex.js", act.spawn.path);

    // Fetch miss (exit 1) stages nothing; opencode's last file moves
    // straight into push (installer runs inside the driver).
    act = onSpawnExit(&slot, idx, .fetch, 1, "", home);
    try t.expect(act == .spawn and act.spawn.op == .push);
    try t.expect(act.spawn.first_chunk);

    // The plugin (8301 bytes) is three chunks; walk them, then the
    // codex fetch begins.
    act = onSpawnExit(&slot, idx, .push, 0, "", home);
    try t.expect(act == .spawn and act.spawn.op == .push and !act.spawn.first_chunk);
    act = onSpawnExit(&slot, idx, .push, 0, "", home);
    try t.expect(act == .spawn and act.spawn.op == .push and !act.spawn.first_chunk);
    act = onSpawnExit(&slot, idx, .push, 0, "", home);
    try t.expect(act == .spawn and act.spawn.op == .fetch);
    try t.expectEqualStrings(".codex/hooks.json", act.spawn.path);

    // Codex: two fetches, then pushes (hooks.json, config.toml, hook
    // script), then token, then tunnel.
    act = onSpawnExit(&slot, idx, .fetch, 1, "", home);
    try t.expect(act == .spawn and act.spawn.op == .fetch);
    try t.expectEqualStrings(".codex/config.toml", act.spawn.path);
    act = onSpawnExit(&slot, idx, .fetch, 1, "", home);
    try t.expect(act == .spawn and act.spawn.op == .push);

    var guard: usize = 0;
    while (act == .spawn and act.spawn.op == .push and guard < 32) {
        act = onSpawnExit(&slot, idx, .push, 0, "", home);
        guard += 1;
    }
    try t.expect(act == .spawn and act.spawn.op == .token);
    try t.expectEqualStrings("tok-abc", act.spawn.stdin);

    act = onSpawnExit(&slot, idx, .token, 0, "", home);
    try t.expect(act == .spawn and act.spawn.op == .tunnel);

    // Tunnel death: 5s backoff, tripling, capped at 60s.
    act = onSpawnExit(&slot, idx, .tunnel, 255, "", home);
    try t.expect(act == .backoff and act.backoff == 5000);
    act = onBackoff(&slot, idx, home);
    try t.expect(act == .spawn and act.spawn.op == .token);
    slot.op = .none;
    act = onSpawnExit(&slot, idx, .tunnel, 255, "", home);
    try t.expect(act == .backoff and act.backoff == 15000);
    slot.op = .none;
    slot.backoff_ms = 30000;
    act = onSpawnExit(&slot, idx, .tunnel, 255, "", home);
    try t.expect(act == .backoff and act.backoff == 60000);
}

test "push failure aborts writeback but still reaches the tunnel" {
    const home = ".zig-cache/petdex-rt-home";
    var slot = testSlot();
    const idx = 1;
    _ = onSpawnExit(&slot, idx, .probe, 0, "", home);
    const act = onSpawnExit(&slot, idx, .fetch, 1, "", home);
    try t.expect(act == .spawn and act.spawn.op == .push);
    const after = onSpawnExit(&slot, idx, .push, 255, "", home);
    try t.expect(after == .spawn and after.spawn.op == .token);
    try t.expect(slot.wb_failed);
}
