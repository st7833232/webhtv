import Foundation
import JavaScriptCore

/// Assembles the compatibility SDK a ported CatVod spider runs against.
///
/// One host, shared by the `csp_*` ports and by the drpy JavaScript spiders the config already
/// carries, so there is exactly one runtime to maintain. The JavaScript half — `pdfh`, `pdfa`, `pd`,
/// the selector engine and the CatVod result builders — lives in `Resources/Spiders/host.js`.
enum CatVodHost {
    static func install(into context: JSContext, storage: SpiderStorage,
                        cookies: CookieJar, session: URLSession) {
        installConsole(context)
        HTTPHost.install(into: context, cookies: cookies, session: session)
        CryptoHost.install(into: context)
        StorageHost.install(into: context, storage: storage)
        installUtil(context)
    }

    private static func installConsole(_ context: JSContext) {
        let log: @convention(block) (String) -> Void = { print("[spider] \($0)") }
        let console = JSValue(newObjectIn: context)
        for name in ["log", "warn", "error", "info"] {
            console?.setObject(log, forKeyedSubscript: name as NSString)
        }
        context.setObject(console, forKeyedSubscript: "console" as NSString)
    }

    private static func installUtil(_ context: JSContext) {
        let encode: @convention(block) (String) -> String = {
            $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0
        }
        let decode: @convention(block) (String) -> String = { $0.removingPercentEncoding ?? $0 }
        let now: @convention(block) () -> Double = { Date().timeIntervalSince1970 * 1000 }
        let util = JSValue(newObjectIn: context)
        util?.setObject(encode, forKeyedSubscript: "urlencode" as NSString)
        util?.setObject(decode, forKeyedSubscript: "urldecode" as NSString)
        util?.setObject(now, forKeyedSubscript: "now" as NSString)
        context.setObject(util, forKeyedSubscript: "__util" as NSString)
    }
}
