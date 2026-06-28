import Foundation

// Pure diff-composition policy: given a changed file and the way it changed,
// decide which `git diff` invocations produce its patch and assemble the titled
// sections. The two effects it needs — running git and probing the filesystem —
// arrive as closures, so the whole policy is testable with a fake git that
// returns canned output. No Process, no real repository required.
enum GitDiffComposer {
    /// The effects the composer depends on. Inject real implementations in the
    /// app; inject fakes in tests.
    struct Environment {
        /// Runs `git <arguments>` and returns trimmed stdout, or throws on failure.
        var runGit: (_ arguments: [String]) throws -> String
        /// True if `absolutePath` exists and is a directory.
        var isDirectory: (_ absolutePath: String) -> Bool
    }

    /// The result of composing a diff: either patch sections to render, or a
    /// human-readable note explaining why there is no patch.
    enum Result: Equatable {
        case sections([GitDiffSection])
        case note(String)
    }

    static func compose(for file: GitChangedFile, repoRoot: String, env: Environment) throws -> Result {
        if file.isConflicted {
            let diff = try env.runGit([
                "-C", repoRoot,
                "diff", "--no-ext-diff", "--no-color", "--cc", "--unified=3",
                "--", file.path
            ])
            if diff.isEmpty {
                return .note("No combined diff is available for \(file.path) right now.")
            }
            return .sections([GitDiffSection(title: "CONFLICT", content: diff)])
        }

        var sections: [GitDiffSection] = []

        if file.hasStagedChanges {
            let diff = try env.runGit([
                "-C", repoRoot,
                "diff", "--no-ext-diff", "--no-color", "--cached", "--no-renames", "--unified=3",
                "--", file.path
            ])
            if !diff.isEmpty {
                sections.append(GitDiffSection(title: "STAGED", content: diff))
            }
        }

        if file.hasUnstagedChanges {
            let diff = try env.runGit([
                "-C", repoRoot,
                "diff", "--no-ext-diff", "--no-color", "--no-renames", "--unified=3",
                "--", file.path
            ])
            if !diff.isEmpty {
                sections.append(GitDiffSection(title: "UNSTAGED", content: diff))
            }
        }

        if file.isUntracked {
            let absolutePath = (repoRoot as NSString).appendingPathComponent(file.path)
            if env.isDirectory(absolutePath) {
                sections.append(GitDiffSection(
                    title: "UNTRACKED",
                    content: "\(file.path) is an untracked directory. Add or select a file inside it to inspect an exact patch."
                ))
            } else {
                let diff = try env.runGit([
                    "-C", repoRoot,
                    "diff", "--no-index", "--no-color",
                    "--", "/dev/null", file.path
                ])
                if !diff.isEmpty {
                    sections.append(GitDiffSection(title: "UNTRACKED", content: diff))
                }
            }
        }

        if sections.isEmpty {
            return .note("No patch is available for \(file.path).")
        }
        return .sections(sections)
    }
}

extension GitDiffComposer.Environment {
    /// The live environment: shells out to git via `run` and probes the real
    /// filesystem. `run` carries the exit-code policy (0 or 1 are both success
    /// for diffs) so the composer stays oblivious to git's CLI conventions.
    static func live(run: @escaping (_ arguments: [String]) throws -> String) -> GitDiffComposer.Environment {
        GitDiffComposer.Environment(
            runGit: run,
            isDirectory: { absolutePath in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
        )
    }
}
