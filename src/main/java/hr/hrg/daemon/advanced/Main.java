package hr.hrg.daemon.advanced;

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
            System.out.println("Advanced Daemon started on " + SOCKET_PATH + " using " + System.getProperty("java.runtime.name") + " " + System.getProperty("java.runtime.version"));

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

                    handleClient(in, out);
                } catch (Exception e) {
                    System.err.println("Error handling client: " + e.getMessage());
                }
            }
        }
    }

    private static void handleClient(InputStream in, OutputStream out) throws IOException {
        List<String> clientArgs = new ArrayList<>();
        String pwd = null;
        String execName = null;

        while (true) {
            Protocol.Frame frame = Protocol.readFrame(in);
            if (frame == null)
                break;

            if (frame.type == Protocol.MessageType.EXIT_CODE) {
                System.out.println("Shutdown request received. Stopping daemon...");
                Files.deleteIfExists(SOCKET_PATH);
                System.exit(0);
            } else if (frame.type == Protocol.MessageType.GET_PID) {
                String pid = java.lang.management.ManagementFactory.getRuntimeMXBean().getName().split("@")[0];
                Protocol.writeFrame(out, Protocol.MessageType.GET_PID, false, pid.getBytes(StandardCharsets.UTF_8));
                return;
            } else if (frame.type == Protocol.MessageType.ARG) {
                String val = new String(frame.payload, StandardCharsets.UTF_8);
                if (execName == null)
                    execName = val;
                else if (pwd == null)
                    pwd = val;
                else
                    clientArgs.add(val);
            }

            if (!frame.more && frame.type == Protocol.MessageType.ARG)
                break;
        }

        for (String arg : clientArgs) {
            String reply = arg.toUpperCase() + "\n";
            Protocol.writeFrame(out, Protocol.MessageType.STDOUT, true, reply.getBytes(StandardCharsets.UTF_8));
        }

        byte[] exitPayload = new byte[4];
        exitPayload[3] = 0;
        Protocol.writeFrame(out, Protocol.MessageType.EXIT_CODE, false, exitPayload);

        out.flush();
    }
}
