import XCTest
import ServiceManagement
@testable import VoiceType

/// Tests for LoginItem wrapper (Phase 4, Task 3).
/// Uses a fake LoginItemService to verify call routing and map(_:) logic
/// without touching the real SMAppService registration machinery.
final class LoginItemTests: XCTestCase {

    // MARK: - Fake

    /// Configurable fake that records register/unregister call counts
    /// and can optionally throw on demand.
    private final class FakeLoginItemService: LoginItemService {
        var rawStatus: SMAppService.Status
        var registerCallCount = 0
        var unregisterCallCount = 0
        var registerError: Error?
        var unregisterError: Error?

        init(status: SMAppService.Status = .notRegistered) {
            rawStatus = status
        }

        func register() throws {
            registerCallCount += 1
            if let error = registerError { throw error }
        }

        func unregister() throws {
            unregisterCallCount += 1
            if let error = unregisterError { throw error }
        }
    }

    private struct FakeError: Error {}

    // MARK: - setEnabled(true) → register()

    func testSetEnabledTrueCallsRegisterOnce() throws {
        let fake = FakeLoginItemService()
        let sut = LoginItem(service: fake)
        try sut.setEnabled(true)
        XCTAssertEqual(fake.registerCallCount, 1, "setEnabled(true) must call register() exactly once")
        XCTAssertEqual(fake.unregisterCallCount, 0, "setEnabled(true) must not call unregister()")
    }

    // MARK: - setEnabled(false) → unregister()

    func testSetEnabledFalseCallsUnregisterOnce() throws {
        let fake = FakeLoginItemService()
        let sut = LoginItem(service: fake)
        try sut.setEnabled(false)
        XCTAssertEqual(fake.unregisterCallCount, 1, "setEnabled(false) must call unregister() exactly once")
        XCTAssertEqual(fake.registerCallCount, 0, "setEnabled(false) must not call register()")
    }

    // MARK: - Error propagation

    func testSetEnabledTrueRethrowsRegisterError() {
        let fake = FakeLoginItemService()
        fake.registerError = FakeError()
        let sut = LoginItem(service: fake)
        XCTAssertThrowsError(try sut.setEnabled(true), "setEnabled(true) must rethrow register() errors")
    }

    func testSetEnabledFalseRethrowsUnregisterError() {
        let fake = FakeLoginItemService()
        fake.unregisterError = FakeError()
        let sut = LoginItem(service: fake)
        XCTAssertThrowsError(try sut.setEnabled(false), "setEnabled(false) must rethrow unregister() errors")
    }

    // MARK: - map(_:) status mapping

    func testMapEnabledReturnsEnabled() {
        XCTAssertEqual(LoginItem.map(.enabled), .enabled)
    }

    func testMapNotRegisteredReturnsDisabled() {
        XCTAssertEqual(LoginItem.map(.notRegistered), .disabled)
    }

    func testMapRequiresApprovalReturnsRequiresApproval() {
        XCTAssertEqual(LoginItem.map(.requiresApproval), .requiresApproval)
    }

    func testMapNotFoundReturnsNotFound() {
        XCTAssertEqual(LoginItem.map(.notFound), .notFound)
    }

    // MARK: - status / isEnabled reflect fake's rawStatus

    func testStatusReflectsFakeRawStatus() {
        let fake = FakeLoginItemService(status: .enabled)
        let sut = LoginItem(service: fake)
        XCTAssertEqual(sut.status, .enabled)
    }

    func testIsEnabledTrueWhenRawStatusEnabled() {
        let fake = FakeLoginItemService(status: .enabled)
        let sut = LoginItem(service: fake)
        XCTAssertTrue(sut.isEnabled)
    }

    func testIsEnabledFalseWhenRawStatusNotRegistered() {
        let fake = FakeLoginItemService(status: .notRegistered)
        let sut = LoginItem(service: fake)
        XCTAssertFalse(sut.isEnabled)
    }

    func testStatusRequiresApproval() {
        let fake = FakeLoginItemService(status: .requiresApproval)
        let sut = LoginItem(service: fake)
        XCTAssertEqual(sut.status, .requiresApproval)
        XCTAssertFalse(sut.isEnabled)
    }
}
