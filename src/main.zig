const std = @import("std");
const builtin = @import("builtin");

// Default configuration if not overridden by arguments
const DEFAULT_SOCKET_PATH = switch (builtin.os.tag) {
    .windows => "daemon.sock",
    else => "/tmp/java-daemon.sock",
};
const DEFAULT_DAEMON_CMD = "java -jar daemon.jar";
const VERSION = "0.1.0";

const BUFFER_SIZE = 4096;

fn printUsage() void {
    const usage =
        \\CLI Daemon Bridge v{s}
        \\
        \\Usage: zig_cli_daemon [options] [--] [command args...]
        \\
        \\Options:
        \\  -h, --help                Show this help message
        \\  -V, --version             Show version information
        \\  --daemon-socket <path>    Socket path (default: {s})
        \\  --daemon-cmd <cmd>       Command to spawn daemon (default: "{s}")
        \\  --daemon-timeout <ms>    Wait timeout for daemon startup (default: 3000ms)
        \\  --restart                 Send restart signal and exit
        \\  --body <body>             Send text/json payload instead of stdin
        \\  --mode <simple|advanced>  Protocol mode (default: advanced)
        \\  --env-allow <pattern>    Regex-ish pattern for environment forwarding
        \\  --env-deny <pattern>     Regex-ish pattern for environment exclusion
        \\  --env-test                Print filtered environment and exit
        \\  --status                  Check if daemon is running and exit
        \\  --verbose                 Print diagnostic information to stderr
        \\  --quiet                   Suppress all diagnostic output (default)
        \\
        \\Examples:
        \\  zig_cli_daemon --mode simple ls -la
        \\  echo "data" | zig_cli_daemon --daemon-socket my.sock
        \\  zig_cli_daemon --body '{{ "id": 1 }}' -- my-app
        \\
    ;
    std.debug.print(usage, .{ VERSION, DEFAULT_SOCKET_PATH, DEFAULT_DAEMON_CMD });
}

const MessageType = enum(u7) {
    exit_code = 0,
    data = 1,
    stderr = 2,
    arg = 3,
    env_var = 4,
    stream_init = 5,
    stream_data = 6,
    jsonrpc = 7,
    get_pid = 8,
    cancel = 9,
};

const FrameHeader = struct {
    type: MessageType,
    more: bool,
    len: u32,
};

fn readHeader(reader: anytype) !FrameHeader {
    var header_buf: [4]u8 = undefined;
    reader.readSliceAll(&header_buf) catch |err| {
        if (err == error.EndOfStream) return error.EndOfStream;
        return err;
    };

    const first = header_buf[0];
    return FrameHeader{
        .type = @as(MessageType, @enumFromInt(@as(u7, @intCast(first >> 1)))),
        .more = (first & 1) != 0,
        .len = (@as(u32, header_buf[1]) << 16) | (@as(u32, header_buf[2]) << 8) | @as(u32, header_buf[3]),
    };
}

// Frame Header is 4 bytes: [Type: 7 bits | More: 1 bit] [Payload Length: 24 bits BE]
const MAX_FRAME_SIZE = 16 * 1024 * 1024; // 16MB limit for protocol sanity

var global_io: ?std.Io = null;
var global_stream: ?std.Io.net.Stream = null;
var global_mutex: std.Io.Mutex = .init;
var verbose = false;

fn sigHandleAbort() void {
    if (global_io) |io| {
        global_mutex.lockUncancelable(io);
        defer global_mutex.unlock(io);
        if (global_stream) |stream| {
            var buf: [16]u8 = undefined;
            var writer_obj = stream.writer(io, &buf);
            sendFrame(&writer_obj.interface, .cancel, false, &.{}) catch {};
            _ = writer_obj.interface.flush() catch {};
        }
    }
}

// Windows
fn windowsCtrlHandler(dwCtrlType: u32) callconv(.winapi) i32 {
    _ = dwCtrlType;
    sigHandleAbort();
    return 0; // OS will terminate us or we can call exit
}

// Unix (stub or simple handler)
fn unixSignalHandler(sig: i32) callconv(.c) void {
    _ = sig;
    sigHandleAbort();
    std.process.exit(143);
}

const ProtocolMode = enum(u8) {
    advanced = 0x00,
    simple = 0x01,
};

fn sendFrame(writer: anytype, msg_type: MessageType, more: bool, payload: []const u8) !void {
    var header: [4]u8 = undefined;
    header[0] = (@as(u8, @intFromEnum(msg_type)) << 1) | @as(u8, if (more) 1 else 0);

    const len = @as(u32, @intCast(payload.len));
    if (len > 0xFFFFFF) return error.PayloadTooLarge;
    header[1] = @intCast((len >> 16) & 0xFF);
    header[2] = @intCast((len >> 8) & 0xFF);
    header[3] = @intCast(len & 0xFF);

    try writer.writeAll(&header);
    try writer.writeAll(payload);
}

fn SocketForwarder(comptime WriterPtr: type) type {
    return struct {
        sock_writer: WriterPtr,
        mode: enum { simple, advanced },

        fn send(self: @This(), data: []const u8) !void {
            switch (self.mode) {
                .simple => try self.sock_writer.writeAll(data),
                .advanced => try sendFrame(self.sock_writer, .data, false, data),
            }
            try self.sock_writer.flush();
        }
    };
}

fn forwardBody(forwarder: anytype, body: []const u8, stream: std.Io.net.Stream, io: std.Io, thread: std.Thread) !void {
    try forwarder.send(body);
    try stream.shutdown(io, .send);
    thread.join();
}

fn forwardStdin(forwarder: anytype, stream: std.Io.net.Stream, io: std.Io, thread: std.Thread) !void {
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
        try forwarder.send(input_buf[0..amt]);
    }
    try stream.shutdown(io, .send);
    thread.join();
}

fn getHumanError(err: anyerror) []const u8 {
    return switch (err) {
        error.ConnectionRefused => "Connection refused. Is the daemon currently running?",
        error.Unexpected => "Connection refused or unexpected system error.",
        error.FileNotFound => "Socket file not found.",
        error.AccessDenied => "Permission denied.",
        error.DaemonStartupTimeout => "Timed out waiting for the daemon to start.",
        error.EmptyDaemonCommand => "The daemon command string is empty or invalid.",
        error.PayloadTooLarge => "Received a frame that exceeds the maximum allowed size (16MB).",
        error.InvalidExitCodeLength => "Received a malformed exit code frame from daemon.",
        error.EndOfStream => "Connection closed unexpectedly.",
        else => @errorName(err),
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 1. Argument Parsing
    const args = try init.minimal.args.toSlice(allocator);
    global_io = io;

    if (builtin.os.tag == .windows) {
        const kernel32 = struct {
            extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*const fn (u32) callconv(.winapi) i32, add: std.os.windows.BOOL) callconv(.winapi) std.os.windows.BOOL;
        };
        _ = kernel32.SetConsoleCtrlHandler(windowsCtrlHandler, @enumFromInt(@as(c_int, 1)));
    } else {
        // Simple Unix signal registration if available
    }

    var socket_path: ?[]const u8 = null;
    var daemon_cmd: ?[]const u8 = null;
    var daemon_timeout_ms: u32 = 3000;
    var is_restart = false;
    var is_status = false;
    var mode: ProtocolMode = .advanced;
    var client_args: std.ArrayList([]const u8) = .empty;
    defer client_args.deinit(allocator);
    var body: ?[]const u8 = null;
    var env_allow_patterns: std.ArrayList([]const u8) = .empty;
    defer env_allow_patterns.deinit(allocator);
    var env_deny_patterns: std.ArrayList([]const u8) = .empty;
    defer env_deny_patterns.deinit(allocator);
    var env_test = false;

    if (args.len <= 1) {
        printUsage();
        return;
    }

    var i: usize = 1;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--daemon-socket")) {
            i += 1;
            if (i >= args.len or std.mem.startsWith(u8, args[i], "--")) {
                std.debug.print("Error: --daemon-socket requires a value\n", .{});
                std.process.exit(1);
            }
            socket_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--daemon-cmd")) {
            i += 1;
            if (i >= args.len or std.mem.startsWith(u8, args[i], "--")) {
                std.debug.print("Error: --daemon-cmd requires a value\n", .{});
                std.process.exit(1);
            }
            daemon_cmd = args[i];
        } else if (std.mem.eql(u8, args[i], "--daemon-timeout")) {
            i += 1;
            if (i >= args.len or std.mem.startsWith(u8, args[i], "--")) {
                std.debug.print("Error: --daemon-timeout requires a value\n", .{});
                std.process.exit(1);
            }
            daemon_timeout_ms = std.fmt.parseInt(u32, args[i], 10) catch b: {
                std.debug.print("Warning: Invalid --daemon-timeout value '{s}', using default 3000ms\n", .{args[i]});
                break :b 3000;
            };
        } else if (std.mem.eql(u8, args[i], "--restart")) {
            is_restart = true;
        } else if (std.mem.eql(u8, args[i], "--body")) {
            i += 1;
            if (i >= args.len or std.mem.startsWith(u8, args[i], "--")) {
                std.debug.print("Error: --body requires a value\n", .{});
                std.process.exit(1);
            }
            body = args[i];
        } else if (std.mem.eql(u8, args[i], "--mode")) {
            i += 1;
            if (i >= args.len or std.mem.startsWith(u8, args[i], "--")) {
                std.debug.print("Error: --mode requires a value (simple|advanced)\n", .{});
                std.process.exit(1);
            }
            if (std.mem.eql(u8, args[i], "simple")) {
                mode = .simple;
            } else {
                mode = .advanced;
            }
        } else if (std.mem.eql(u8, args[i], "--env-allow")) {
            i += 1;
            if (i >= args.len or std.mem.startsWith(u8, args[i], "--")) {
                std.debug.print("Error: --env-allow requires a value\n", .{});
                std.process.exit(1);
            }
            try env_allow_patterns.append(allocator, args[i]);
        } else if (std.mem.eql(u8, args[i], "--env-deny")) {
            i += 1;
            if (i >= args.len or std.mem.startsWith(u8, args[i], "--")) {
                std.debug.print("Error: --env-deny requires a value\n", .{});
                std.process.exit(1);
            }
            try env_deny_patterns.append(allocator, args[i]);
        } else if (std.mem.eql(u8, args[i], "--env-test")) {
            env_test = true;
        } else if (std.mem.eql(u8, args[i], "--status")) {
            is_status = true;
        } else if (std.mem.eql(u8, args[i], "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, args[i], "--quiet")) {
            verbose = false;
        } else if (std.mem.eql(u8, args[i], "-h") or std.mem.eql(u8, args[i], "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, args[i], "-V") or std.mem.eql(u8, args[i], "--version")) {
            std.debug.print("v{s}\n", .{VERSION});
            return;
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

    if (env_test) {
        var env_iter = init.environ_map.iterator();
        while (env_iter.next()) |entry| {
            if (shouldForwardEnv(entry.key_ptr.*, env_allow_patterns.items, env_deny_patterns.items)) {
                std.debug.print("{s}\n", .{entry.key_ptr.*});
            }
        }
        return;
    }

    // 2. Connect to Daemon
    var ua = std.Io.net.UnixAddress.init(final_socket_path) catch |err| {
        std.debug.print("Fatal: Invalid socket path '{s}': {s}\n", .{ final_socket_path, getHumanError(err) });
        return err;
    };

    if (is_status) {
        const stream = ua.connect(io) catch |err| {
            std.debug.print("Daemon is NOT running on {s} ({s})\n", .{ final_socket_path, getHumanError(err) });
            std.process.exit(1);
        };
        defer stream.close(io);

        if (mode == .advanced) {
            var write_buf: [16]u8 = undefined;
            var sock_writer_obj = stream.writer(io, &write_buf);
            var stream_reader_obj = stream.reader(io, &[_]u8{});
            const reader = &stream_reader_obj.interface;
            try sendFrame(&sock_writer_obj.interface, .get_pid, false, &.{});
            try sock_writer_obj.interface.flush();

            const header = try readHeader(reader);

            if (header.type == .get_pid) {
                if (header.len != 8) return error.PayloadTooLarge;
                var pid_buf: [8]u8 = undefined;
                try reader.readSliceAll(&pid_buf);
                const pid = std.mem.readInt(u64, &pid_buf, .big);
                std.debug.print("Daemon is running (PID: {d})\n", .{pid});
            } else {
                std.debug.print("Daemon is running (Advanced Mode)\n", .{});
            }
        } else {
            std.debug.print("Daemon is running (Simple Mode)\n", .{});
        }
        std.process.exit(0);
    }

    const stream = connectToDaemonOrSpawn(io, allocator, gpa, final_socket_path, final_daemon_cmd, daemon_timeout_ms) catch |err| {
        std.debug.print("Fatal: Could not connect to or start daemon. Error: {s}\n", .{getHumanError(err)});
        return err;
    };
    defer {
        global_mutex.lockUncancelable(io);
        global_stream = null;
        global_mutex.unlock(io);
        stream.close(io);
    }
    
    global_mutex.lockUncancelable(io);
    global_stream = stream;
    global_mutex.unlock(io);

    if (is_restart) {
        var writer_obj = stream.writer(io, &[_]u8{});
        try sendFrame(&writer_obj.interface, .exit_code, false, &.{ 0, 0, 0, 0 });
        try writer_obj.interface.flush();
        if (verbose) std.debug.print("Restart signal sent to daemon.\n", .{});
        return;
    }

    if (mode == .simple) {
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
            if (!shouldForwardEnv(entry.key_ptr.*, env_allow_patterns.items, env_deny_patterns.items)) continue;
            try meta.appendSlice(allocator, entry.key_ptr.*);
            try meta.append(allocator, '=');
            try meta.appendSlice(allocator, entry.value_ptr.*);
            try meta.append(allocator, 0);
        }
        try meta.append(allocator, 0);

        var meta_writer_obj = stream.writer(io, &[_]u8{});
        try meta_writer_obj.interface.writeInt(u32, @intCast(meta.items.len), .big);
        try meta_writer_obj.interface.writeAll(meta.items);
        try meta_writer_obj.interface.flush();

        const pipe_stdout = struct {
            fn run_pipe(sock: std.Io.net.Stream, thread_io: std.Io) !void {
                const stdout_file = std.Io.File.stdout();
                var read_buf: [BUFFER_SIZE]u8 = undefined;
                var stream_reader_obj = sock.reader(thread_io, &read_buf);
                const reader = &stream_reader_obj.interface;
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
            const Forwarder = SocketForwarder(*@TypeOf(sock_writer_simple.interface));
            const forwarder = Forwarder{ .sock_writer = &sock_writer_simple.interface, .mode = .simple };
            try forwardBody(forwarder, b, stream, io, thread);
        } else {
            var write_buf: [BUFFER_SIZE]u8 = undefined;
            var sock_writer_simple = stream.writer(io, &write_buf);
            const Forwarder = SocketForwarder(*@TypeOf(sock_writer_simple.interface));
            const forwarder = Forwarder{ .sock_writer = &sock_writer_simple.interface, .mode = .simple };
            try forwardStdin(forwarder, stream, io, thread);
        }
        return;
    }

    var sock_buf: [BUFFER_SIZE]u8 = undefined;
    var sock_writer_obj = stream.writer(io, &sock_buf);

    const pwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(pwd);

    // Filter environment first to get an accurate count
    var env_vars: std.ArrayList([]const u8) = .empty;
    defer {
        for (env_vars.items) |ev| allocator.free(ev);
        env_vars.deinit(allocator);
    }
    var env_iter = init.environ_map.iterator();
    while (env_iter.next()) |entry| {
        if (shouldForwardEnv(entry.key_ptr.*, env_allow_patterns.items, env_deny_patterns.items)) {
            const entry_str = try std.fmt.allocPrint(allocator, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
            try env_vars.append(allocator, entry_str);
        }
    }

    const total_metadata_frames = 2 + env_vars.items.len + client_args.items.len;
    var frames_sent: usize = 0;

    // 1. Exec name
    frames_sent += 1;
    try sendFrame(&sock_writer_obj.interface, .arg, frames_sent < total_metadata_frames, args[0]);

    // 2. PWD
    frames_sent += 1;
    try sendFrame(&sock_writer_obj.interface, .arg, frames_sent < total_metadata_frames, pwd);

    // 3. Env Vars
    for (env_vars.items) |ev| {
        frames_sent += 1;
        try sendFrame(&sock_writer_obj.interface, .env_var, frames_sent < total_metadata_frames, ev);
    }

    // 4. Client Args
    for (client_args.items) |arg| {
        frames_sent += 1;
        try sendFrame(&sock_writer_obj.interface, .arg, frames_sent < total_metadata_frames, arg);
    }

    try sock_writer_obj.interface.flush();

    const socket_to_stdout = struct {
        fn run(sock: std.Io.net.Stream, thread_io: std.Io) !void {
            const stdout_file = std.Io.File.stdout();
            const stderr_file = std.Io.File.stderr();

            var read_buf: [BUFFER_SIZE]u8 = undefined;
            var stream_reader_obj = sock.reader(thread_io, &read_buf);
            const reader = &stream_reader_obj.interface;

            while (true) {
                const header = readHeader(reader) catch |err| {
                    if (err == error.EndOfStream) break;
                    return err;
                };

                if (header.len > MAX_FRAME_SIZE) return error.PayloadTooLarge;

                if (header.type == .exit_code) {
                    if (header.len != 4) return error.InvalidExitCodeLength;
                    var exit_buf: [4]u8 = undefined;
                    try reader.readSliceAll(&exit_buf);
                    const code = std.mem.readInt(i32, &exit_buf, .big);
                    std.process.exit(@intCast(code));
                }

                if (header.type == .data or header.type == .stderr) {
                    const file = if (header.type == .data) stdout_file else stderr_file;
                    var remaining = header.len;
                    var chunk: [BUFFER_SIZE]u8 = undefined;
                    while (remaining > 0) {
                        const to_read = @min(remaining, chunk.len);
                        const read = try reader.readSliceShort(chunk[0..to_read]);
                        if (read == 0) return error.EndOfStream;
                        try file.writeStreamingAll(thread_io, chunk[0..read]);
                        remaining -= @intCast(read);
                    }
                } else {
                    try reader.discardAll(header.len);
                }
            }
        }
    };

    const thread = try std.Thread.spawn(.{}, socket_to_stdout.run, .{ stream, io });

    if (body) |b| {
        const Forwarder = SocketForwarder(*@TypeOf(sock_writer_obj.interface));
        const forwarder = Forwarder{ .sock_writer = &sock_writer_obj.interface, .mode = .advanced };
        try forwardBody(forwarder, b, stream, io, thread);
    } else {
        const Forwarder = SocketForwarder(*@TypeOf(sock_writer_obj.interface));
        const forwarder = Forwarder{ .sock_writer = &sock_writer_obj.interface, .mode = .advanced };
        try forwardStdin(forwarder, stream, io, thread);
    }
}

fn isPidAlive(pid: u32) bool {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const local_kernel32 = struct {
            extern "kernel32" fn OpenProcess(dwDesiredAccess: windows.DWORD, bInheritHandle: windows.BOOL, dwProcessId: windows.DWORD) callconv(.winapi) ?windows.HANDLE;
            extern "kernel32" fn GetExitCodeProcess(hProcess: windows.HANDLE, lpExitCode: *windows.DWORD) callconv(.winapi) windows.BOOL;
        };
        const handle = local_kernel32.OpenProcess(0x1000, @enumFromInt(@as(c_int, 0)), pid);
        if (handle) |h| {
            defer windows.CloseHandle(h);
            var exit_code: windows.DWORD = 0;
            if (@intFromEnum(local_kernel32.GetExitCodeProcess(h, &exit_code)) != 0) {
                return exit_code == 259;
            }
        }
        return false;
    } else {
        _ = std.posix.kill(@intCast(pid), 0) catch |err| {
            if (err == error.ProcessNotFound) return false;
            return true;
        };
        return true;
    }
}

fn connectToDaemonOrSpawn(
    io: std.Io,
    allocator: std.mem.Allocator,
    gpa: std.mem.Allocator,
    socket_path: []const u8,
    daemon_cmd_str: []const u8,
    timeout_ms: u32,
) !std.Io.net.Stream {
    const ua = try std.Io.net.UnixAddress.init(socket_path);
    if (ua.connect(io)) |stream| return stream else |_| {}

    const pid_path = try std.fmt.allocPrint(allocator, "{s}.pid", .{socket_path});
    var pid_file = try std.Io.Dir.cwd().createFile(io, pid_path, .{ .truncate = false, .read = true });
    defer pid_file.close(io);
    try pid_file.lock(io, .exclusive);

    if (ua.connect(io)) |stream| return stream else |_| {}

    var is_dead = true;
    var pid_buf: [64]u8 = undefined;
    var pid_reader_obj = pid_file.reader(io, &pid_buf);
    const pid_reader = &pid_reader_obj.interface;
    if (pid_reader.readSliceShort(&pid_buf)) |amt| {
        if (amt > 0) {
            if (std.fmt.parseInt(u32, std.mem.trim(u8, pid_buf[0..amt], " \n\r\t"), 10)) |pid| {
                if (isPidAlive(pid)) is_dead = false;
            } else |_| {}
        }
    } else |_| {}

    if (is_dead) {
        if (verbose) std.debug.print("Daemon not running or stale socket detected. Spawning...\n", .{});
        std.Io.Dir.cwd().deleteFile(io, socket_path) catch {};
        try spawnDaemon(io, allocator, gpa, daemon_cmd_str);
    }

    const max_retries = timeout_ms / 10;
    var retries: usize = 0;
    while (retries < max_retries) : (retries += 1) {
        const wait_timeout = std.Io.Timeout{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(10),
            .clock = .awake,
        } };
        _ = wait_timeout.sleep(io) catch {};
        if (ua.connect(io)) |stream| return stream else |_| {}
    }
    return error.DaemonStartupTimeout;
}

fn spawnDaemon(io: std.Io, allocator: std.mem.Allocator, gpa: std.mem.Allocator, daemon_cmd_str: []const u8) !void {
    var cmd_args: std.ArrayList([]const u8) = .empty;
    defer {
        for (cmd_args.items) |arg| allocator.free(arg);
        cmd_args.deinit(allocator);
    }

    var i: usize = 0;
    while (i < daemon_cmd_str.len) {
        while (i < daemon_cmd_str.len and daemon_cmd_str[i] == ' ') i += 1;
        if (i == daemon_cmd_str.len) break;

        var current_arg: std.ArrayList(u8) = .empty;
        defer current_arg.deinit(allocator);

        var state: enum { normal, single_quote, double_quote, escape } = .normal;
        var in_quote = false;

        while (i < daemon_cmd_str.len) : (i += 1) {
            const c = daemon_cmd_str[i];
            switch (state) {
                .normal => {
                    if (c == ' ') {
                        if (!in_quote) break;
                        try current_arg.append(allocator, c);
                    } else if (c == '\\') {
                        state = .escape;
                    } else if (c == '\'') {
                        state = .single_quote;
                        in_quote = true;
                    } else if (c == '"') {
                        state = .double_quote;
                        in_quote = true;
                    } else {
                        try current_arg.append(allocator, c);
                    }
                },
                .single_quote => {
                    if (c == '\'') {
                        state = .normal;
                        in_quote = false; 
                    } else {
                        try current_arg.append(allocator, c);
                    }
                },
                .double_quote => {
                    if (c == '"') {
                        state = .normal;
                        in_quote = false;
                    } else if (c == '\\') {
                        // Very basic escaping inside double quotes
                        if (i + 1 < daemon_cmd_str.len and (daemon_cmd_str[i+1] == '"' or daemon_cmd_str[i+1] == '\\')) {
                           i += 1;
                           try current_arg.append(allocator, daemon_cmd_str[i]);
                        } else {
                           try current_arg.append(allocator, c);
                        }
                    } else {
                        try current_arg.append(allocator, c);
                    }
                },
                .escape => {
                    try current_arg.append(allocator, c);
                    state = .normal;
                },
            }
        }
        if (current_arg.items.len > 0 or in_quote) {
            try cmd_args.append(allocator, try allocator.dupe(u8, current_arg.items));
        }
    }

    if (cmd_args.items.len == 0) return error.EmptyDaemonCommand;

    const run_daemon_thread = struct {
        fn run(thread_io: std.Io, thread_allocator: std.mem.Allocator, args: [][]const u8) void {
            var child = std.process.spawn(thread_io, .{
                .argv = args,
                .stdout = .ignore,
                .stderr = .ignore,
            }) catch |err| {
                if (verbose) std.debug.print("Warning: Failed to execute daemon spawn command: {any}\n", .{err});
                return;
            };
            _ = child.wait(thread_io) catch {};
            for (args) |arg| thread_allocator.free(arg);
            thread_allocator.free(args);
        }
    };

    var dup_args = try gpa.alloc([]const u8, cmd_args.items.len);
    for (cmd_args.items, 0..) |arg, idx| {
        dup_args[idx] = try gpa.dupe(u8, arg);
    }

    const thread = try std.Thread.spawn(.{}, run_daemon_thread.run, .{ io, gpa, dup_args });
    thread.detach();
}

fn envPatternMatch(value: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return false;
    var pat = pattern;
    const starts_anchor = pat[0] == '^';
    if (starts_anchor) pat = pat[1..];
    const ends_anchor = pat.len > 0 and pat[pat.len - 1] == '$';
    if (ends_anchor) pat = pat[0 .. pat.len - 1];

    const wildcard_pos = std.mem.indexOf(u8, pat, ".*");
    if (wildcard_pos) |pos| {
        const prefix = pat[0..pos];
        const suffix = pat[pos + 2 ..];
        if (starts_anchor) {
            if (!std.mem.startsWith(u8, value, prefix)) return false;
            const remainder = value[prefix.len..];
            if (ends_anchor) return std.mem.endsWith(u8, remainder, suffix);
            return std.mem.indexOf(u8, remainder, suffix) != null;
        } else if (ends_anchor) {
            if (!std.mem.endsWith(u8, value, suffix)) return false;
            const head = value[0 .. value.len - suffix.len];
            return prefix.len == 0 or std.mem.indexOf(u8, head, prefix) != null;
        } else {
            if (std.mem.indexOf(u8, value, prefix)) |first| {
                const remainder = value[first + prefix.len ..];
                return std.mem.indexOf(u8, remainder, suffix) != null;
            }
            return false;
        }
    }

    if (starts_anchor and ends_anchor) return std.mem.eql(u8, value, pat);
    if (starts_anchor) return std.mem.startsWith(u8, value, pat);
    if (ends_anchor) return std.mem.endsWith(u8, value, pat);
    return std.mem.indexOf(u8, value, pat) != null;
}

fn shouldForwardEnv(env_name: []const u8, allow_patterns: [][]const u8, deny_patterns: [][]const u8) bool {
    if (allow_patterns.len == 0 and deny_patterns.len == 0) return false;

    for (deny_patterns) |pattern| {
        if (envPatternMatch(env_name, pattern)) return false;
    }
    if (allow_patterns.len == 0) return true;
    for (allow_patterns) |pattern| {
        if (envPatternMatch(env_name, pattern)) return true;
    }
    return false;
}
