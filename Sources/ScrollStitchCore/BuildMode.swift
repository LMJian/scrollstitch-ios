/// Capabilities are fixed by the target, never by launch arguments or preferences.
public enum BuildMode {
    public static var operatorToolsEnabled: Bool {
#if SCROLLSTITCH_STORE
        false
#else
        true
#endif
    }
    public static var captureCreationEnabled: Bool {
        true
    }
}
