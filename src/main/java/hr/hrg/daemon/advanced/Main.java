package hr.hrg.daemon.advanced;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Executors;

public class Main {
    static final Path SOCKET_PATH = Path.of(System.getProperty("daemon.sock",
            System.getProperty("os.name").startsWith("Windows") ? "daemon.sock" : "/tmp/java-daemon.sock"));

    public static void main(String[] args) throws IOException {
        new Protocol.DaemonServer(
                SOCKET_PATH,
                Executors.newVirtualThreadPerTaskExecutor(),
                Main::handleAdvancedSession,
                Main::onRestart).run();
    }

    private static void onRestart() {
        System.out.println("Shutdown request received. Stopping daemon...");
    }

    private static void handleAdvancedSession(InputStream in, OutputStream out, List<String> args, Map<String, String> env) throws IOException {
        // 1. Business Logic Phase: Echo arguments in Uppercase
        for (String arg : args) {
            String reply = arg.toUpperCase() + "\n";
            Protocol.writeFrame(out, Protocol.MessageType.DATA, true, reply.getBytes(StandardCharsets.UTF_8));
        }

        // 2. Persistent Piping Phase: Handle Stdin (Bi-directional)
        while (true) {
            Protocol.Frame frame = Protocol.readFrame(in);
            if (frame == null)
                break;

            if (frame.type == Protocol.MessageType.DATA) {
                // Echo stdin back for demo purposes
                String received = new String(frame.payload, StandardCharsets.UTF_8);
                String uppercased = received.toUpperCase();
                Protocol.writeFrame(out, Protocol.MessageType.DATA, true, uppercased.getBytes(StandardCharsets.UTF_8));
                out.flush();
            } else if (frame.type == Protocol.MessageType.EXIT_CODE) {
                break; // Client finished
            } else if (frame.type == Protocol.MessageType.CANCEL) {
                System.out.println("Graceful Abort: Client received interrupt signal. Stop current task.");
                break;
            }
        }

        // 3. Finalization
        byte[] exitPayload = new byte[4];
        exitPayload[3] = 0;
        Protocol.writeFrame(out, Protocol.MessageType.EXIT_CODE, false, exitPayload);
        out.flush();
    }
}
