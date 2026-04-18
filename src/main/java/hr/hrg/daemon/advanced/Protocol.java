package hr.hrg.daemon.advanced;

import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

public class Protocol {

    public enum MessageType {
        EXIT_CODE(), // 0
        STDOUT(), // 1
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
                case 1 -> STDOUT;
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
}
