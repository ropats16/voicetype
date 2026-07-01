import XCTest
@testable import VoiceType

/// Tests for the pure role-classification logic backing
/// `CaretLocator.hasFocusedEditableElement()` (Phase 3, Task 2). The
/// Accessibility calls themselves aren't unit-testable (no real focused UI
/// element in a test process), so only the pure "does this role count as
/// editable" decision is covered here — same constraint as `locate()`, which
/// also has no tests.
final class CaretLocatorTests: XCTestCase {

    func testStandardEditableRolesAreEditable() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
            XCTAssertTrue(CaretLocator.isEditableRole(role), "\(role) should be editable")
        }
    }

    func testNonEditableRolesAreNotEditable() {
        for role in ["AXButton", "AXStaticText", "AXWindow", "AXGroup"] {
            XCTAssertFalse(CaretLocator.isEditableRole(role), "\(role) should not be editable")
        }
    }

    func testNilRoleIsNotEditable() {
        XCTAssertFalse(CaretLocator.isEditableRole(nil))
    }
}
