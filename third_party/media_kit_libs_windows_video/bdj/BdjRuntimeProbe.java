/** Verifies the private JVM's version and architecture without loading a user's disc. */
public final class BdjRuntimeProbe {
    public static void main(String[] args) throws Exception {
        if (!"1.8".equals(System.getProperty("java.specification.version"))) {
            throw new IllegalStateException("BD-J component requires Java 8");
        }
        if (!"64".equals(System.getProperty("sun.arch.data.model"))) {
            throw new IllegalStateException("BD-J component requires a 64-bit JVM");
        }
        System.out.println("BDJ_RUNTIME_OK " + System.getProperty("java.runtime.version"));
    }
}
