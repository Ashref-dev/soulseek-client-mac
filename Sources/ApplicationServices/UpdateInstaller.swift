import Foundation

enum UpdateInstaller {
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func prepare(staging: URL, candidate: URL, current: URL, requirement: String, helperExecutable: String = "/bin/bash") async throws {
        let nonce = UUID().uuidString
        guard let bundle = Bundle(url: candidate), let executable = bundle.executableURL else { throw UpdateError.unreadable }
        guard executable.path.hasPrefix(candidate.path + "/"), executable.path == executable.resolvingSymlinksInPath().path,
              !executable.pathComponents.contains("..") else { throw UpdateError.unreadable }
        let request = UpdateLaunchReceipt.Request(nonce: nonce, installedPath: current.resolvingSymlinksInPath().path,
                                                  version: UpdateCompatibility.releaseVersion(bundle), requirement: requirement)
        let requestURL = staging.appendingPathComponent("request.json")
        try JSONEncoder().encode(request).write(to: requestURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestURL.path)
        let previous = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Arpeggio/Previous", isDirectory: true)
        let script = helper(staging: staging, candidate: candidate, current: current,
                            executableRelative: String(executable.path.dropFirst(candidate.path.count + 1)),
                            nonce: nonce, requirement: requirement, previous: previous,
                            oldPID: ProcessInfo.processInfo.processIdentifier)
        let helperURL = staging.appendingPathComponent("helper.sh")
        try Data(script.utf8).write(to: helperURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)
        let logURL = staging.appendingPathComponent("helper.log")
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw UpdateError.helperFailed }
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helperExecutable); process.arguments = [helperURL.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = log; process.standardError = log
        do { try process.run() } catch { throw UpdateError.helperFailed }
        let deadline = Date().addingTimeInterval(5)
        do {
            while !FileManager.default.fileExists(atPath: staging.appendingPathComponent("ready").path) {
                guard process.isRunning, Date() < deadline else { throw UpdateError.helperFailed }
                try await Task.sleep(for: .milliseconds(25))
            }
            try UpdateLaunchReceipt.requirePrivate(staging.appendingPathComponent("ready"), directory: false)
        } catch { process.terminate(); throw error }
    }

    // The helper owns the entire transaction after readiness; app shutdown must not terminate it.
    static func helper(staging: URL, candidate: URL, current: URL, executableRelative: String, nonce: String,
                       requirement: String, previous: URL, oldPID: Int32,
                       verifier: String = "/usr/bin/codesign", receiptSeconds: Int = 30, rollbackLauncher: String = "/usr/bin/open",
                       archiver: String = "/usr/bin/ditto", mover: String = "/bin/mv") -> String {
        """
        #!/bin/bash
        set -eu
        umask 077
        root=\(quote(staging.path))
        candidate=\(quote(candidate.path))
        current=\(quote(current.path))
        previous=\(quote(previous.path))
        nonce=\(quote(nonce))
        requirement=\(quote(requirement))
        old="$root/previous.app"
        child=''
        swapped=0
        committed=0
        operation=initializing
        exec > >(/usr/bin/head -c 131072 > "$root/helper.log"; /bin/cat >/dev/null) 2>&1
        logger=$!
        finish_log() { exec >/dev/null 2>&1; wait "$logger" || true; }
        bounded() {
          "$@" & local pid=$! i=0
          while /bin/kill -0 "$pid" 2>/dev/null; do
            i=$((i+1)); if [ "$i" -ge 100 ]; then /bin/kill -9 "$pid" 2>/dev/null || true; wait "$pid" || true; return 1; fi
            /bin/sleep 0.1
          done
          wait "$pid"
        }
        verify() { bounded \(quote(verifier)) --verify --deep --strict -R "=$requirement" "$1"; }
        rollback() {
          code=$?
          trap - EXIT HUP INT TERM
          printf 'operation-failed=%s exit=%s\\n' "$operation" "$code"
          printf '%s\\n' "$operation" > "$root/failure-step"
          if [ "$committed" -eq 0 ] && [ -d "$old" ]; then
            if [ -n "$child" ]; then
              /bin/kill "$child" 2>/dev/null || true
              i=0
              while /bin/kill -0 "$child" 2>/dev/null; do
                i=$((i+1)); if [ "$i" -ge 20 ]; then /bin/kill -9 "$child" 2>/dev/null || true; break; fi
                /bin/sleep 0.1
              done
              wait "$child" 2>/dev/null || true
            fi
            if [ "$swapped" -eq 1 ] && [ -e "$current" ]; then
              if [ -e "$root/rejected.app" ] || ! \(quote(mover)) "$current" "$root/rejected.app"; then
                printf 'rollback-displace-failed\\n' > "$root/failure-step"
                printf 'rollback-incomplete\\n' > "$root/result"
                finish_log; exit 1
              fi
            fi
            if [ -e "$current" ] || ! \(quote(mover)) "$old" "$current"; then
              printf 'rollback-restore-failed\\n' > "$root/failure-step"
              printf 'rollback-incomplete\\n' > "$root/result"
              finish_log; exit 1
            fi
            if ! bounded \(quote(verifier)) --verify --deep --strict "$current"; then
              printf 'rollback-verify-failed\\n' > "$root/failure-step"
              printf 'rollback-incomplete\\n' > "$root/result"
              finish_log; exit 1
            fi
            printf 'rolled-back\\n' > "$root/result"
            if ! bounded \(quote(rollbackLauncher)) "$current"; then
              printf 'rollback-launch-failed\\n' > "$root/failure-step"
              printf 'rolled-back-launch-failed\\n' > "$root/result"
            fi
          elif [ "$committed" -eq 0 ]; then printf 'failed-before-swap\\n' > "$root/result"; fi
          finish_log
          exit "$code"
        }
        trap rollback EXIT HUP INT TERM
        operation=verify-old
        bounded \(quote(verifier)) --verify --deep --strict "$current"
        operation=verify-candidate
        verify "$candidate"
        printf ready > "$root/ready"
        i=0
        while [ \(oldPID) -gt 0 ] && /bin/kill -0 \(oldPID) 2>/dev/null; do
          i=$((i+1)); [ "$i" -lt 3000 ] || exit 1
          /bin/sleep 0.1
        done
        verify "$candidate"
        operation=swap-old
        \(quote(mover)) "$current" "$old"
        operation=swap-new
        \(quote(mover)) "$candidate" "$current"
        swapped=1
        operation=verify-installed
        verify "$current"
        operation=launch
        "$current"/\(quote(executableRelative)) --arpeggio-update-receipt "$root" "$nonce" > >(/usr/bin/head -c 131072 > "$root/launch.log"; /bin/cat >/dev/null) 2>&1 &
        child=$!
        operation=startup-receipt
        i=0
        while [ ! -f "$root/receipt" ]; do
          /bin/kill -0 "$child" 2>/dev/null || exit 1
          i=$((i+1)); [ "$i" -lt \(receiptSeconds * 10) ] || exit 1
          /bin/sleep 0.1
        done
        [ ! -L "$root/receipt" ] && [ "$(/bin/cat "$root/receipt")" = "$nonce" ] || exit 1
        committed=1
        trap - EXIT HUP INT TERM
        printf 'confirmed-archival-pending\\n' > "$root/result"
        archived=0
        operation=archive-old
        if [ ! -L "$previous" ] && /bin/mkdir -p "$previous" && /bin/chmod 700 "$previous"; then
          destination="$previous/$(/usr/bin/basename "$root").app"
          if [ ! -e "$destination" ] && bounded \(quote(archiver)) "$old" "$destination" && bounded \(quote(verifier)) --verify --deep --strict "$destination"; then
            /bin/rm -rf "$old"
            printf 'confirmed-archived\\n' > "$root/result"
            archived=1
          fi
        fi
        if [ "$archived" -eq 0 ]; then
          printf 'archive-old-failed\\n' > "$root/failure-step"
          printf 'confirmed-local-backup\\n' > "$root/result"
        fi
        finish_log
        """
    }
}
