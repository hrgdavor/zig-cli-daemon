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
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Executor;
import java.util.concurrent.Semaphore;

public class Protocol {

    public enum MessageType {
        EXIT_CODE(), // 0
        DATA(), // 1
        STDERR(), // 2
        ARG(), // 3
        ENV_VAR(), // 4
        STREAM_INIT(), // 5
        STREAM_DATA(), // 6
        JSONRPC(), // 7
        GET_PID(),// 8
        CANCEL(),// 9
        ;

        public int getValue() {
            return ordinal();
        }

        public static MessageType fromValue(int value) {
            return switch (value) {
                case 0 -> EXIT_CODE;
                case 1 -> DATA;
                case 2 -> STDERR;
                case 3 -> ARG;
                case 4 -> ENV_VAR;
                case 5 -> STREAM_INIT;
                case 6 -> STREAM_DATA;
                case 7 -> JSONRPC;
                case 8 -> GET_PID;
                case 9 -> CANCEL;
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
        void handle(InputStream in, OutputStream out, List<String> args, Map<String, String> env) throws IOException;
    }

    public static class DaemonServer {
        private final Path socketPath;
        private final Executor executor;
        private final SessionHandler sessionHandler;
        private final Runnable restartHandler;
        private volatile boolean running = true;
        private final Semaphore connectionSemaphore;
        private ServerSocketChannel server;

        public DaemonServer(Path socketPath, Executor executor, SessionHandler sessionHandler,
                Runnable restartHandler) {
            this(socketPath, executor, sessionHandler, restartHandler, 64);
        }

        public DaemonServer(Path socketPath, Executor executor, SessionHandler sessionHandler,
                Runnable restartHandler, int maxConnections) {
            this.socketPath = socketPath;
            this.executor = executor;
            this.sessionHandler = sessionHandler;
            this.restartHandler = restartHandler;
            this.connectionSemaphore = new Semaphore(maxConnections);
        }

        public void stop() {
            running = false;
            try {
                if (server != null) {
                    server.close();
                }
            } catch (IOException e) {
                // Ignore
            }
        }

        public void run() throws IOException {
            Path parent = socketPath.getParent();
            if (parent != null && !Files.exists(parent)) {
                Files.createDirectories(parent);
            }

            if (Files.exists(socketPath)) {
                Files.delete(socketPath);
            }

            // Cleanup PID file on exit
            Runtime.getRuntime().addShutdownHook(new Thread(() -> {
                try {
                    Files.deleteIfExists(socketPath);
                    Files.deleteIfExists(Path.of(socketPath.toString() + ".pid"));
                } catch (IOException e) {
                    // Ignore
                }
            }));

            UnixDomainSocketAddress address = UnixDomainSocketAddress.of(socketPath);

            try (ServerSocketChannel s = ServerSocketChannel.open(StandardProtocolFamily.UNIX)) {
                this.server = s;
                server.bind(address);
                System.out.println("Advanced Daemon started on " + socketPath + " using "
                        + System.getProperty("java.runtime.name"));

                // Write PID file
                try {
                    Path pidPath = Path.of(socketPath.toString() + ".pid");
                    Files.writeString(pidPath, String.valueOf(ProcessHandle.current().pid()));
                } catch (IOException e) {
                    System.err.println("Warning: Could not write PID file: " + e.getMessage());
                }

                if (!System.getProperty("os.name").startsWith("Windows")) {
                    try {
                        Files.setPosixFilePermissions(socketPath,
                                java.nio.file.attribute.PosixFilePermissions.fromString("rwx------"));
                    } catch (UnsupportedOperationException e) {
                        System.err.println("Warning: Filesystem does not support POSIX permissions.");
                    }
                }

                while (running) {
                    try {
                        SocketChannel socket = server.accept();
                        if (!connectionSemaphore.tryAcquire()) {
                            System.err.println("Maximum connections reached. Rejecting client.");
                            socket.close();
                            continue;
                        }
                        executor.execute(() -> {
                            try (socket;
                                    InputStream in = Channels.newInputStream(socket);
                                    OutputStream out = Channels.newOutputStream(socket)) {
                                handleProtocol(in, out);
                            } catch (Exception e) {
                                if (running) {
                                    System.err.println("Error handling client: " + e.getMessage());
                                }
                            } finally {
                                connectionSemaphore.release();
                            }
                        });
                    } catch (Exception i) {
                        if (running) {
                            System.err.println("Error accepting client: " + i.getMessage());
                        }
                    }
                }
            } finally {
                System.out.println("Server accept loop finished.");
            }
        }

        private void handleProtocol(InputStream in, OutputStream out) throws IOException {
            List<String> clientArgs = new ArrayList<>();
            Map<String, String> env = new HashMap<>();
            String pwd = null;
            String execName = null;

            while (true) {
                Frame frame = readFrame(in);
                if (frame == null)
                    return;

                if (frame.type == MessageType.EXIT_CODE) {
                    restartHandler.run();
                    stop();
                    return;
                } else if (frame.type == MessageType.GET_PID) {
                    long pid = ProcessHandle.current().pid();
                    byte[] pidBuf = new byte[8];
                    pidBuf[0] = (byte) (pid >> 56);
                    pidBuf[1] = (byte) (pid >> 48);
                    pidBuf[2] = (byte) (pid >> 40);
                    pidBuf[3] = (byte) (pid >> 32);
                    pidBuf[4] = (byte) (pid >> 24);
                    pidBuf[5] = (byte) (pid >> 16);
                    pidBuf[6] = (byte) (pid >> 8);
                    pidBuf[7] = (byte) (pid);
                    writeFrame(out, MessageType.GET_PID, false, pidBuf);
                    return;
                } else if (frame.type == MessageType.ENV_VAR) {
                    String val = new String(frame.payload, StandardCharsets.UTF_8);
                    int eqIdx = val.indexOf('=');
                    if (eqIdx != -1) {
                        env.put(val.substring(0, eqIdx), val.substring(eqIdx + 1));
                    }
                } else if (frame.type == MessageType.ARG) {
                    String val = new String(frame.payload, StandardCharsets.UTF_8);
                    if (execName == null)
                        execName = val;
                    else if (pwd == null)
                        pwd = val;
                    else
                        clientArgs.add(val);
                }

                // Any frame with !more signals end of metadata/arguments
                if (!frame.more) {
                    break;
                }
            }

            sessionHandler.handle(in, out, clientArgs, env);
        }
    }
}
