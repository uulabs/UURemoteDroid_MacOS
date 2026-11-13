import Foundation

/// Builds the scrcpy server command line.
///
/// Samsung's Codec2 plugin crashes with "stack corruption detected" when the
/// `app_process` command line grows beyond roughly 255 bytes. Keep the command
/// compact by omitting options whose server defaults already match our needs:
/// `control`, `cleanup`, `video_codec`, `send_dummy_byte` and
/// `clipboard_autosync` are intentionally not passed.
public enum ScrcpyCommand {
    public static func serverCommand(
        scid: UInt32,
        configuration: StreamConfiguration,
        remotePath: String = ScrcpyServer.remotePath
    ) -> String {
        var parts = [
            "CLASSPATH=\(remotePath)",
            "app_process",
            "/",
            "com.genymobile.scrcpy.Server",
            ScrcpyServer.version,
            "scid=\(String(format: "%08x", scid))",
            "log_level=info",
            "audio=false",
            "send_device_meta=false",
            "video_bit_rate=\(configuration.bitRate)",
        ]
        if configuration.maxSize > 0 {
            parts.append("max_size=\(configuration.maxSize)")
        }
        if configuration.maxFPS > 0 {
            parts.append("max_fps=\(configuration.maxFPS)")
        }
        if configuration.keepAwake {
            parts.append("stay_awake=true")
        }
        return parts.joined(separator: " ")
    }
}
