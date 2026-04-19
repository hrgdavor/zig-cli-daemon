package hr.hrg.daemon.advanced;

import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.channels.Channels;
import java.nio.channels.ServerSocketChannel;
import java.nio.channels.SocketChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.Executor;

public class Protocol {

    public enum MessageType {
        EXIT_CODE(), // 0
        STDIN_STDOUT(), // 1
        STDERR(), // 2
        ARG(), // 3
        ENV_VAR(), // 4
        STREAM_INIT(), // 5
        STREAM_DATA(), // 6
        JSONRPC(), // 7
        GET_PID(),// 8
        ;

        public int getValue() {
            return ordinal();
        }

        public static MessageType fromValue(int value) {
            return switch (value) {
                case 0 -> EXIT_CODE;
                case 1 -> STDIN_STDOUT;
                case 2 -> STDERR;
                case 3 -> ARG;
                case 4 -> ENV_VAR;
                case 5 -> STREAM_INIT;
                case 6 -> STREAM_DATA;
                case 7 -> JSONRPC;
                case 8 -> GET_PID;
                default -> null;
            };
        }
    }

    public static class Frame {
        public final MessageType type;
        public final boolean more;
        public final byte[] payload;

        public Frame(MessageType type, boolean more, byte[] payload) {
            this.type = type;
            this.more = more;
            this.payload = payload;
        }
    }

    public static Frame readFrame(InputStream in) throws IOException {
        int first = in.read();
        if (first == -1)
            return null;

        MessageType type = MessageType.fromValue((first >> 1) & 0x7F);
        boolean more = (first & 1) != 0;

        int b1 = in.read();
        int b2 = in.read();
        int b3 = in.read();
        if ((b1 | b2 | b3) < 0)
            throw new EOFException();

        int len = (b1 << 16) | (b2 << 8) | b3;
        byte[] payload = new byte[len];
        int read = 0;
        while (read < len) {
            int n = in.read(payload, read, len - read);
            if (n == -1)
                throw new EOFException();
            read += n;
        }

        return new Frame(type, more, payload);
    }

    public static void writeFrame(OutputStream out, MessageType type, boolean more, byte[] payload) throws IOException {
        int first = (type.getValue() << 1) | (more ? 1 : 0);
        out.write(first);

        int len = payload.length;
        if (len > 0xFFFFFF)
            throw new IOException("Payload too large");

        out.write((len >> 16) & 0xFF);
        out.write((len >> 8) & 0xFF);
        out.write(len & 0xFF);
        out.write(payload);
    }

    @FunctionalInterface
    public interface SessionHandler {
        void handle(InputStream in, OutputStream out, List<String> args) throws IOException;
    }

    public static class DaemonServer {
        private final Path socketPath;
        private final Executor executor;
        private final SessionHandler sessionHandler;
        private final Runnable restartHandler;

        public DaemonServer(Path socketPath, Executor executor, SessionHandler sessionHandler,
                Runnable restartHandler) {
            this.socketPath = socketPath;
            this.executor = executor;
            this.sessionHandler = sessionHandler;
            this.restartHandler = restartHandler;
        }

        public void run() throws IOException {
            Path parent = socketPath.getParent();
            if (parent != null && !Files.exists(parent)) {
                Files.createDirectories(parent);
            }

            if (Files.exists(socketPath)) {
                Files.delete(socketPath);
            }

            UnixDomainSocketAddress address = UnixDomainSocketAddress.of(socketPath);

            try (ServerSocketChannel server = ServerSocketChannel.open(StandardProtocolFamily.UNIX)) {
                server.bind(address);
                System.out.println("Advanced Daemon started on " + socketPath + " using "
                        + System.getProperty("java.runtime.name"));

                if (!System.getProperty("os.name").startsWith("Windows")) {
                    try {
                        Files.setPosixFilePermissions(socketPath,
                                java.nio.file.attribute.PosixFilePermissions.fromString("rwx------"));
                    } catch (UnsupportedOperationException e) {
                        System.err.println("Warning: Filesystem does not support POSIX permissions.");
                    }
                }

                while (true) {
                    try {
                        SocketChannel socket = server.accept();
                        executor.execute(() -> {
                            try (socket;
                                    InputStream in = Channels.newInputStream(socket);
                                    OutputStream out = Channels.newOutputStream(socket)) {
                                handleProtocol(in, out);
                            } catch (Exception e) {
                                System.err.println("Error handling client: " + e.getMessage());
                            }
                        });
                    } catch (Exception e) {
                        System.err.println("Error accepting client: " + e.getMessage());
                    }
                }
            }
        }

        private void handleProtocol(InputStream in, OutputStream out) throws IOException {
            List<String> clientArgs = new ArrayList<>();
            String pwd = null;
            String execName = null;

            while (true) {
                Frame frame = readFrame(in);
                if (frame == null)
                    return;

                if (frame.type == MessageType.EXIT_CODE) {
                    try {
                        Files.deleteIfExists(socketPath);
                    } catch (Exception e) {
                        e.printStackTrace();
                    }
                    restartHandler.run();
                    System.exit(0);
                    return;
                } else if (frame.type == MessageType.GET_PID) {
                    String pid = java.lang.management.ManagementFactory.getRuntimeMXBean().getName().split("@")[0];
                    writeFrame(out, MessageType.GET_PID, false, pid.getBytes(StandardCharsets.UTF_8));
                    return;
                } else if (frame.type == MessageType.ARG) {
                    String val = new String(frame.payload, StandardCharsets.UTF_8);
                    if (execName == null)
                        execName = val;
                    else if (pwd == null)
                        pwd = val;
                    else
                        clientArgs.add(val);

                    if (!frame.more)
                        break; // Last argument received
                }
            }

            sessionHandler.handle(in, out, clientArgs);
        }
    }
}
