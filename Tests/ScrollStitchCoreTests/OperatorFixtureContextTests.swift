import XCTest
@testable import ScrollStitchCore

final class OperatorFixtureContextTests:XCTestCase {
    private func preferences() -> UserDefaults {
        let suite="ScrollStitch.fixture-test."+UUID().uuidString
        let preferences=UserDefaults(suiteName:suite)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName:suite) }
        return preferences
    }
    func testExplicitFixtureSurvivesLaunchWithoutDeveloperArguments() {
        let prefs=preferences()
        XCTAssertNil(OperatorFixtureContext.resolve(arguments:[],preferences:prefs))
        XCTAssertEqual(OperatorFixtureContext.resolve(arguments:["--m1-fixture","capture"],preferences:prefs),"capture")
        // Settings can kill the process and relaunch without its previous launch arguments.
        XCTAssertEqual(OperatorFixtureContext.resolve(arguments:[],preferences:prefs),"capture")
        XCTAssertEqual(OperatorFixtureContext.resolve(arguments:["--m1-fixture","fixed-bars"],preferences:prefs),"fixed-bars")
        XCTAssertEqual(OperatorFixtureContext.resolve(arguments:[],preferences:prefs),"fixed-bars")
    }
    func testExplicitExitPreservesOriginalSelectionAndSurvivesRestart() {
        let prefs=preferences();prefs.set(["first":0,"last":77,"top":260],forKey:"captureSelection")
        _=OperatorFixtureContext.resolve(arguments:["--m1-fixture","unknown"],preferences:prefs)
        XCTAssertNil(OperatorFixtureContext.resolve(arguments:["--m1-production"],preferences:prefs))
        XCTAssertNil(OperatorFixtureContext.resolve(arguments:[],preferences:prefs))
        XCTAssertEqual(prefs.dictionary(forKey:"captureSelection") as? [String:Int],["first":0,"last":77,"top":260])
    }
    func testInvalidFixtureCannotEscapeItsStoreOrDiscardAnActiveFixture() {
        let prefs=preferences()
        XCTAssertNil(OperatorFixtureContext.resolve(arguments:["--m1-fixture","../../ScrollStitch"],preferences:prefs))
        _=OperatorFixtureContext.resolve(arguments:["--m1-fixture","collage"],preferences:prefs)
        XCTAssertEqual(OperatorFixtureContext.resolve(arguments:["--m1-fixture","../../ScrollStitch"],preferences:prefs),"collage")
        XCTAssertNil(OperatorFixtureContext.resolve(arguments:["--m1-production","--m1-fixture","capture"],preferences:prefs))
    }
}
