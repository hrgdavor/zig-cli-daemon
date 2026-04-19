package hr.hrg.daemon.simple;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.Executors;

public class Main {
    static final Path SOCKET_PATH = Path.of(System.getProperty("daemon.sock",
            System.getProperty("os.name").startsWith("Windows") ? "daemon.sock" : "/tmp/java-daemon.sock"));

    public static void main(String[] args) throws IOException {
        new Protocol.DaemonServer(
                SOCKET_PATH,
                Executors.newVirtualThreadPerTaskExecutor(),
                Main::handleSimpleSession).run();
    }

    private static void handleSimpleSession(InputStream in, OutputStream out) {
        try {
            // 1. Read Metadata Block Length prefix
            byte[] lenBuf = new byte[Protocol.METADATA_LENGTH_SIZE];
            int bytesRead = in.read(lenBuf);
            if (bytesRead != Protocol.METADATA_LENGTH_SIZE)
                return;

            int len = ((lenBuf[0] & 0xFF) << 24) | ((lenBuf[1] & 0xFF) << 16) | ((lenBuf[2] & 0xFF) << 8)
                    | (lenBuf[3] & 0xFF);

            if (len < 0 || len > Protocol.MAX_METADATA_SIZE) {
                throw new IOException("Invalid metadata length: " + len);
            }

            // 2. Read Metadata Block
            byte[] meta = new byte[len];
            int read = 0;
            while (read < len) {
                int n = in.read(meta, read, len - read);
                if (n == -1)
                    break;
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
                if (n == -1)
                    break;
                // Simple transformation for demonstration
                for (int i = 0; i < n; i++) {
                    buf[i] = (byte) Character.toUpperCase((char) buf[i]);
                }
                out.write(buf, 0, n);
                out.flush();
            }
        } catch (Exception e) {
            e.printStackTrace();
        }
    }
}
