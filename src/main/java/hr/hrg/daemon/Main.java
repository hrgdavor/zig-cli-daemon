package hr.hrg.daemon;

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
    // Shared reference to the socket path
    static final Path SOCKET_PATH = Path.of(System.getProperty("daemon.sock", "/tmp/java-daemon.sock"));

    public static void main(String[] args) throws IOException {
        // Ensure parent directory exists for the socket
        Path parent = SOCKET_PATH.getParent();
        if (parent != null && !Files.exists(parent)) {
            Files.createDirectories(parent);
        }

        // NATIVE UDS SEMANTICS:
        // In POSIX/AF_UNIX, the socket file survives process termination.
        // We must manually delete ("unlink") it before binding, otherwise 
        // ServerSocketChannel.bind will throw java.net.BindException: Address already in use.
        if (Files.exists(SOCKET_PATH)) {
            Files.delete(SOCKET_PATH);
        }

        UnixDomainSocketAddress address = UnixDomainSocketAddress.of(SOCKET_PATH);

        // Use Java 16+ native ServerSocketChannel for AF_UNIX
        try (ServerSocketChannel server = ServerSocketChannel.open(StandardProtocolFamily.UNIX)) {
            server.bind(address);
            System.out.println("Daemon started on " + SOCKET_PATH);

            while (true) {
                // Accept new bridge connections
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

        // 1. Read Frames
        while (true) {
            Protocol.Frame frame = Protocol.readFrame(in);
            if (frame == null)
                break;

            if (frame.type == Protocol.MessageType.EXIT_CODE) {
                // REFERENCE IMPLEMENTATION: Early Unlink Strategy
                // By deleting the socket file *before* process exit, we signal to the 
                // Zig bridge that this daemon is now offline. 
                // This is functionally equivalent to POSIX unlink().
                System.out.println("Shutdown request received. Stopping daemon...");
                Files.deleteIfExists(SOCKET_PATH);
                System.exit(0);
            } else if (frame.type == Protocol.MessageType.GET_PID) {
                // REFERENCE IMPLEMENTATION: Process Identification
                // Returns the PID as a string in a Type 8 frame.
                String pid = java.lang.management.ManagementFactory.getRuntimeMXBean().getName().split("@")[0];
                Protocol.writeFrame(out, Protocol.MessageType.GET_PID, false, pid.getBytes(StandardCharsets.UTF_8));
                return; // End session after PID request
            } else if (frame.type == Protocol.MessageType.ARG) {
                String val = new String(frame.payload, StandardCharsets.UTF_8);
                if (execName == null)
                    execName = val;
                else if (pwd == null)
                    pwd = val;
                else
                    clientArgs.add(val);
            }

            // The last argument frame should have more=false for a standard request
            if (!frame.more && frame.type == Protocol.MessageType.ARG)
                break;
        }

        // 2. Reply: Arguments uppercased
        for (String arg : clientArgs) {
            String reply = arg.toUpperCase() + "\n";
            Protocol.writeFrame(out, Protocol.MessageType.STDOUT, true, reply.getBytes(StandardCharsets.UTF_8));
        }

        // 3. Send Exit Code 0 TO client
        byte[] exitPayload = new byte[4];
        exitPayload[0] = 0;
        exitPayload[1] = 0;
        exitPayload[2] = 0;
        exitPayload[3] = 0;
        Protocol.writeFrame(out, Protocol.MessageType.EXIT_CODE, false, exitPayload);

        out.flush();
    }
}
