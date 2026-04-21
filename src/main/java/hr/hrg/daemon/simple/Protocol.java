package hr.hrg.daemon.simple;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.channels.Channels;
import java.nio.channels.ServerSocketChannel;
import java.nio.channels.SocketChannel;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.Executor;
import java.util.concurrent.Semaphore;
import java.util.function.BiConsumer;

/**
 * Simple Protocol implementation for the CLI Daemon.
 * 
 * NOTE: Simple Mode is a raw bidirectional pipe. It does not support:
 * <ul>
 *   <li>Separate stderr stream (all daemon output goes to the CLI's stdout)</li>
 *   <li>Exit code propagation (CLI will always exit 0 if communication succeeds)</li>
 * </ul>
 * For these features, use the Advanced Protocol.
 */
public class Protocol {
    /** Size of the metadata block length prefix in bytes (u32 big endian). */
    public static final int METADATA_LENGTH_SIZE = 4;

    /** Maximum allowed metadata block size to prevent OOM. */
    public static final int MAX_METADATA_SIZE = 1024 * 1024; // 1 MB

    public static class DaemonServer {
        private final Path socketPath;
        private final Executor executor;
        private final BiConsumer<InputStream, OutputStream> sessionHandler;
        private volatile boolean running = true;
        private final Semaphore connectionSemaphore;
        private ServerSocketChannel server;

        public DaemonServer(Path socketPath, Executor executor, BiConsumer<InputStream, OutputStream> sessionHandler) {
            this(socketPath, executor, sessionHandler, 64);
        }

        public DaemonServer(Path socketPath, Executor executor, BiConsumer<InputStream, OutputStream> sessionHandler,
                int maxConnections) {
            this.socketPath = socketPath;
            this.executor = executor;
            this.sessionHandler = sessionHandler;
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
                System.out.println(
                        "Simple Daemon started on " + socketPath + " using " + System.getProperty("java.runtime.name"));

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
                            System.err.println("Maximum connections reached. Rejecting client (Simple Mode).");
                            socket.close();
                            continue;
                        }
                        executor.execute(() -> {
                            try (socket;
                                    InputStream in = Channels.newInputStream(socket);
                                    OutputStream out = Channels.newOutputStream(socket)) {
                                sessionHandler.accept(in, out);
                            } catch (Exception e) {
                                if (running) {
                                    System.err.println("Error handling client (Simple Mode): " + e.getMessage());
                                }
                            } finally {
                                connectionSemaphore.release();
                            }
                        });
                    } catch (Exception e) {
                        if (running) {
                            System.err.println("Error accepting client (Simple Mode): " + e.getMessage());
                        }
                    }
                }
            } finally {
                System.out.println("Simple Server accept loop finished.");
            }
        }
    }
}
