//! fd_passing — Send/receive file descriptors between processes via Unix socket.
//!
//! Uses SCM_RIGHTS ancillary messages to pass file descriptors over a Unix
//! domain socket. This is the standard Linux mechanism for sharing memfd-backed
//! shared memory (SharedRing) between processes.
//!
//! Usage:
//!   // Process A (server):
//!   var server = try FdServer.listen("/tmp/ringmpsc.sock");
//!   defer server.deinit();
//!   const conn = try server.accept();
//!   defer posix.close(conn);
//!   try sendFd(conn, ring.getFd());
//!
//!   // Process B (client):
//!   const conn = try connectUnix("/tmp/ringmpsc.sock");
//!   defer posix.close(conn);
//!   const fd = try recvFd(conn);
//!   var ring = try SharedRing(u64).attach(fd);

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// SCM_RIGHTS ancillary message type — passes file descriptors between
/// processes over Unix domain sockets. Value 0x01 is defined in
/// linux/socket.h and is stable across all Linux versions.
const SCM_RIGHTS: i32 = 0x01;

/// Send a file descriptor over a Unix domain socket using SCM_RIGHTS.
pub fn sendFd(socket: posix.fd_t, fd_to_send: posix.fd_t) !void {
    // Payload: single byte (SCM_RIGHTS requires at least 1 byte of data)
    var data_buf = [_]u8{1};
    const data_iov = [_]posix.iovec_const{.{
        .base = &data_buf,
        .len = 1,
    }};

    // Ancillary message: one file descriptor
    const cmsg_size = @sizeOf(CmsgFd);
    var cmsg_buf: [cmsg_size]u8 align(@alignOf(linux.msghdr_const)) = undefined;

    const cmsg: *cmsghdr = @ptrCast(@alignCast(&cmsg_buf));
    cmsg.level = posix.SOL.SOCKET;
    cmsg.type = SCM_RIGHTS;
    cmsg.len = @sizeOf(cmsghdr) + @sizeOf(posix.fd_t);

    // Copy fd into cmsg data area
    const fd_ptr: *posix.fd_t = @ptrCast(@alignCast(@as([*]u8, @ptrCast(cmsg)) + @sizeOf(cmsghdr)));
    fd_ptr.* = fd_to_send;

    const msg = linux.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &data_iov,
        .iovlen = 1,
        .control = &cmsg_buf,
        .controllen = cmsg_size,
        .flags = 0,
    };

    const rc = linux.sendmsg(socket, &msg, 0);
    if (posix.errno(rc) != .SUCCESS) return error.SendFdFailed;
}

/// Receive a file descriptor from a Unix domain socket (SCM_RIGHTS).
pub fn recvFd(socket: posix.fd_t) !posix.fd_t {
    var data_buf = [_]u8{0};
    var data_iov = [_]posix.iovec{.{
        .base = &data_buf,
        .len = 1,
    }};

    const cmsg_size = @sizeOf(CmsgFd);
    var cmsg_buf: [cmsg_size]u8 align(@alignOf(linux.msghdr)) = undefined;

    var msg = linux.msghdr{
        .name = null,
        .namelen = 0,
        .iov = &data_iov,
        .iovlen = 1,
        .control = &cmsg_buf,
        .controllen = cmsg_size,
        .flags = 0,
    };

    const rc = linux.recvmsg(socket, &msg, 0);
    if (posix.errno(rc) != .SUCCESS) return error.RecvFdFailed;
    if (rc == 0) return error.ConnectionClosed;

    // Extract fd from ancillary data
    const cmsg: *cmsghdr = @ptrCast(@alignCast(&cmsg_buf));
    if (cmsg.level != posix.SOL.SOCKET or cmsg.type != SCM_RIGHTS) {
        return error.NoCmsgRights;
    }
    if (cmsg.len != @sizeOf(cmsghdr) + @sizeOf(posix.fd_t)) {
        return error.InvalidCmsgLength;
    }

    const fd_ptr: *const posix.fd_t = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(cmsg)) + @sizeOf(cmsghdr)));
    return fd_ptr.*;
}

/// Connect to a Unix domain socket (client side).
pub fn connectUnix(path: []const u8) !posix.fd_t {
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    errdefer posix.close(fd);

    var addr = std.net.Address.initUnix(path) catch return error.PathTooLong;
    posix.connect(fd, &addr.any, addr.getOsSockLen()) catch return error.ConnectFailed;

    return fd;
}

/// Simple Unix domain socket server for fd passing.
pub const FdServer = struct {
    fd: posix.fd_t,
    path: [108]u8,
    path_len: usize,

    pub fn listen(path: []const u8) !FdServer {
        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer posix.close(fd);

        // Remove stale socket
        std.fs.deleteFileAbsolute(path) catch {};

        var addr = std.net.Address.initUnix(path) catch return error.PathTooLong;
        posix.bind(fd, &addr.any, addr.getOsSockLen()) catch return error.BindFailed;
        posix.listen(fd, 1) catch return error.ListenFailed;

        var server = FdServer{
            .fd = fd,
            .path = undefined,
            .path_len = path.len,
        };
        @memcpy(server.path[0..path.len], path);
        return server;
    }

    pub fn accept(self: *const FdServer) !posix.fd_t {
        return posix.accept(self.fd, null, null, 0) catch return error.AcceptFailed;
    }

    pub fn deinit(self: *FdServer) void {
        posix.close(self.fd);
        std.fs.deleteFileAbsolute(self.path[0..self.path_len]) catch {};
    }
};

// cmsghdr is not in Zig's linux bindings — define it here
const cmsghdr = extern struct {
    len: usize,     // cmsg_len: total bytes including header
    level: i32,     // originating protocol (SOL_SOCKET)
    type: i32,      // protocol-specific type (SCM_RIGHTS = 1)
};

// cmsghdr + one fd, for SCM_RIGHTS ancillary message
const CmsgFd = extern struct {
    hdr: cmsghdr,
    fd: posix.fd_t,
};
