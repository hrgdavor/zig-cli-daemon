const std = @import("std");
const builtin = @import("builtin");

// Default configuration if not overridden by arguments
const DEFAULT_SOCKET_PATH = switch (builtin.os.tag) {
    .windows => "daemon.sock",
    else => "/tmp/java-daemon.sock",
};
const DEFAULT_DAEMON_CMD = "java -jar daemon.jar";

const BUFFER_SIZE = 4096;

const MessageType = enum(u7) {
    exit_code = 0,
    stdout = 1,
    stderr = 2,
    arg = 3,
    env_var = 4,
    stream_init = 5,
    stream_data = 6,
    jsonrpc = 7,
    get_pid = 8,
};

const ProtocolMode = enum(u8) {
    advanced = 0x00,
    simple = 0x01,
};

fn sendFrame(writer: anytype, msg_type: MessageType, more: bool, payload: []const u8) !void {
    const header_byte = (@as(u8, @intFromEnum(msg_type)) << 1) | @as(u8, if (more) 1 else 0);
    try writer.writeByte(header_byte);

    const len = @as(u32, @intCast(payload.len));
    if (len > 0xFFFFFF) return error.PayloadTooLarge;
    try writer.writeByte(@intCast((len >> 16) & 0xFF));
    try writer.writeByte(@intCast((len >> 8) & 0xFF));
    try writer.writeByte(@intCast(len & 0xFF));

    try writer.writeAll(payload);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 1. Argument Parsing
    const args = try init.minimal.args.toSlice(allocator);
    var socket_path: ?[]const u8 = null;
    var daemon_cmd: ?[]const u8 = null;
    var daemon_timeout_ms: u32 = 3000;
    var is_restart = false;
    var mode: ProtocolMode = .advanced;
    var client_args: std.ArrayList([]const u8) = .empty;
    defer client_args.deinit(allocator);
    var body: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--daemon-socket")) {
            i += 1;
            if (i < args.len) socket_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--daemon-cmd")) {
            i += 1;
            if (i < args.len) daemon_cmd = args[i];
        } else if (std.mem.eql(u8, args[i], "--daemon-timeout")) {
            i += 1;
            if (i < args.len) {
                daemon_timeout_ms = std.fmt.parseInt(u32, args[i], 10) catch 3000;
            }
        } else if (std.mem.eql(u8, args[i], "--restart")) {
            is_restart = true;
        } else if (std.mem.eql(u8, args[i], "--body")) {
            i += 1;
            if (i < args.len) body = args[i];
        } else if (std.mem.eql(u8, args[i], "--mode")) {
            i += 1;
            if (i < args.len) {
                if (std.mem.eql(u8, args[i], "simple")) {
                    mode = .simple;
                } else {
                    mode = .advanced;
                }
            }
        } else if (std.mem.eql(u8, args[i], "--")) {
            i += 1;
            while (i < args.len) : (i += 1) {
                try client_args.append(allocator, args[i]);
            }
            break;
        } else {
            try client_args.append(allocator, args[i]);
        }
        i += 1;
    }

    const final_socket_path = socket_path orelse DEFAULT_SOCKET_PATH;
    const final_daemon_cmd = daemon_cmd orelse DEFAULT_DAEMON_CMD;

    // 2. Connect to Daemon (with optimistic liveness & auto-restart fallback)
    const stream = connectToDaemonOrSpawn(io, allocator, final_socket_path, final_daemon_cmd, daemon_timeout_ms) catch |err| {
        std.debug.print("Fatal: Could not connect to or start daemon. Error: {s}\n", .{@errorName(err)});
        return err;
    };
    defer stream.close(io);

    // 2.5 Proceed directly to mode-specific logic

    if (is_restart) {
        var writer = stream.writer(io, &[_]u8{});
        try sendFrame(&writer.interface, .exit_code, false, &.{ 0, 0, 0, 0 });
        try writer.interface.flush();
        std.debug.print("Restart signal sent to daemon.\n", .{});
        return;
    }

    if (mode == .simple) {
        // 3. Simple Mode: Assemble Metadata Block
        var meta: std.ArrayList(u8) = .empty;
        try meta.appendSlice(allocator, args[0]);
        try meta.append(allocator, 0);
        const current_pwd = try std.process.currentPathAlloc(io, allocator);
        try meta.appendSlice(allocator, current_pwd);
        try meta.append(allocator, 0);
        for (client_args.items) |arg| {
            try meta.appendSlice(allocator, arg);
            try meta.append(allocator, 0);
        }
        var env_iter = init.environ_map.iterator();
        while (env_iter.next()) |entry| {
            try meta.appendSlice(allocator, entry.key_ptr.*);
            try meta.append(allocator, '=');
            try meta.appendSlice(allocator, entry.value_ptr.*);
            try meta.append(allocator, 0);
        }
        try meta.append(allocator, 0); // Terminal null

        // Send Length + Metadata
        var meta_writer = stream.writer(io, &[_]u8{});
        try meta_writer.interface.writeInt(u32, @intCast(meta.items.len), .big);
        try meta_writer.interface.writeAll(meta.items);
        try meta_writer.interface.flush();

        // Start Raw Piping
        const pipe_stdout = struct {
            fn run_pipe(sock: std.Io.net.Stream, thread_io: std.Io) !void {
                const stdout_file = std.Io.File.stdout();
                var read_buf: [BUFFER_SIZE]u8 = undefined;
                var stream_reader = sock.reader(thread_io, &read_buf);
                const reader = &stream_reader.interface;
                var chunk: [BUFFER_SIZE]u8 = undefined;
                while (true) {
                    const n = reader.readSliceShort(&chunk) catch |err| {
                        if (err == error.EndOfStream) break;
                        return err;
                    };
                    if (n == 0) break;
                    try stdout_file.writeStreamingAll(thread_io, chunk[0..n]);
                }
            }
        };
        const thread = try std.Thread.spawn(.{}, pipe_stdout.run_pipe, .{ stream, io });

        if (body) |b| {
            var sock_writer_simple = stream.writer(io, &[_]u8{});
            try sock_writer_simple.interface.writeAll(b);
            try sock_writer_simple.interface.flush();
            try stream.shutdown(io, .send);
            thread.join();
        } else {
            thread.detach();
            var stdin_buf: [BUFFER_SIZE]u8 = undefined;
            var stdin_file_reader = std.Io.File.stdin().reader(io, &stdin_buf);
            const stdin_reader = &stdin_file_reader.interface;
            var write_buf: [BUFFER_SIZE]u8 = undefined;
            var sock_writer_simple = stream.writer(io, &write_buf);
            var input_buf: [BUFFER_SIZE]u8 = undefined;
            while (true) {
                const amt = stdin_reader.readSliceShort(&input_buf) catch |err| {
                    if (err == error.EndOfStream) break;
                    return err;
                };
                if (amt == 0) break;
                try sock_writer_simple.interface.writeAll(input_buf[0..amt]);
                try sock_writer_simple.interface.flush();
            }
        }
        return;
    }

    // 3. Socket construct & send header (Advanced Mode)
    var sock_buf: [BUFFER_SIZE]u8 = undefined;
    var sock_buffered_writer = stream.writer(io, &sock_buf);
    const sock_writer = &sock_buffered_writer.interface;

    const pwd = try std.process.currentPathAlloc(io, allocator);

    // Sequence 0: Executable name
    try sendFrame(sock_writer, .arg, true, args[0]);
    // Sequence 1: PWD
    try sendFrame(sock_writer, .arg, true, pwd);

    // Forward Environment Variables
    var env_iter = init.environ_map.iterator();
    while (env_iter.next()) |entry| {
        // Construct KEY=VALUE
        const entry_str = try std.fmt.allocPrint(allocator, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
        defer allocator.free(entry_str);
        try sendFrame(sock_writer, .env_var, true, entry_str);
    }

    // Forward Args (Starting from Sequence 2)
    for (client_args.items, 0..) |arg, idx| {
        const is_last = idx == client_args.items.len - 1;
        try sendFrame(sock_writer, .arg, !is_last, arg);
    }

    try sock_writer.flush();

    // 4. Bi-directional pipe
    const socket_to_stdout = struct {
        fn run(sock: std.Io.net.Stream, thread_io: std.Io) !void {
            const stdout_file = std.Io.File.stdout();
            const stderr_file = std.Io.File.stderr();

            var read_buf: [BUFFER_SIZE]u8 = undefined;
            var stream_reader = sock.reader(thread_io, &read_buf);
            const reader = &stream_reader.interface;

            var header: [4]u8 = undefined;
            while (true) {
                reader.readSliceAll(&header) catch |err| {
                    if (err == error.EndOfStream) break;
                    return err;
                };

                const first = header[0];
                const msg_type: MessageType = @enumFromInt(@as(u7, @intCast(first >> 1)));
                const len = (@as(u32, header[1]) << 16) | (@as(u32, header[2]) << 8) | @as(u32, header[3]);

                if (msg_type == .exit_code) {
                    if (len != 4) return error.InvalidExitCodeLength;
                    var exit_buf: [4]u8 = undefined;
                    try reader.readSliceAll(&exit_buf);
                    const code = std.mem.readInt(i32, &exit_buf, .big);
                    std.process.exit(@intCast(code));
                }

                if (msg_type == .stdout or msg_type == .stderr) {
                    const file = if (msg_type == .stdout) stdout_file else stderr_file;
                    var remaining = len;
                    var chunk: [BUFFER_SIZE]u8 = undefined;
                    while (remaining > 0) {
                        const to_read = @min(remaining, chunk.len);
                        const read = try reader.readSliceShort(chunk[0..to_read]);
                        if (read == 0) return error.EndOfStream;
                        try file.writeStreamingAll(thread_io, chunk[0..read]);
                        remaining -= @intCast(read);
                    }
                } else {
                    try reader.discardAll(len);
                }
            }
        }
    };

    const thread = try std.Thread.spawn(.{}, socket_to_stdout.run, .{ stream, io });

    if (body) |b| {
        try sendFrame(sock_writer, .stdout, false, b);
        try sock_writer.flush();
        try stream.shutdown(io, .send);
        thread.join();
    } else {
        thread.detach();
        // 5. Main thread: stdin to socket
        var stdin_buf: [BUFFER_SIZE]u8 = undefined;
        var stdin_file_reader = std.Io.File.stdin().reader(io, &stdin_buf);
        const stdin_reader = &stdin_file_reader.interface;

        var input_buf: [BUFFER_SIZE]u8 = undefined;
        while (true) {
            const amt = stdin_reader.readSliceShort(&input_buf) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };
            if (amt == 0) break;
            // Advanced Mode: Send stdin directly using Message Type 1 (symmetric with stdout)
            try sendFrame(sock_writer, .stdout, false, input_buf[0..amt]);
            try sock_writer.flush();
        }
    }
}

/// Attempts to connect to the unix socket.
/// If it fails with ConnectionRefused or FileNotFound, it spawns the daemon
/// command and active-polls until the daemon is bound to the socket.
fn connectToDaemonOrSpawn(
    io: std.Io,
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    daemon_cmd_str: []const u8,
    timeout_ms: u32,
) !std.Io.net.Stream {
    const ua = try std.Io.net.UnixAddress.init(socket_path);

    // Initial Optimistic Connect
    if (ua.connect(io)) |stream| {
        return stream;
    } else |err| {
        switch (err) {
            error.FileNotFound, error.Unexpected => {
                // Daemon is either not running or in a bad state (stale socket).
                // Note: error.Unexpected is a proxy for ConnectionRefused in some Zig 0.16.0 targets.
                if (err == error.Unexpected) {
                    std.debug.print("Stale socket detected. Forcing daemon restart...\n", .{});
                    std.Io.Dir.cwd().deleteFile(io, socket_path) catch {};
                }

                try spawnDaemon(io, allocator, daemon_cmd_str);

                // Retry connecting with a 10ms delay between attempts
                const max_retries = timeout_ms / 10;
                var retries: usize = 0;
                while (retries < max_retries) : (retries += 1) {
                    const wait_timeout = std.Io.Timeout{ .duration = .{
                        .raw = std.Io.Duration.fromMilliseconds(10),
                        .clock = .awake,
                    } };
                    _ = wait_timeout.sleep(io) catch {};
                    if (ua.connect(io)) |stream| {
                        return stream;
                    } else |retry_err| {
                        switch (retry_err) {
                            error.FileNotFound, error.Unexpected => continue,
                            else => return retry_err,
                        }
                    }
                }
                return error.DaemonStartupTimeout;
            },
            else => return err,
        }
    }
}

/// Tokenizes the daemon command string and spawns the process detached
fn spawnDaemon(io: std.Io, allocator: std.mem.Allocator, daemon_cmd_str: []const u8) !void {
    var cmd_args: std.ArrayList([]const u8) = .empty;
    defer {
        for (cmd_args.items) |arg| allocator.free(arg);
        cmd_args.deinit(allocator);
    }

    // Split by space but respect quotes
    var i: usize = 0;
    while (i < daemon_cmd_str.len) {
        while (i < daemon_cmd_str.len and daemon_cmd_str[i] == ' ') i += 1;
        if (i == daemon_cmd_str.len) break;

        var start = i;
        if (daemon_cmd_str[i] == '"') {
            i += 1;
            start = i;
            while (i < daemon_cmd_str.len and daemon_cmd_str[i] != '"') i += 1;
            try cmd_args.append(allocator, try allocator.dupe(u8, daemon_cmd_str[start..i]));
            if (i < daemon_cmd_str.len) i += 1;
        } else {
            while (i < daemon_cmd_str.len and daemon_cmd_str[i] != ' ') i += 1;
            try cmd_args.append(allocator, try allocator.dupe(u8, daemon_cmd_str[start..i]));
        }
    }

    if (cmd_args.items.len == 0) return error.EmptyDaemonCommand;
    
    // Spawn the daemon. In Zig 0.16.0 we use std.process.spawn.
    // We will spawn a detached thread to wait on it and avoid zombie processes on UNIX.
    const run_daemon_thread = struct {
        fn run(thread_io: std.Io, thread_allocator: std.mem.Allocator, args: [][]const u8) void {
            var child = std.process.spawn(thread_io, .{
                .argv = args,
                .stderr = .inherit, // Pipe stderr to bridge's stderr for debugging
            }) catch |err| {
                std.debug.print("Warning: Failed to execute daemon spawn command: {s}\n", .{@errorName(err)});
                return;
            };
            _ = child.wait(thread_io) catch {}; // Reaps the child process natively
            for (args) |arg| thread_allocator.free(arg);
            thread_allocator.free(args);
        }
    };

    // Duplicate string slices to maintain safety across threads
    var dup_args = try allocator.alloc([]const u8, cmd_args.items.len);
    for (cmd_args.items, 0..) |arg, idx| {
        dup_args[idx] = try allocator.dupe(u8, arg);
    }

    const thread = try std.Thread.spawn(.{}, run_daemon_thread.run, .{ io, allocator, dup_args });
    thread.detach();
}
