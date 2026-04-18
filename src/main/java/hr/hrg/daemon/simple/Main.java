package hr.hrg.daemon.simple;

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

public class Main {
    static final Path SOCKET_PATH = Path.of(System.getProperty("daemon.sock", 
        System.getProperty("os.name").startsWith("Windows") ? "daemon.sock" : "/tmp/java-daemon.sock"));

    public static void main(String[] args) throws IOException {
        Path parent = SOCKET_PATH.getParent();
        if (parent != null && !Files.exists(parent)) {
            Files.createDirectories(parent);
        }

        if (Files.exists(SOCKET_PATH)) {
            Files.delete(SOCKET_PATH);
        }

        UnixDomainSocketAddress address = UnixDomainSocketAddress.of(SOCKET_PATH);

        try (ServerSocketChannel server = ServerSocketChannel.open(StandardProtocolFamily.UNIX)) {
            server.bind(address);
            System.out.println("Simple Daemon started on " + SOCKET_PATH + " using " + System.getProperty("java.runtime.name") + " " + System.getProperty("java.runtime.version"));

            if (!System.getProperty("os.name").startsWith("Windows")) {
                try {
                    Files.setPosixFilePermissions(SOCKET_PATH, java.nio.file.attribute.PosixFilePermissions.fromString("rwx------"));
                } catch (UnsupportedOperationException e) {
                    System.err.println("Warning: Filesystem does not support POSIX permissions.");
                }
            }

            while (true) {
                try (SocketChannel socket = server.accept();
                        InputStream in = Channels.newInputStream(socket);
                        OutputStream out = Channels.newOutputStream(socket)) {

                    handleSimpleClient(in, out);
                } catch (Exception e) {
                    System.err.println("Error handling client: " + e.getMessage());
                }
            }
        }
    }

    private static void handleSimpleClient(InputStream in, OutputStream out) throws IOException {
        // 1. Read Metadata Block Length prefix
        byte[] lenBuf = new byte[Protocol.METADATA_LENGTH_SIZE];
        int bytesRead = in.read(lenBuf);
        if (bytesRead != Protocol.METADATA_LENGTH_SIZE) return;
        
        int len = ((lenBuf[0] & 0xFF) << 24) | ((lenBuf[1] & 0xFF) << 16) | ((lenBuf[2] & 0xFF) << 8) | (lenBuf[3] & 0xFF);
        
        if (len < 0 || len > Protocol.MAX_METADATA_SIZE) {
            throw new IOException("Invalid metadata length: " + len);
        }

        // 2. Read Metadata Block
        byte[] meta = new byte[len];
        int read = 0;
        while (read < len) {
            int n = in.read(meta, read, len - read);
            if (n == -1) break;
            read += n;
        }

        // Parse null-terminated strings for demonstration
        List<String> metaStrings = new ArrayList<>();
        int start = 0;
        for (int i = 0; i < len; i++) {
            if (meta[i] == 0) {
                if (i > start) {
                    metaStrings.add(new String(meta, start, i - start, StandardCharsets.UTF_8));
                }
                start = i + 1;
            }
        }
        System.out.println("Simple Mode Request: " + metaStrings);

        // 3. Raw Echo Pipe
        byte[] buf = new byte[4096];
        while (true) {
            int n = in.read(buf);
            if (n == -1) break;
            // Simple transformation for demonstration
            for (int i = 0; i < n; i++) {
                buf[i] = (byte) Character.toUpperCase((char) buf[i]);
            }
            out.write(buf, 0, n);
            out.flush();
        }
    }
}
