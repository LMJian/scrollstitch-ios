import Foundation

/// Explicit local acceptance mode survives OS restarts caused by permission changes.
/// Normal users never enter it; it cannot select an arbitrary path or mutate source data.
public enum OperatorFixtureContext {
    private static let key="m1OperatorFixture"
    private static let allowed:Set<String>=["blank","capture","collage","unknown","fixed-bars"]
    public static func resolve(arguments:[String], preferences:UserDefaults = .standard) -> String? {
        guard BuildMode.operatorToolsEnabled else { return nil }
        if arguments.contains("--m1-production") {
            preferences.removeObject(forKey:key)
            return nil
        }
        if let i=arguments.firstIndex(of:"--m1-fixture"), arguments.count>i+1,
           allowed.contains(arguments[i+1]) {
            preferences.set(arguments[i+1],forKey:key)
        }
        guard let stored=preferences.string(forKey:key), allowed.contains(stored) else { return nil }
        return stored
    }
}
