import ApplicationServices
import XCTest
@testable import UltraTermComputerUseKit

/// Accessibility tree walk budgets and the AX messaging timeout configuration.
/// Pure functions only; the timeout probe targets the test process itself, so
/// no TCC prompt and no foreign app is involved.
final class TreeBudgetContractTests: XCTestCase {
    func testTreeLimitDefaultsMatchContract() {
        XCTAssertEqual(AccessibilityTreeLimits.defaultMaxNodeCount, 1200)
        XCTAssertEqual(AccessibilityTreeLimits.defaultMaxDepth, 64)
        XCTAssertEqual(AccessibilityTreeLimits.defaultMaxVisitedNodeCount, 10_000)
        XCTAssertEqual(AccessibilityTreeLimits.defaultMaxVisitedDepth, 256)

        let defaults = AccessibilityTreeLimits.defaults
        XCTAssertEqual(defaults.maxNodeCount, 1200)
        XCTAssertEqual(defaults.maxDepth, 64)
        XCTAssertEqual(defaults.maxVisitedNodeCount, 10_000)
        XCTAssertEqual(defaults.maxVisitedDepth, 256)
    }

    func testRenderBudgetStopsExactlyAtTheLimit() {
        let limits = AccessibilityTreeLimits(maxNodeCount: 10, maxDepth: 4)

        XCTAssertTrue(shouldContinueRendering(nextIndex: 9, depth: 3, limits: limits))
        XCTAssertFalse(shouldContinueRendering(nextIndex: 10, depth: 3, limits: limits))
        XCTAssertFalse(shouldContinueRendering(nextIndex: 9, depth: 4, limits: limits))
        XCTAssertFalse(shouldContinueRendering(nextIndex: 10, depth: 4, limits: limits))
        XCTAssertTrue(shouldContinueRendering(nextIndex: 0, depth: 0, limits: limits))
    }

    func testVisitedBudgetStopsExactlyAtTheLimit() {
        let limits = AccessibilityTreeLimits(maxVisitedNodeCount: 100, maxVisitedDepth: 8)

        XCTAssertTrue(shouldContinueVisiting(visitedNodeCount: 99, visitedDepth: 7, limits: limits))
        XCTAssertFalse(shouldContinueVisiting(visitedNodeCount: 100, visitedDepth: 7, limits: limits))
        XCTAssertFalse(shouldContinueVisiting(visitedNodeCount: 99, visitedDepth: 8, limits: limits))
        XCTAssertFalse(shouldContinueVisiting(visitedNodeCount: 100, visitedDepth: 8, limits: limits))
        XCTAssertTrue(shouldContinueVisiting(visitedNodeCount: 0, visitedDepth: 0, limits: limits))
    }

    func testVisitedBudgetDefaultsAreUsedWhenLimitsOmitted() {
        XCTAssertTrue(shouldContinueVisiting(visitedNodeCount: 9_999, visitedDepth: 255))
        XCTAssertFalse(shouldContinueVisiting(visitedNodeCount: 10_000, visitedDepth: 255))
        XCTAssertFalse(shouldContinueVisiting(visitedNodeCount: 9_999, visitedDepth: 256))
    }

    func testReplacingUpdatesEachBudgetIndependently() {
        let base = AccessibilityTreeLimits(maxNodeCount: 50, maxDepth: 5, maxVisitedNodeCount: 500, maxVisitedDepth: 50)

        XCTAssertEqual(
            base.replacing(maxNodeCount: 60),
            AccessibilityTreeLimits(maxNodeCount: 60, maxDepth: 5, maxVisitedNodeCount: 500, maxVisitedDepth: 50)
        )
        XCTAssertEqual(
            base.replacing(maxDepth: 6),
            AccessibilityTreeLimits(maxNodeCount: 50, maxDepth: 6, maxVisitedNodeCount: 500, maxVisitedDepth: 50)
        )
        XCTAssertEqual(
            base.replacing(maxVisitedNodeCount: 600),
            AccessibilityTreeLimits(maxNodeCount: 50, maxDepth: 5, maxVisitedNodeCount: 600, maxVisitedDepth: 50)
        )
        XCTAssertEqual(
            base.replacing(maxVisitedDepth: 60),
            AccessibilityTreeLimits(maxNodeCount: 50, maxDepth: 5, maxVisitedNodeCount: 500, maxVisitedDepth: 60)
        )
        XCTAssertEqual(base.replacing(), base)
    }

    func testAXMessagingTimeoutIsFiniteAndConfigured() {
        // The contract: a hung target app can never block a snapshot forever.
        XCTAssertEqual(axMessagingTimeoutSeconds, 4)
        XCTAssertGreaterThan(axMessagingTimeoutSeconds, 0)
    }

    func testAXMessagingTimeoutApplicationIsBestEffortOnOwnProcess() {
        // Applying the timeout to our own process element must never throw or
        // prompt; the call is explicitly best-effort.
        let ownElement = AXUIElementCreateApplication(getpid())
        applyAccessibilityMessagingTimeout(to: ownElement)
        applyAccessibilityMessagingTimeout(to: ownElement, timeoutSeconds: 1.5)
    }
}
