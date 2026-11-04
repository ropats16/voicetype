import XCTest
@testable import VoiceType

/// The main-thread side of the tap adapter: actions from a stopped (stale) tap
/// must not double-fire next to its replacement, but its releases still land.
final class HotkeyDeliveryTests: XCTestCase {

    private var fired: [HotkeyAction] = []

    private func makeDelivery() -> HotkeyDelivery {
        let delivery = HotkeyDelivery()
        delivery.onHoldStart = { [unowned self] in fired.append(.holdStart) }
        delivery.onHoldStop = { [unowned self] in fired.append(.holdStop) }
        delivery.onTogglePress = { [unowned self] in fired.append(.togglePress) }
        delivery.onCancel = { [unowned self] in fired.append(.cancel) }
        return delivery
    }

    func testLiveGenerationDeliversEverythingInOrder() {
        let delivery = makeDelivery()
        delivery.deliver([.holdStart, .togglePress, .cancel, .holdStop], generation: delivery.generation)
        XCTAssertEqual(fired, [.holdStart, .togglePress, .cancel, .holdStop])
    }

    func testStaleTapPressesAreDroppedAfterRebind() {
        let delivery = makeDelivery()
        let old = delivery.generation
        delivery.invalidate()                     // stop(): the old tap is still tearing down
        let new = delivery.generation

        delivery.deliver([.togglePress], generation: new)   // the new tap sees the press
        delivery.deliver([.togglePress], generation: old)   // the old tap flushes the same press late
        delivery.deliver([.holdStart, .cancel], generation: old)
        XCTAssertEqual(fired, [.togglePress], "One physical press must toggle once, not start then stop")
    }

    func testStaleTapReleaseStillDelivered() {
        let delivery = makeDelivery()
        let old = delivery.generation
        delivery.invalidate()
        delivery.deliver([.holdStop], generation: old)      // synthetic release from teardown
        XCTAssertEqual(fired, [.holdStop], "A hold active at teardown must still stop")
    }
}
