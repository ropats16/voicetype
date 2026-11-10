import XCTest
@testable import VoiceType

/// The pure rules turning what the AX probe saw into a paste/copy verdict and
/// a restore speed. The AX calls themselves aren't unit-testable.
final class FocusRulesTests: XCTestCase {

    private func report(_ focused: FocusObservation.Focused, app: String? = "com.apple.TextEdit",
                        chromium: Bool = false) -> FocusReport {
        FocusRules.report(for: FocusObservation(focused: focused, bundleID: app, isChromiumHosted: chromium))
    }

    // MARK: - Roles

    func testStandardEditableRolesAreEditable() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
            XCTAssertEqual(report(.element(role: role, valueSettable: false)).verdict, .editable, role)
        }
    }

    func testOtherRolesAreEditableOnlyWhenValueSettable() {
        for role in ["AXButton", "AXStaticText", "AXWindow", "AXGroup", "AXWebArea"] {
            XCTAssertEqual(report(.element(role: role, valueSettable: false)).verdict, .notEditable, role)
            XCTAssertEqual(report(.element(role: role, valueSettable: true)).verdict, .editable, role)
        }
        XCTAssertEqual(report(.element(role: nil, valueSettable: false)).verdict, .notEditable)
    }

    // MARK: - Unknown focus

    func testNoFocusedElementIsUnknown() {
        // Electron apps whose AX tree isn't up yet: pasted anyway (4bbfeac).
        XCTAssertEqual(report(.none), FocusReport(verdict: .unknown, isSlowApp: false))
        XCTAssertEqual(report(.none, app: nil), FocusReport(verdict: .unknown, isSlowApp: false))
    }

    func testTimeoutIsUnknownAndSlow() {
        // A hung app may read the pasteboard late: give it the long restore.
        XCTAssertEqual(report(.timedOut), FocusReport(verdict: .unknown, isSlowApp: true))
    }

    // MARK: - Finder

    func testFinderWithoutFocusedFieldIsNotEditable() {
        let finder = FocusRules.finderBundleID
        XCTAssertEqual(report(.none, app: finder).verdict, .notEditable, "Desktop")
        XCTAssertEqual(report(.element(role: "AXList", valueSettable: false), app: finder).verdict,
                       .notEditable, "File list")
        XCTAssertEqual(report(.element(role: "AXOutline", valueSettable: false), app: finder).verdict,
                       .notEditable, "List view")
        XCTAssertEqual(report(.timedOut, app: finder).verdict, .notEditable)
    }

    func testFinderTextFieldsAreEditable() {
        let finder = FocusRules.finderBundleID
        XCTAssertEqual(report(.element(role: "AXTextField", valueSettable: true), app: finder).verdict,
                       .editable, "Rename field")
        XCTAssertEqual(report(.element(role: "AXSearchField", valueSettable: true), app: finder).verdict,
                       .editable, "Search field")
        XCTAssertEqual(report(.element(role: "AXTextArea", valueSettable: true), app: finder).verdict, .editable)
    }

    // MARK: - Chromium / Electron

    func testChromiumHostedAppIsSlow() {
        XCTAssertEqual(report(.element(role: "AXTextArea", valueSettable: true), chromium: true),
                       FocusReport(verdict: .editable, isSlowApp: true))
        XCTAssertEqual(report(.none, chromium: true), FocusReport(verdict: .unknown, isSlowApp: true))
        XCTAssertFalse(report(.element(role: "AXTextArea", valueSettable: true)).isSlowApp)
    }

    func testChromiumHostedFromBundledFrameworks() {
        let chromium: [[String]] = [
            ["Electron Framework.framework", "Mantle.framework", "Squirrel.framework"],   // VS Code, Slack
            ["Google Chrome Framework.framework"],
            ["Microsoft Edge Framework.framework"],
            ["Brave Browser Framework.framework"],
            ["Chromium Embedded Framework.framework"],                                  // CEF apps
        ]
        for frameworks in chromium {
            XCTAssertTrue(FocusRules.isChromiumHosted(frameworks: frameworks), "\(frameworks)")
        }
        let native: [[String]] = [
            [],
            ["Sparkle.framework", "Sentry.framework"],
            ["Electron.framework"],   // not the Electron Framework bundle name
        ]
        for frameworks in native {
            XCTAssertFalse(FocusRules.isChromiumHosted(frameworks: frameworks), "\(frameworks)")
        }
    }
}
