import Foundation

@main
struct NativeAppLauncherResolverTests {
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            fputs("expected app search root\n", stderr)
            exit(2)
        }
        let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        do {
            let unique=try resolve("Unique",roots:[root])
            guard unique.bundleID=="com.test.unique" else { throw failure("unique_name_mismatch") }
            let wrapped=try resolve("Wrapped iOS App",roots:[root])
            guard wrapped.bundleID=="com.test.ios-wrapper" else { throw failure("wrapper_name_mismatch") }
            do {
                _=try resolve("Duplicate",roots:[root])
                throw failure("duplicate_name_was_not_rejected")
            } catch {
                guard (error as NSError).localizedDescription=="application_name_is_ambiguous" else { throw error }
            }
            print("resolver-tests-ok")
        } catch {
            fputs((error as NSError).localizedDescription+"\n",stderr)
            exit(1)
        }
    }

    private static func failure(_ reason:String)->NSError {
        NSError(domain:"NativeAppLauncherTests",code:1,userInfo:[NSLocalizedDescriptionKey:reason])
    }
}
