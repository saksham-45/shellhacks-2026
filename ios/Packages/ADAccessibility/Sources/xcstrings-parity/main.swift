// CLI: swift run xcstrings-parity [--languages es,en,ht] [--allow-needs-review] <file.xcstrings>...
// Exit 0 when every catalog is complete; 1 with a report otherwise; 2 on usage/IO errors
// (including an empty language list or an empty entry such as "es,,ht").
import ADAccessibility
import Foundation

func usageError(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    FileHandle.standardError.write(Data("usage: xcstrings-parity [--languages es,en,ht] [--allow-needs-review] <file.xcstrings>...\n".utf8))
    exit(2)
}

var languages = ["es", "en", "ht"]
var states: Set<String> = ["translated"]
var files: [String] = []
var args = CommandLine.arguments.dropFirst()
while let a = args.popFirst() {
    switch a {
    case "--languages":
        guard let v = args.popFirst() else { usageError("--languages needs a value") }
        guard let parsed = StringCatalogParity.parseLanguages(v) else {
            usageError("--languages must be a comma-separated list with no empty entries, got '\(v)'")
        }
        languages = parsed
    case "--allow-needs-review":
        states.insert("needs_review")
    default:
        files.append(a)
    }
}
guard !files.isEmpty else { usageError("no catalog files given") }
let checker = StringCatalogParity(requiredLanguages: languages, acceptedStates: states)
var failed = false
for f in files {
    do {
        let issues = try checker.check(fileAt: URL(fileURLWithPath: f))
        if issues.isEmpty {
            print("OK   \(f) (\(languages.joined(separator: "/")))")
        } else {
            failed = true
            print("FAIL \(f): \(issues.count) issue(s)")
            for i in issues { print("  " + i.description) }
        }
    } catch {
        FileHandle.standardError.write(Data("ERROR \(f): \(error)\n".utf8))
        exit(2)
    }
}
exit(failed ? 1 : 0)
