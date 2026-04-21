# Zig CLI Daemon Bridge

Minimize execution latency by maintaining a long-running background daemon and passing arguments, `stdin`, `stdout`, and `stderr` over Unix Sockets.

Initially made to help optimize Java process startup time for repeated tasks like testing and compilation. 

> High-performance, zero allocation, written in Zig 0.16.0 and faster alternative to `socat + cat` combo.

## Usage

```bash
CLI Daemon Bridge v0.1.0

Usage: zig_cli_daemon [options] [--] [command args...]

Options:
  -h, --help                Show this help message
  -V, --version             Show version information
  --daemon-socket <path>    Socket path (default: daemon.sock)
  --daemon-cmd <cmd>       Command to spawn daemon (default: "java -jar daemon.jar")
  --daemon-timeout <ms>    Wait timeout for daemon startup (default: 3000ms)
  --restart                 Send restart signal and exit
  --body <body>             Send text/json payload instead of stdin
  --mode <simple|advanced>  Protocol mode (default: advanced)
  --env-allow <pattern>    Regex-ish pattern for environment forwarding
  --env-deny <pattern>     Regex-ish pattern for environment exclusion
  --env-test                Print filtered environment and exit
  --status                  Check if daemon is running and exit
  --verbose                 Print diagnostic information to stderr
  --quiet                   Suppress all diagnostic output (default)

Examples:
  zig_cli_daemon --mode simple ls -la
  echo "data" | zig_cli_daemon --daemon-socket my.sock
  zig_cli_daemon --body '{ "id": 1 }' -- my-app
```

You MUST take a bit of time/effort and setup **alias** to enjoy the benefits of the cli-daemon fully like so:

```bash
my_cli_tool cliarg1 cliarg2 ...
```

### Wrapping it via Alias (Recommended Setup)
By aliasing it to your shell path, you get frictionless high-performance execution. On windows add one folder to path and put your alias batch files there.

```bash
alias native_graal='/path/to/zig_cli_daemon --daemon-socket /tmp/fast-app.sock --daemon-cmd "java -jar my-worker.jar" --'

# Execute seamlessly
native_graal compile --target=aarch64
```

Regardless if you are using windows or linux, find time to setup a place for your own cli tools. If not as important as before, now in age of AI hype, CLI is the king.

## Advanced Usage (Application Management & Security)

The CLI bridge transforms a "black box" background process into a manageable service. By utilizing Unix Domain Sockets (UDS) instead of TCP, you gain a high-performance side-channel for administrative tasks without the overhead or risks of exposing network ports.

### 🛡️ Secure Local Administration
*   **POSIX-Based Access Control**: Security is governed by OS filesystem permissions. By setting the socket directory to `0700`, you ensure only the service owner can manage the application. This structurally prevents unauthorized local users or network probes from accessing internal management endpoints.
*   **Socket Access == Management Access**: The daemon shutdown/restart path is intentionally protected by the same socket permissions used for normal daemon control. If the socket is stored in a user-private directory and the file permissions are restricted, only authorized local accounts can connect and issue management frames.
*   **No Shared Secrets for Local-only Control**: Authorization can be implicitly handled by the OS. Administrative tasks like `RELOAD_CONFIGURATION` or `PURGE_CACHE` don't require managing fragile API keys for local-only traffic—the kernel validates the connection identity via the socket inode.
*   **Restrict forwarded environment variables**: Do not forward every environment variable blindly. Use `--env-allow` to permit only specific env keys and `--env-deny` to block sensitive values. Example allow patterns: `^PATH$`, `^JAVA_HOME$`, `^USER$`; example deny pattern: `^(AWS|GITHUB|SECRET|TOKEN)_`.
*   **Test filter matches**: Use `--env-test` to print the environment variable names that would be forwarded under the active allow/deny rules, one name per line. This helps verify regex patterns without connecting to the daemon.
*   **Optional Hardening**: If you need a second layer of protection beyond filesystem ACLs, consider placing the daemon socket in a user-only directory and/or adding an application-level token. The default model assumes local process isolation and file-permission-based trust, which is the standard security model for Unix domain socket services.
*   **Windows Security & Philosophy**: On Windows, Unix domain sockets do not inherit the same POSIX-style permission enforcement as on Linux/macOS. As such, any local user can potentially connect to the socket if it is in a shared directory. **Windows support in this project is focused on performance and operational parity ("making it work") rather than providing an equivalent security boundary.** For secure deployments on Windows, we recommend placing your sockets in user-private directories (e.g., `%LOCALAPPDATA%`) and manually setting NTFS ACLs on the socket file.
*   **Token Example**: A management token can be sent as raw stdin text via `--body` or piped into the CLI, then validated by the daemon before processing sensitive frames.

```bash
# One-shot token send with --body
./zig_cli_daemon --daemon-socket /tmp/secure.sock --daemon-cmd "java -jar daemon.jar" --body "SECRET_TOKEN" -- status

# Pipe a token from stdin
printf '%s' "SECRET_TOKEN" | ./zig_cli_daemon --daemon-socket /tmp/secure.sock --daemon-cmd "java -jar daemon.jar" -- status
```

### ⚡ Sub-Millisecond Management
*   **Instant Interaction**: Management requests over UDS bypass the entire TCP/IP stack (handshakes, encapsulation, congestion control). status checks and metrics gathering occur with near-zero latency.
*   **Lightweight Side-Channel**: Unlike heavy management agents or HTTP servers, the bridge provides a "raw" connection. You can send a JSON trigger via `--body` and receive instant status without waking up a heavy web-server threadpool.

### 🔄 Dynamic Lifecycle & Metrics
*   **Hot-Reloading**: Trigger configuration updates live without restarting the JVM by sending custom management frames.
*   **Real-time Metrics**: Stream internal state or live logs directly to the CLI stdout for immediate diagnostic feedback.

> [!TIP]
> Use the `--body` parameter for one-shot management tasks:
> `bash
> ./zig_cli_daemon --body '{"action":"RELOAD_CONFIG"}' -- admin-cmd
> `



### Examples

**1. General Invocation:**
```bash
./zig_cli_daemon --daemon-socket /tmp/graal-native-server.sock \
                 --daemon-cmd "/opt/my-app/start_server-native" \
                 -- build backend --incremental
```

**2. Sending a JSON payload directly:**
```bash
./zig_cli_daemon --mode advanced --body '{"action": "status", "id": 123}' -- rpc-call
```

**3. Standard Input/Output Chaining:**
```bash
# Streams live terminal inputs completely into the socket asynchronously
cat large_data.json | ./zig_cli_daemon -- parse-json --validate
```


## Compatibility

This project requires **Native Unix Domain Socket** support.
- **Windows**: Requires **Windows 10 Version 1803** (Build 17063) or newer.
- **Linux/macOS**: Supported natively on all modern versions.
- **Java**: Requires **OpenJDK 21+** for native `java.net` support (Project uses **Java 21**).
- **Zig**: Requires **Zig 0.16.0** (standard library `std.Io` and `std.process` integration).

## Use cases & Advantages (Unix Sockets vs TCP)

Unix Domain Sockets (UDS) offer substantial architectural and operational advantages over local `localhost` TCP connections for IPC background daemons.

### Raw Performance & Latency
- **Zero-Network Overhead**: UDS completely bypasses the IP routing stack, TCP state machines, encapsulation, checksum generation, Nagle's algorithm, and MTU fragmentation. Data is shunted directly between process kernel buffers.
- **Microsecond Latency**: Testing suites and compilers suffer heavily from process startup limits. Bridging over a socket guarantees sub-millisecond data transit, routinely supporting 2x-3x higher raw throughput compared to TCP loopbacks for bursty CLI commands.
- **Instant Liveness Discovery**: Determining if another daemon instance is alive using a TCP loopback port requires ephemeral port allocation and a full TCP handshake (often stalling for `0.1ms` to `0.5ms+`). A Unix socket connects directly via an OS inode lookup, dropping coordination and polling latency down to raw nanoseconds. If the background process is dead, the kernel immediately rejects with `ECONNREFUSED` instead of risking dangling `TIME_WAIT` network timeouts.

### Hardened Security
- **Filesystem-Backed Permissions**: Sockets bind strictly to OS POSIX file permissions. Only users or directory-groups with explicit file read/write access can connect. This structurally prevents unauthorized background agents from probing exposed TCP ports on a shared machine.
- **Trusted Endpoints**: Safe administration commands, clean-shutdown hooks, and liveness checks can be performed natively over the socket without relying on insecure internal tokens or localhost firewall rules.

### Typical Real-World Examples
Major high-performance systems default to Unix sockets for local IPC:
- **Build Daemons**: The Maven Daemon (`mvnd`), Gradle Daemon, and `bloop` (Scala) all utilize persistent background workers, communicating via sockets to completely eliminate JVM boot latency.
- **Docker**: The Docker cli communicates natively with the OS engine via `/var/run/docker.sock`, securing admin privileges simply through group allocation.
- **Databases & Proxies**: PostgreSQL (`.s.PGSQL.5432`), Redis, and Nginx reverse-proxies (e.g., PHP-FPM/uWSGI) often connect across local Unix sockets in production to strip TCP processing lag.

### Configuration Best Practices
- **Secure Namespaces**: Always host the socket file in isolated user-bound directory paths (e.g., `/tmp/user_scope/` or `/run/user/1000/`) rather than the open `/tmp/` root. The Java daemon automatically applies **`0700` (Owner-Only) POSIX permissions** to the socket file upon binding on supported systems to prevent unauthorized access.
- **Stale Socket Handling**: Operating system crashes can leave stale socket files behind. This CLI bridge natively captures `ConnectionRefused` faults to identify stale nodes, automatically deletes the stale socket file, and forcefully boots the background worker back up.
- **Path Length Limits**: POSIX structures rigidly limit Unix socket system paths to `108 bytes`. Do not generate excessively deep file structures for the connection target.

## Features

- **Optimistic Auto-Restart**: The bridge assumes the daemon is alive for raw `0ms` overhead. If the Unix socket is down, it natively auto-spawns the fallback process in the background, polling efficiently until the socket connects.
- **Zero-Allocation Data Streams**: Built natively against the Zig 0.16.0 `std.Io` subsystem, eliminating standard library allocations by buffering everything via static stack chunks mapping.
- **Bi-Directional Bridging**: Connects isolated processes dynamically, piping internal Linux/Windows standard streams dynamically across the socket.
- **Environment & CWD Forwarding**: Automatically captures and serializes the caller's environment map and absolute working directory to the daemon.
- **Multiplexed I/O & Exit Codes**: Supports interleaved `stdout` and `stderr` streams, and propagates the daemon's exit status back to the CLI shell.
- **Superior to `socat` + `cat` Shelling**: Traditional bash scripting around `socat` requires generating expensive subshells, lacks CWD alignment out-of-the-box, and struggles with pure bi-directional stream multiplexing synchronization. This tool handles pure byte-for-byte stream forwarding efficiently in user space without spawning piped subshells.
- **Frictionless Cross-Compilation**: Leveraging Zig's world-class toolchain, this bridge produces a statically linked, ultra-efficient standalone payload that seamlessly compiles to hundreds of architectures (Linux, macOS, Windows/WSL) via a single command, dropping the heavy external dependency requirements typical in production environments.

## Build

Compile the native executable using Zig 0.16.0:

```bash
# Production build with maximum execution performance
zig build -Doptimize=ReleaseFast

# The compiled binary will be located at:
# ./zig-out/bin/zig_cli_daemon(.exe)
```

## Advanced Workflow Examples

**4. JSON-RPC Communication:**
Because the CLI seamlessly bridges standard streams, you can use it to transmit formatted RPC payloads to your daemon process. In this example, the daemon expects an `RPC` execution mode, receives the request payload via `stdin`, and returns the JSON-RPC response via `stdout`.

```bash
# Pipe the JSON-RPC payload into stdin and capture the JSON response from stdout
echo '{"jsonrpc": "2.0", "method": "subtract", "params": [42, 23], "id": 1}' | \
  ./zig_cli_daemon --daemon-socket /tmp/rpc.sock \
                   --daemon-cmd "java -jar rpc-server.jar" \
                   -- RPC
```

**5. Single Instance Coordination & Graceful Handoff:**
Because the OS rejects dead Unix Sockets instantly (vs. TCP handshake delays), the CLI bridge is perfect for coordinating a zero-downtime handoff. You can notify an older daemon instance to gracefully shut down—and release its bound TCP ports—right before launching your replacement process.

```bash
# Connect to the old daemon and transmit a custom Shutdown directive
./zig_cli_daemon --daemon-socket /tmp/worker.sock \
                 --daemon-cmd "echo 'Daemon already dead'" \
                 -- GRACEFUL_SHUTDOWN

# The old daemon detects the instruction, releases its IP ports, and exits safely.
# Now, instantly spin up the new version of your worker without "Address already in use" errors!
java -jar new-worker-v2.jar &
```

## Technical Protocol Specification

For the full protocol details, see [PROTOCOL.md](PROTOCOL.md).

## Reference Implementations (Java)

The project includes two standalone Java implementations:

### 1. Simple Daemon
Raw pipe, no framing. Ideal for minimal tools.
```bash
java -cp target/daemon-1.0.0.jar hr.hrg.daemon.simple.Main
```

### 2. Advanced Daemon
Full multiplexed framing protocol.
```bash
java -cp target/daemon-1.0.0.jar hr.hrg.daemon.advanced.Main
```

## Java Daemon Build & Run Instructions

Build the Java daemon with Maven from the project root:

```bash
mvn package
```

This produces the daemon JAR at:

```bash
target/daemon-1.0.0.jar
```

Then run either daemon implementation:

```bash
java -cp target/daemon-1.0.0.jar hr.hrg.daemon.simple.Main
```

or:

```bash
java -cp target/daemon-1.0.0.jar hr.hrg.daemon.advanced.Main
```

> Note: Java 21 is required to compile and run the daemon implementations.

## Background Diagnostics

1. **Path Alignment Forwarding**: Upon connection, the CLI will predictably send its absolute Current Working Directory (`CWD`) via Zig's `std.process.currentPathAlloc()` straight into the daemon buffer, allowing your long-running java application to calculate relative compilation and read instructions normally.
2. **Optimistic Thread Link**: If linking to the socket fails (`error.FileNotFound`), the application detaches an internal `std.Thread` and asynchronously launches the daemon command using OS level `spawn` mechanics. It polls up to `3000ms` concurrently until establishing socket access.
