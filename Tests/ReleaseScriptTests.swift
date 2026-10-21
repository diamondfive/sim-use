// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@Suite("Release Script Tests")
struct ReleaseScriptTests {
    @Test("notarized formulas preserve the upstream signature")
    func notarizedFormula() async throws {
        let result = try await generateFormula(notarized: true)
        #expect(result.exitCode == 0, "\(result.output)")
        #expect(!result.output.contains("def post_install"))
        #expect(!result.output.contains("codesign"))
        #expect(result.output.contains("SimUse_AndroidBackend.bundle"))
        #expect(!result.output.contains("\"Frameworks\""))
    }

    @Test("legacy formulas retain ad-hoc signing")
    func legacyFormula() async throws {
        let result = try await generateFormula(notarized: false)
        #expect(result.exitCode == 0, "\(result.output)")
        #expect(result.output.contains("def post_install"))
        #expect(result.output.contains("\"--sign\", \"-\""))
    }

    @Test("the release driver forwards the notarized mode", arguments: [true, false])
    func releaseDriver(notarized: Bool) async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try copyScript("local-release.sh", to: root)
        for directory in ["build_products/XCFrameworks", "build_products/PrivateHeaders"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try write("versionName = \"0.16.0\"\n", to: "bridge/app/build.gradle.kts", in: root)
        try write("apk", to: "Sources/AndroidBackend/Resources/sim-use-device-bridge.apk", in: root)
        try write("viewer", to: "Sources/SimUse/Resources/viewer/index.html", in: root)
        try write("#!/bin/bash\nexit 0\n", to: "build_products/sim-use", in: root, executable: true)
        for script in ["check-protocol-parity.sh", "build.sh"] {
            try write("#!/bin/bash\nexit 0\n", to: "scripts/\(script)", in: root, executable: true)
        }
        try write("#!/bin/bash\nprintf 'status: Accepted\\n'\n", to: "bin/xcrun", in: root, executable: true)
        try write(#"""
        #!/bin/bash
        set -euo pipefail
        operation="$1"; shift
        stage=""; archive=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --stage-dir) stage="$2"; shift 2 ;;
                --archive) archive="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        case "$operation" in
            stage-build-output) mkdir -p "$stage"; printf binary > "$stage/sim-use" ;;
            create-*) printf archive > "$archive" ;;
        esac
        """#, to: "scripts/release-artifacts.sh", in: root, executable: true)
        try write(#"""
        #!/bin/bash
        printf '%s\n' "$@" > "$FIXTURE_ROOT/generator-args"
        exit 73
        """#, to: "scripts/generate-homebrew-formula.sh", in: root, executable: true)

        let mode = notarized ? " --notarize --codesign-identity fixture" : ""
        let result = try await CommandRunner.run(
            "bash \(quote(root.appendingPathComponent("scripts/local-release.sh").path)) --version 0.16.0 --skip-build --skip-bridge --skip-viewer\(mode)",
            environment: fixtureEnvironment(root), allowFailure: true
        )
        #expect(result.exitCode == 73, "driver did not reach the generator: \(result.output)")
        let arguments = try String(contentsOf: root.appendingPathComponent("generator-args"), encoding: .utf8)
        #expect(arguments.split(separator: "\n").contains("--notarized") == notarized)
    }

    @Test("install verification preserves the selected signing mode", arguments: [
        (notarized: true, mutated: false, assessment: "skip"),
        (notarized: false, mutated: false, assessment: "skip"),
        (notarized: true, mutated: true, assessment: "skip"),
        (notarized: true, mutated: false, assessment: "valid-cli"),
        (notarized: true, mutated: false, assessment: "accepted"),
        (notarized: true, mutated: false, assessment: "rejected"),
    ])
    func installVerification(_ testCase: (notarized: Bool, mutated: Bool, assessment: String)) async throws {
        let notarized = testCase.notarized
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try copyScript("verify-brew-install.sh", to: root)
        try copyScript("generate-homebrew-formula.sh", to: root)
        try write("#!/bin/bash\nprintf '0.16.0\\n'\n", to: "payload/sim-use", in: root, executable: true)
        let resourcePath = notarized ? "Contents/Resources/Resources" : "Resources"
        try write("apk fixture", to: "payload/SimUse_AndroidBackend.bundle/\(resourcePath)/sim-use-device-bridge.apk", in: root)
        try write("skill fixture", to: "payload/SimUse_SimUse.bundle/Contents/Resources/skills/sim-use/SKILL.md", in: root)
        let archive = root.appendingPathComponent("fixture.tar.gz")
        _ = try await CommandRunner.run("tar -czf \(quote(archive.path)) -C \(quote(root.appendingPathComponent("payload").path)) sim-use SimUse_SimUse.bundle SimUse_AndroidBackend.bundle")
        try write(#"""
        #!/bin/bash
        set -euo pipefail
        printf '%s\n' "$*" >> "$FIXTURE_ROOT/brew-args"
        case "$1" in
            --repository) printf '%s\n' "$FIXTURE_ROOT/brew" ;;
            --cellar) printf '%s\n' "$FIXTURE_ROOT/cellar" ;;
            list) exit 1 ;;
            install)
                cp "$FIXTURE_ROOT/brew/Library/Taps/sim-use-release-test/homebrew-dryrun/Formula/sim-use-dryrun.rb" "$FIXTURE_ROOT/installed-formula.rb"
                target="$FIXTURE_ROOT/cellar/sim-use-dryrun/0.16.0/libexec"
                mkdir -p "$target"
                tar -xzf "$FIXTURE_ROOT/fixture.tar.gz" -C "$target"
                if [[ "${MUTATE_INSTALL:-0}" == "1" ]]; then
                    printf '\n# changed\n' >> "$target/sim-use"
                fi
                ;;
        esac
        """#, to: "bin/brew", in: root, executable: true)
        try write(#"""
        #!/bin/bash
        printf '%s\n' 'Authority=Developer ID Application: Fixture (GFPYJQXRSN)' 'TeamIdentifier=GFPYJQXRSN'
        """#, to: "bin/codesign", in: root, executable: true)
        try write(#"""
        #!/bin/bash
        case "$ASSESSMENT" in
            valid-cli) printf 'rejected (the code is valid but does not seem to be an app)\n' ;;
            accepted) printf 'accepted\n'; exit 0 ;;
            *) printf 'rejected\nsource=Unnotarized Developer ID\n' ;;
        esac
        exit 3
        """#, to: "bin/spctl", in: root, executable: true)
        var mode = notarized
            ? " --require-developer-id --download-url https://example.com/sim-use.tar.gz"
            : ""
        if testCase.assessment != "skip" { mode += " --require-spctl-accept" }
        var environment = fixtureEnvironment(root)
        environment["MUTATE_INSTALL"] = testCase.mutated ? "1" : "0"
        environment["ASSESSMENT"] = testCase.assessment
        let result = try await CommandRunner.run(
            "bash \(quote(root.appendingPathComponent("scripts/verify-brew-install.sh").path)) --archive \(quote(archive.path)) --version 0.16.0\(mode)",
            environment: environment, allowFailure: true
        )
        if testCase.mutated {
            #expect(result.exitCode != 0)
            #expect(result.output.contains("Installed binary differs from the notarized archive"))
        } else if testCase.assessment == "rejected" {
            #expect(result.exitCode != 0)
            #expect(result.output.contains("no ad-hoc fallback was attempted"))
        } else {
            #expect(result.exitCode == 0, "\(result.output)")
        }
        let formula = try String(contentsOf: root.appendingPathComponent("installed-formula.rb"), encoding: .utf8)
        #expect(formula.contains("class SimUseDryrun < Formula"))
        #expect(formula.contains("bin.write_exec_script"))
        #expect(!formula.contains("\"Frameworks\""))
        #expect(formula.contains("def post_install") != notarized)
        #expect(formula.contains(notarized ? "https://example.com/sim-use.tar.gz" : "file://"))
        if !notarized { #expect(formula.contains("release%20fixture%20")) }
        let commands = try String(contentsOf: root.appendingPathComponent("brew-args"), encoding: .utf8)
        #expect(commands.contains("install --formula --skip-link"))
        #expect(!commands.contains("uninstall --force"))
        if !testCase.mutated && testCase.assessment != "rejected" {
            #expect(commands.contains("test --force"))
        }
    }

    @Test("verification refuses an existing workspace without deleting it")
    func existingWorkspaceIsPreserved() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try copyScript("verify-brew-install.sh", to: root)
        try write("fixture", to: "archive.tar.gz", in: root)
        let sentinel = "brew/Library/Taps/sim-use-release-test/homebrew-dryrun/keep"
        try write("existing work", to: sentinel, in: root)
        try write(#"""
        #!/bin/bash
        case "$1" in
            --repository) printf '%s\n' "$FIXTURE_ROOT/brew" ;;
            --cellar) printf '%s\n' "$FIXTURE_ROOT/cellar" ;;
            *) exit 99 ;;
        esac
        """#, to: "bin/brew", in: root, executable: true)
        let result = try await CommandRunner.run(
            "bash \(quote(root.appendingPathComponent("scripts/verify-brew-install.sh").path)) --archive \(quote(root.appendingPathComponent("archive.tar.gz").path)) --version 0.16.0",
            environment: fixtureEnvironment(root), allowFailure: true
        )
        #expect(result.exitCode != 0)
        #expect(result.output.contains("Verification tap already exists"))
        #expect(try String(contentsOf: root.appendingPathComponent(sentinel), encoding: .utf8) == "existing work")
    }

    private func generateFormula(notarized: Bool) async throws -> (output: String, exitCode: Int32) {
        let mode = notarized ? " --notarized" : ""
        return try await CommandRunner.run(
            "bash scripts/generate-homebrew-formula.sh --formula-class SimUse --homepage https://example.com --version 0.16.0 --url https://example.com/sim-use.tar.gz --sha256 fixture\(mode)",
            allowFailure: true
        )
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("release fixture \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        return root
    }

    private func copyScript(_ name: String, to root: URL) throws {
        try write(String(contentsOfFile: "scripts/\(name)", encoding: .utf8), to: "scripts/\(name)", in: root, executable: true)
    }

    private func write(_ content: String, to path: String, in root: URL, executable: Bool = false) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    private func fixtureEnvironment(_ root: URL) -> [String: String] {
        [
            "FIXTURE_ROOT": root.path,
            "PATH": root.appendingPathComponent("bin").path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"),
            "TMPDIR": root.appendingPathComponent("tmp").path,
        ]
    }

    private func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
