import Foundation
import Python

/// Starts the CPython interpreter the app ships, once, and reports what came up.
///
/// This lives in the app target rather than in `WebHTVCore` for one hard reason: the interpreter is
/// an iOS-only XCFramework with **no macOS slice**, and `WebHTVCore` has to keep building and testing
/// on macOS, where the 143 existing tests run. Nothing that links Python can sit below this line.
///
/// IOS-POC-7F is only the boot: it answers "does CPython start inside this app at all", which is the
/// one question no macOS test can answer. The Spider runtime is built on top of it, not here.
enum PythonBoot {
    /// What the interpreter reported, or why it did not start. Computed once, during launch, before
    /// anything concurrent exists — the same `nonisolated(unsafe)` this codebase already uses for
    /// launch-time shared state in `CSPSourceResolver`.
    nonisolated(unsafe) private(set) static var status: Status?

    enum Status: Equatable {
        case running(version: String)
        case failed(String)
    }

    /// The standard library `install_python` lays down in the bundle at build time. Upstream's own
    /// installer decides this layout, and its testbed points `PYTHONHOME` at exactly this directory.
    private static var home: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("python")
    }

    @discardableResult
    static func start() -> Status {
        if let status { return status }
        let result = boot()
        status = result
        return result
    }

    private static func boot() -> Status {
        guard let home, FileManager.default.fileExists(atPath: home.path) else {
            return .failed("no python directory in the bundle — the Install Python build phase did not run")
        }
        // `PYTHONHOME` rather than `PyConfig`: it is two calls instead of a struct whose `PyStatus`
        // handling does not bridge cleanly into Swift, and it answers the same question.
        // ponytail: move to PyConfig_InitIsolatedConfig if isolation or argv ever actually matters.
        setenv("PYTHONHOME", home.path, 1)
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1)  // the bundle is read-only; do not try to write .pyc
        setenv("PYTHONUNBUFFERED", "1", 1)         // so a print arrives in the console when it happens

        Py_Initialize()
        guard Py_IsInitialized() != 0 else { return .failed("Py_Initialize left the interpreter down") }

        // `Py_GetVersion` is a plain C string. `Py_GetPrefix` is `wchar_t *`, which is not worth
        // bridging when the interpreter can simply print it.
        let version = String(cString: Py_GetVersion()).split(separator: " ").first.map(String.init) ?? "?"

        // Importing is the real test. `sys` is built in and would pass with no standard library on
        // disk at all; `json` and `re` only import when PYTHONHOME actually found the library, and
        // the assert makes them do work rather than merely resolve.
        //
        // Python's own stdout does not reach the console that `simctl launch --console-pty` captures,
        // so the return code is the evidence here, not a print.
        let imported = PyRun_SimpleString("""
        import sys, json, re
        assert json.loads(json.dumps({'re': re.escape('a.b')}))['re'] == 'a\\\\.b'
        """)
        guard imported == 0 else {
            return .failed("the standard library did not import — check PYTHONHOME at \(home.path)")
        }

        // Negative control. Without it, a `PyRun_SimpleString` that silently did nothing would look
        // exactly like success above, and the whole check would be worthless.
        guard PyRun_SimpleString("raise RuntimeError('negative control: this traceback is expected')") != 0 else {
            return .failed("the interpreter reported success for a snippet that must fail")
        }
        return .running(version: version)
    }
}
