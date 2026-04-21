# Protocol Specification

The CLI bridge and daemon must agree on the same mode before communicating. There is no negotiation header.

## Advanced Mode (`--mode advanced`, default)

Uses a ZMTP-style 4-byte header framing protocol to multiplex data types over a single connection.

### Frame Header (4 Bytes)

- **Byte 0**: `[Type: 7 bits | More: 1 bit]`
  - `Bits 1-7`: Message Type.
  - `Bit 0`: `More` flag (1 = another frame follows for this logical message).
- **Bytes 1-3**: `Payload Length` (24-bit unsigned integer, Big Endian).

### Message Types

| Type  | Name            | Direction     | Payload                                              |
| ----- | --------------- | ------------- | ---------------------------------------------------- |
| **0** | **Exit Code**   | Bi-Di         | 4 bytes (Big Endian Exit Status)                     |
| **1** | **Data**        | Bi-Di         | CLI stdin (C->D) or daemon stdout (D->C)             |
| **2** | **Stderr**      | Daemon -> CLI | Raw stream chunk                                     |
| **3** | **Argument**    | CLI -> Daemon | UTF-8 string (Order: Exec, PWD, Args...)             |
| **4** | **Env Var**     | CLI -> Daemon | `NAME=VALUE` UTF-8 string                            |
| **5** | **Stream Init** | Bi-Di         | `[1 byte ID] [8 bytes total size] [UTF-8 Name/Path]` |
| **6** | **Stream Data** | Bi-Di         | `[1 byte ID] [Raw Payload]`                          |
| **7** | **JSON-RPC**    | Bi-Di         | UTF-8 JSON string                                    |
| **8** | **Get PID**     | Bi-Di         | Returns the daemon process ID                        |

## Notes

- The advanced mode framing protocol is intentionally lightweight and stream-oriented.
- The `More` bit allows logical messages to span multiple frames without requiring the sender to buffer a full payload.
- The protocol does not include a negotiation handshake; both endpoints must agree on `simple` vs `advanced` up front.

## Simple Mode (`--mode simple`)

Designed for easy daemon implementation. And caces where it is more about triggering the daemon than full control.

1. **Metadata Block**: `[u32 length (BE)] [null-terminated strings...]`
   - Strings: `exec\0pwd\0arg1\0arg2\0...\0ENV1=val\0ENV2=val\0\0`
   - Double null (`\0\0`) terminates the block.
2. **Raw Bidirectional Pipe**: All subsequent bytes flow transparently between CLI stdin/stdout and the daemon socket.

### Limitations

- **No Signal Multiplexing**: Simple mode is a raw pipe. It does not support separate `stderr` or propagating the daemon's exit code.
- **Merged Streams**: The daemon must write both stdout and stderr to the same output stream, which the CLI bridge prints to its own `stdout`.
- **Exit Status**: The CLI bridge will always exit with code `0` in Simple Mode unless the connection itself fails.
