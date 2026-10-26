import Foundation
import Darwin

/// Developer test runs must fail closed BEFORE AppEnvironment is constructed.
/// Normal launches do not change storage, defaults or product behavior.
enum TestIsolationGuard {
    static func validate() {
        let values = ProcessInfo.processInfo.environment
        guard values["OPENISLAND_TEST_DEFAULTS"] != nil || values["OPENISLAND_TEST_SUPPORT"] != nil
                || values["OPENISLAND_PERFORMANCE_SCRIPT"] == "1" else { return }
        func canonical(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }
        guard let rawRoot = values["OPENISLAND_TEST_ROOT"], rawRoot.hasPrefix("/"),
              let support = values["OPENISLAND_TEST_SUPPORT"], support.hasPrefix("/"),
              let log = values["OPENISLAND_DIAGNOSTICS"], log.hasPrefix("/"),
              let suite = values["OPENISLAND_TEST_DEFAULTS"], suite.hasPrefix("io.github.openisland.validation."),
              canonical(rawRoot) != "/", canonical(rawRoot) != NSHomeDirectory(),
              !canonical(rawRoot).hasPrefix(NSHomeDirectory() + "/Library/"),
              canonical(support).hasPrefix(canonical(rawRoot) + "/"),
              canonical(log).hasPrefix(canonical(rawRoot) + "/"),
              let marker = try? String(contentsOfFile: canonical(rawRoot) + "/.openisland-test-root", encoding: .utf8),
              marker == "OpenIsland isolated fixture\n",
              let attributes = try? FileManager.default.attributesOfItem(atPath: canonical(rawRoot)),
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            fputs("REFUSED: missing or unsafe OpenIsland test root/defaults/support/diagnostics\n", stderr)
            exit(78)
        }
    }
}
