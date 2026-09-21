import Foundation
import Python
import WebHTVCore

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

    /// The pending Python exception as text, clearing it either way.
    ///
    /// Without this a failure crosses into Swift as "something went wrong": `PyErr_Clear` throws the
    /// reason away, and Python's own traceback goes to a stderr the console never shows. Every place
    /// that used to clear the error now reports it.
    static func takePythonError() -> String {
        guard PyErr_Occurred() != nil else { return "no Python error was set" }
        var type: UnsafeMutablePointer<PyObject>?
        var value: UnsafeMutablePointer<PyObject>?
        var trace: UnsafeMutablePointer<PyObject>?
        PyErr_Fetch(&type, &value, &trace)
        PyErr_NormalizeException(&type, &value, &trace)
        defer {
            if let type { Py_DecRef(type) }
            if let value { Py_DecRef(value) }
            if let trace { Py_DecRef(trace) }
        }
        var name = "Error"
        if let type, let attribute = PyObject_GetAttrString(type, "__name__") {
            if let text = PyUnicode_AsUTF8(attribute) { name = String(cString: text) }
            Py_DecRef(attribute)
        }
        var detail = "(no message)"
        if let value, let described = PyObject_Str(value) {
            if let text = PyUnicode_AsUTF8(described) { detail = String(cString: text) }
            Py_DecRef(described)
        }
        return "\(name): \(detail)"
    }

    @discardableResult
    static func start() -> Status {
        if let status { return status }
        let result = boot()
        status = result
        return result
    }

    /// Starts the interpreter if it is not up, and throws if it will not come up. The Spider runtime
    /// calls this rather than assuming launch already did it, so a Release build works the same.
    static func ensureStarted() throws {
        if case .running = start() { return }
        if case .failed(let why) = start() { throw SpiderError.scriptFailed("Python did not start: \(why)") }
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
        // bridging when the version alone answers what started.
        let version = String(cString: Py_GetVersion()).split(separator: " ").first.map(String.init) ?? "?"

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

        // The app's own Python — `base/spider.py` and `webhtv_runtime.py` — travels beside the
        // standard library in the bundle. The path goes onto `sys.path` through the C API rather
        // than by evaluating a string: `PyRun_SimpleString` swallows its own errors, so a failure
        // there is invisible, and this way there is nothing to quote in the first place.
        guard let ourPython = Bundle.main.resourceURL?.appendingPathComponent("webhtv-python") else {
            return .failed("the bundle has no webhtv-python directory")
        }
        guard let searchPath = PySys_GetObject("path") else {
            return .failed("sys.path is missing — \(takePythonError())")
        }
        let entry = PyUnicode_FromString(ourPython.path)
        let inserted = PyList_Insert(searchPath, 0, entry)
        if let entry { Py_DecRef(entry) }
        guard inserted == 0 else {
            return .failed("could not put \(ourPython.path) on sys.path — \(takePythonError())")
        }
        guard let runtimeModule = PyImport_ImportModule("webhtv_runtime") else {
            return .failed("webhtv_runtime did not import from \(ourPython.path) — \(takePythonError())")
        }
        Py_DecRef(runtimeModule)

        // Hand the GIL back. `Py_Initialize` leaves it held by this thread, and every later call
        // arrives on whichever thread the caller is on and takes it with `PyGILState_Ensure`; without
        // this they would all block on the main thread forever.
        PyEval_SaveThread()
        return .running(version: version)
    }

    #if DEBUG
    /// Drives a hard-coded spider through all thirteen methods of the ABI.
    ///
    /// This is IOS-POC-7G's acceptance: the script arrives as text, exactly as a real one arrives
    /// over HTTP, and every method has to come back with what it was asked for. It cannot live in
    /// `swift test` — that runs on macOS, where this interpreter does not exist.
    static func selfCheck() async -> String {
        let script = """
        from base.spider import Spider

        class Spider(Spider):
            def init(self, extend=''):
                self.extend = extend
            def homeContent(self, filter):
                return {'class': [{'type_id': '1', 'type_name': 'one'}], 'filter': filter}
            def homeVideoContent(self):
                return {'list': [{'vod_id': 'v1'}]}
            def categoryContent(self, tid, pg, filter, extend):
                return {'tid': tid, 'pg': pg, 'filter': filter, 'extend': extend}
            def detailContent(self, ids):
                return {'ids': ids, 'extend': self.extend}
            def searchContent(self, key, quick, pg='1'):
                return {'key': key, 'quick': quick, 'pg': pg}
            def playerContent(self, flag, id, vipFlags):
                return {'parse': 0, 'url': id, 'flag': flag, 'vip': vipFlags}
            def liveContent(self, url):
                return {'url': url}
            def isVideoFormat(self, url):
                return url.endswith('.mp4')
            def manualVideoCheck(self):
                return True
            def action(self, action):
                return 'did ' + action
            def getName(self):
                return 'fake'
        """
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let runtime: PythonSpiderRuntime
        do {
            runtime = try PythonSpiderRuntime(script: script, siteKey: "selfcheck",
                                              cacheDirectory: caches.appendingPathComponent("python-spider"))
        } catch {
            return "FAILED to load: \(error)"
        }

        var failures = [String]()
        func expect(_ label: String, _ actual: String, contains needle: String) {
            if !actual.contains(needle) { failures.append("\(label): \(actual) lacks \(needle)") }
        }
        do {
            try await runtime.initialize(extend: "EXT")
            expect("homeContent", try await runtime.homeContent(filter: true), contains: "\"filter\": true")
            expect("homeVideoContent", try await runtime.homeVideoContent(), contains: "v1")
            expect("categoryContent",
                   try await runtime.categoryContent(tid: "3", page: "2", filter: false, extend: ["a": "b"]),
                   contains: "\"tid\": \"3\"")
            // `init` ran first, so the extend it stored has to come back out of a later call.
            expect("detailContent", try await runtime.detailContent(ids: ["id7"]), contains: "EXT")
            expect("searchContent", try await runtime.searchContent(key: "k", quick: true, page: "1"),
                   contains: "\"key\": \"k\"")
            expect("playerContent", try await runtime.playerContent(flag: "F", id: "u", vipFlags: ["v"]),
                   contains: "\"parse\": 0")
            expect("liveContent", try await runtime.liveContent(url: "L"), contains: "L")
            expect("action", try await runtime.action("go"), contains: "did go")
            if try await runtime.isVideoFormat(url: "a.mp4") != true { failures.append("isVideoFormat true") }
            if try await runtime.isVideoFormat(url: "a.html") != false { failures.append("isVideoFormat false") }
            if try await runtime.manualVideoCheck() != true { failures.append("manualVideoCheck") }
        } catch {
            failures.append("threw: \(error)")
        }

        // A spider that raises must arrive as a named error, not as a crash or an empty page.
        do {
            let broken = try PythonSpiderRuntime(script: "from base.spider import Spider\nclass Spider(Spider):\n    def init(self, extend=''):\n        raise ValueError('boom')\n",
                                                 siteKey: "selfcheck-broken",
                                                 cacheDirectory: caches.appendingPathComponent("python-spider"))
            _ = try await broken.initialize(extend: "")
            failures.append("a raising spider reported success")
        } catch {
            if !"\(error)".contains("boom") { failures.append("the raised error lost its message: \(error)") }
        }

        await runtime.destroy()
        return failures.isEmpty ? "13/13 methods OK, errors propagate" : "FAILED \(failures)"
    }
    #endif
}
