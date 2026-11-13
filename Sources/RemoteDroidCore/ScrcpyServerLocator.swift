import Foundation

public enum ScrcpyServer {
    public static let version = "5.0.1"
    public static let fileName = "scrcpy-server-v5.0.1"
    public static let remotePath = "/data/local/tmp/scrcpy-server.jar"

    public static func locate() -> URL? {
        var candidates: [URL] = []

        if let override = ProcessInfo.processInfo.environment["UU_SCRCPY_SERVER"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let bundled = Bundle.main.url(forResource: fileName, withExtension: nil) {
            candidates.append(bundled)
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent(fileName))
        }
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources")
                .appendingPathComponent(fileName)
        )
        candidates.append(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources")
                .appendingPathComponent(fileName)
        )

        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
