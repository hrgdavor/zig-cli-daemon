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
import java.util.function.BiConsumer;

public class Protocol {
    /** Size of the metadata block length prefix in bytes (u32 big endian). */
    public static final int METADATA_LENGTH_SIZE = 4;

    /** Maximum allowed metadata block size to prevent OOM. */
    public static final int MAX_METADATA_SIZE = 1024 * 1024; // 1 MB

    public static class DaemonServer {
        private final Path socketPath;
        private final Executor executor;
        private final BiConsumer<InputStream, OutputStream> sessionHandler;

        public DaemonServer(Path socketPath, Executor executor, BiConsumer<InputStream, OutputStream> sessionHandler) {
            this.socketPath = socketPath;
            this.executor = executor;
            this.sessionHandler = sessionHandler;
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
                System.out.println(
                        "Simple Daemon started on " + socketPath + " using " + System.getProperty("java.runtime.name"));

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
                                sessionHandler.accept(in, out);
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
    }
}
