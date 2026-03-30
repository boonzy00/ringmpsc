//! NUMA topology detection, per-node allocation, and CPU affinity.
//!
//! Reads the Linux sysfs interface (`/sys/devices/system/node/`) to discover
//! NUMA nodes, per-node CPU lists, memory sizes, and inter-node distances.
//! Falls back to a single uniform node on non-NUMA or non-Linux systems.

const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// TOPOLOGY
// ============================================================================

pub const NumaNode = struct {
    id: usize,
    cpus: []usize,
    memory_bytes: u64,
    distances: []u32,
};

pub const NumaTopology = struct {
    node_count: usize,
    cpu_count: usize,
    nodes: []NumaNode,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !NumaTopology {
        var self = NumaTopology{
            .node_count = 1,
            .cpu_count = std.Thread.getCpuCount() catch 1,
            .nodes = &.{},
            .allocator = allocator,
        };

        if (comptime builtin.os.tag == .linux) {
            if (detectNuma()) {
                self.loadFromSysfs() catch {
                    try self.initUniform();
                };
            } else {
                try self.initUniform();
            }
        } else {
            try self.initUniform();
        }
        return self;
    }

    pub fn deinit(self: *NumaTopology) void {
        for (self.nodes) |*node| {
            if (node.cpus.len > 0) self.allocator.free(node.cpus);
            if (node.distances.len > 0) self.allocator.free(node.distances);
        }
        if (self.nodes.len > 0) self.allocator.free(self.nodes);
    }

    /// Which NUMA node owns the given CPU?
    pub fn nodeOfCpu(self: *const NumaTopology, cpu: usize) usize {
        for (self.nodes) |node| {
            for (node.cpus) |c| {
                if (c == cpu) return node.id;
            }
        }
        return 0;
    }

    /// Nearest neighbor node (lowest distance, excluding self).
    pub fn nearestNode(self: *const NumaTopology, from: usize) usize {
        if (from >= self.nodes.len) return 0;
        var best: usize = from;
        var best_dist: u32 = std.math.maxInt(u32);
        for (self.nodes) |node| {
            if (node.id == from) continue;
            if (from < self.nodes[from].distances.len) {
                const d = self.nodes[from].distances[node.id];
                if (d < best_dist) {
                    best_dist = d;
                    best = node.id;
                }
            }
        }
        return best;
    }

    /// Check if system is actually multi-node.
    pub fn isNuma(self: *const NumaTopology) bool {
        return self.node_count > 1;
    }

    // -- private helpers -----------------------------------------------------

    fn detectNuma() bool {
        var dir = std.fs.openDirAbsolute("/sys/devices/system/node", .{}) catch return false;
        dir.close();
        return true;
    }

    fn loadFromSysfs(self: *NumaTopology) !void {
        var dir = try std.fs.openDirAbsolute("/sys/devices/system/node", .{ .iterate = true });
        defer dir.close();

        var count: usize = 0;
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (std.mem.startsWith(u8, entry.name, "node")) {
                // Verify it's nodeN (numeric suffix)
                const suffix = entry.name[4..];
                _ = std.fmt.parseInt(usize, suffix, 10) catch continue;
                count += 1;
            }
        }

        self.node_count = count;
        self.nodes = try self.allocator.alloc(NumaNode, count);

        for (self.nodes, 0..) |*node, i| {
            node.* = try self.loadNode(i);
        }
    }

    fn loadNode(self: *NumaTopology, id: usize) !NumaNode {
        var node = NumaNode{
            .id = id,
            .cpus = &.{},
            .memory_bytes = 0,
            .distances = &.{},
        };

        // --- cpus ---
        const cpu_path = try std.fmt.allocPrint(self.allocator, "/sys/devices/system/node/node{d}/cpulist", .{id});
        defer self.allocator.free(cpu_path);

        if (readSysfs(self.allocator, cpu_path)) |raw| {
            defer self.allocator.free(raw);
            node.cpus = parseCpuList(self.allocator, std.mem.trimRight(u8, raw, "\n")) catch &.{};
        } else |_| {
            node.cpus = try self.fallbackCpus(id);
        }

        // --- memory ---
        const mem_path = try std.fmt.allocPrint(self.allocator, "/sys/devices/system/node/node{d}/meminfo", .{id});
        defer self.allocator.free(mem_path);

        if (readSysfs(self.allocator, mem_path)) |raw| {
            defer self.allocator.free(raw);
            node.memory_bytes = parseMemTotal(raw);
        } else |_| {}

        // --- distances ---
        node.distances = try self.loadDistances(id);

        return node;
    }

    fn fallbackCpus(self: *NumaTopology, node_id: usize) ![]usize {
        const per_node = self.cpu_count / self.node_count;
        const start = node_id * per_node;
        const end = @min(start + per_node, self.cpu_count);
        const cpus = try self.allocator.alloc(usize, end - start);
        for (cpus, 0..) |*c, i| c.* = start + i;
        return cpus;
    }

    fn loadDistances(self: *NumaTopology, id: usize) ![]u32 {
        const path = try std.fmt.allocPrint(self.allocator, "/sys/devices/system/node/node{d}/distance", .{id});
        defer self.allocator.free(path);

        var dists = try self.allocator.alloc(u32, self.node_count);

        if (readSysfs(self.allocator, path)) |raw| {
            defer self.allocator.free(raw);
            var it = std.mem.tokenizeAny(u8, std.mem.trimRight(u8, raw, "\n"), " \t");
            var i: usize = 0;
            while (it.next()) |tok| {
                if (i >= dists.len) break;
                dists[i] = std.fmt.parseInt(u32, tok, 10) catch 0;
                i += 1;
            }
        } else |_| {
            for (dists, 0..) |*d, i| d.* = if (i == id) 10 else 20;
        }
        return dists;
    }

    fn initUniform(self: *NumaTopology) !void {
        self.node_count = 1;
        self.nodes = try self.allocator.alloc(NumaNode, 1);

        const cpus = try self.allocator.alloc(usize, self.cpu_count);
        for (cpus, 0..) |*c, i| c.* = i;

        const dists = try self.allocator.alloc(u32, 1);
        dists[0] = 10;

        self.nodes[0] = .{
            .id = 0,
            .cpus = cpus,
            .memory_bytes = 0,
            .distances = dists,
        };
    }
};

// ============================================================================
// NUMA ALLOCATOR (per-node arenas)
// ============================================================================

pub const NumaAllocator = struct {
    backing: std.mem.Allocator,
    topology: *const NumaTopology,
    arenas: []std.heap.ArenaAllocator,

    pub fn init(backing: std.mem.Allocator, topology: *const NumaTopology) !NumaAllocator {
        const arenas = try backing.alloc(std.heap.ArenaAllocator, topology.node_count);
        for (arenas) |*a| a.* = std.heap.ArenaAllocator.init(backing);
        return .{
            .backing = backing,
            .topology = topology,
            .arenas = arenas,
        };
    }

    pub fn deinit(self: *NumaAllocator) void {
        for (self.arenas) |*a| a.deinit();
        self.backing.free(self.arenas);
    }

    /// Allocate on a specific NUMA node's arena.
    pub fn allocOnNode(self: *NumaAllocator, comptime T: type, node_id: usize) !*T {
        const actual_node = if (node_id >= self.arenas.len) 0 else node_id;
        const ptr = try self.arenas[actual_node].allocator().create(T);
        ptr.* = .{};

        // mbind to requested node for physical placement
        if (comptime builtin.os.tag == .linux) {
            bindMemoryToNode(@as([*]u8, @ptrCast(ptr)), @sizeOf(T), actual_node);
        }

        return ptr;
    }

    /// Allocate on the NUMA node that owns the given CPU.
    pub fn allocForCpu(self: *NumaAllocator, comptime T: type, cpu: usize) !*T {
        const node = self.topology.nodeOfCpu(cpu);
        return self.allocOnNode(T, node);
    }
};

// ============================================================================
// CPU AFFINITY (Linux)
// ============================================================================

/// Pin the calling thread to a specific CPU.
pub fn bindToCpu(cpu: usize) !void {
    if (comptime builtin.os.tag != .linux) return;

    var set = std.mem.zeroes(std.os.linux.cpu_set_t);
    const word = cpu / @bitSizeOf(usize);
    const bit: std.math.Log2Int(usize) = @intCast(cpu % @bitSizeOf(usize));
    if (word < set.len) {
        set[word] = @as(usize, 1) << bit;
    }
    std.os.linux.sched_setaffinity(0, &set) catch return error.CpuBindFailed;
}

/// Pin the calling thread to the first CPU of a NUMA node.
pub fn bindToNode(node_id: usize, topology: *const NumaTopology) !void {
    if (node_id >= topology.nodes.len) return error.InvalidNode;
    if (topology.nodes[node_id].cpus.len > 0) {
        try bindToCpu(topology.nodes[node_id].cpus[0]);
    }
}

/// Detect which CPU the calling thread is running on.
pub fn currentCpu() ?usize {
    if (comptime builtin.os.tag != .linux) return null;

    var set: std.os.linux.cpu_set_t = undefined;
    @memset(&set, 0);
    const rc = std.os.linux.sched_getaffinity(0, @sizeOf(std.os.linux.cpu_set_t), &set);
    if (rc != 0) return null;

    const bits_per_word = @bitSizeOf(usize);
    for (set, 0..) |word, wi| {
        if (word != 0) {
            return wi * bits_per_word + @ctz(word);
        }
    }
    return null;
}

/// Detect the NUMA node of the calling thread.
pub fn currentNode(topology: *const NumaTopology) usize {
    if (currentCpu()) |cpu| {
        return topology.nodeOfCpu(cpu);
    }
    return 0;
}

// ============================================================================
// MEMORY BINDING (Linux mbind)
// ============================================================================

const MPOL_BIND: c_uint = 2;
const MPOL_F_STATIC_NODES: c_uint = 1 << 15;

pub fn bindMemoryToNode(addr: [*]u8, len: usize, node: usize) void {
    if (comptime builtin.os.tag != .linux) return;

    var nodemask: [16]c_ulong = [_]c_ulong{0} ** 16;
    const word_index = node / 64;
    const bit_index = node % 64;
    if (word_index < nodemask.len) {
        nodemask[word_index] = @as(c_ulong, 1) << @intCast(bit_index);
    }

    const maxnode: c_ulong = @as(c_ulong, @intCast(node)) + 2;
    const rc = std.os.linux.syscall6(
        .mbind,
        @intFromPtr(addr),
        len,
        MPOL_BIND,
        @intFromPtr(&nodemask),
        maxnode,
        MPOL_F_STATIC_NODES,
    );

    // Non-fatal — silently continue without binding.
    // mbind fails on single-node systems and non-NUMA kernels.
    _ = rc;
}

// ============================================================================
// HELPERS
// ============================================================================

fn readSysfs(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, 4096);
}

fn parseCpuList(allocator: std.mem.Allocator, raw: []const u8) ![]usize {
    var list = std.ArrayListUnmanaged(usize){};
    errdefer list.deinit(allocator);

    var it = std.mem.tokenizeScalar(u8, raw, ',');
    while (it.next()) |range| {
        const trimmed = std.mem.trim(u8, range, " \t\n");
        if (std.mem.indexOfScalar(u8, trimmed, '-')) |dash| {
            const lo = try std.fmt.parseInt(usize, trimmed[0..dash], 10);
            const hi = try std.fmt.parseInt(usize, trimmed[dash + 1 ..], 10);
            for (lo..hi + 1) |c| try list.append(allocator, c);
        } else {
            try list.append(allocator, try std.fmt.parseInt(usize, trimmed, 10));
        }
    }
    return list.toOwnedSlice(allocator);
}

fn parseMemTotal(raw: []const u8) u64 {
    var lines = std.mem.tokenizeScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "MemTotal") == null) continue;
        var parts = std.mem.tokenizeAny(u8, line, " \t");
        while (parts.next()) |tok| {
            if (std.fmt.parseInt(u64, tok, 10)) |kb| return kb * 1024 else |_| continue;
        }
    }
    return 0;
}
