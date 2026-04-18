package hr.hrg.daemon.simple;

public class Protocol {
    /** Size of the metadata block length prefix in bytes (u32 big endian). */
    public static final int METADATA_LENGTH_SIZE = 4;
    
    /** Maximum allowed metadata block size to prevent OOM. */
    public static final int MAX_METADATA_SIZE = 1024 * 1024; // 1 MB
}
