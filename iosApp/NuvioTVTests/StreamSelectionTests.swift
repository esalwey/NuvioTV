import XCTest
@testable import NuvioTV

/// The rules behind the stream-selection settings: how long Up Next waits for add-ons, the
/// add-on and plugin allow lists, the option lists of the pickers, and the source group Up Next
/// follows.
@MainActor
final class StreamSelectionTests: XCTestCase {

    // MARK: - Selection timeout

    func testInstantChoosesOnEveryResponseWithoutAWaitingPeriod() {
        let timeout = StreamSelectionTimeout(settingSeconds: 0)
        XCTAssertTrue(timeout.choosesOnEveryResponse)
        XCTAssertNil(timeout.softTimeoutSec)
        XCTAssertEqual(timeout.hardStopSec, StreamSelectionTimeout.graceSec)
    }

    func testUnlimitedChoosesOnEveryResponseWithALongHardStop() {
        let timeout = StreamSelectionTimeout(settingSeconds: Int(Int32.max))
        XCTAssertTrue(timeout.choosesOnEveryResponse)
        XCTAssertNil(timeout.softTimeoutSec)
        XCTAssertEqual(timeout.hardStopSec, 60)
    }

    func testABoundedTimeoutWaitsThenGivesStragglersAGraceWindow() {
        let timeout = StreamSelectionTimeout(settingSeconds: 3)
        XCTAssertFalse(timeout.choosesOnEveryResponse)
        XCTAssertEqual(timeout.softTimeoutSec, 3)
        XCTAssertEqual(timeout.hardStopSec, 3 + StreamSelectionTimeout.graceSec)
    }

    func testBoundedTimeoutsAreKeptBetweenOneAndThirtySeconds() {
        XCTAssertEqual(StreamSelectionTimeout(settingSeconds: 1).softTimeoutSec, 1)
        XCTAssertEqual(StreamSelectionTimeout(settingSeconds: 30).softTimeoutSec, 30)
        XCTAssertEqual(StreamSelectionTimeout(settingSeconds: 45).softTimeoutSec, 30)
    }

    func testANegativeValueIsInstant() {
        XCTAssertTrue(StreamSelectionTimeout(settingSeconds: -5).choosesOnEveryResponse)
    }

    // MARK: - Picker options

    func testTimeoutChoicesAreThePhonesListWithTheCurrentValueAdded() {
        XCTAssertEqual(StreamSelectionOptions.timeoutValues.first, 0)
        XCTAssertEqual(StreamSelectionOptions.timeoutValues.last, StreamSelectionOptions.unlimitedTimeout)
        XCTAssertEqual(StreamSelectionOptions.timeoutChoices(including: 7), StreamSelectionOptions.timeoutValues)
        let withTwelve = StreamSelectionOptions.timeoutChoices(including: 12)
        XCTAssertEqual(withTwelve.firstIndex(of: 12), withTwelve.firstIndex(of: 10).map { $0 + 1 })
    }

    func testTimeoutLabelsNameTheTwoSpecialValues() {
        let labels = Set(StreamSelectionOptions.timeoutValues.map(StreamSelectionOptions.timeoutLabel))
        XCTAssertEqual(labels.count, StreamSelectionOptions.timeoutValues.count)
    }

    func testReuseWindowChoicesAreSortedAndKeepTheCurrentValue() {
        XCTAssertEqual(StreamSelectionOptions.reuseHourChoices(including: 24), StreamSelectionOptions.reuseHourValues)
        let odd = StreamSelectionOptions.reuseHourChoices(including: 10)
        XCTAssertEqual(odd, odd.sorted())
        XCTAssertTrue(odd.contains(10))
        XCTAssertEqual(Set(StreamSelectionOptions.reuseHourValues.map(StreamSelectionOptions.reuseHoursLabel)).count,
                       StreamSelectionOptions.reuseHourValues.count)
    }

    // MARK: - Allow lists

    private let addons = ["Comet", "Torrentio", "Zilean"]

    func testNothingStoredMeansEveryNameIsOn() {
        let selection = AllowedSourceSelection(available: addons, stored: [])
        XCTAssertTrue(selection.allowsEverything)
        XCTAssertEqual(selection.allowed, Set(addons))
        XCTAssertTrue(addons.allSatisfy(selection.isAllowed))
    }

    func testSwitchingOneNameOffStoresTheOthers() {
        let selection = AllowedSourceSelection(available: addons, stored: [])
        XCTAssertEqual(selection.storing("Torrentio", allowed: false), ["Comet", "Zilean"])
    }

    func testSwitchingTheLastNameBackOnStoresNothingAgain() {
        let selection = AllowedSourceSelection(available: addons, stored: ["Comet", "Zilean"])
        XCTAssertFalse(selection.allowsEverything)
        XCTAssertFalse(selection.isAllowed("Torrentio"))
        XCTAssertEqual(selection.storing("Torrentio", allowed: true), [])
    }

    func testTheLastNameThatIsOnCannotBeSwitchedOff() {
        let selection = AllowedSourceSelection(available: addons, stored: ["Comet"])
        XCTAssertNil(selection.storing("Comet", allowed: false))
        XCTAssertEqual(selection.storing("Zilean", allowed: true), ["Comet", "Zilean"])
    }

    func testANameThatIsNoLongerInstalledCountsForNothing() {
        let stale = AllowedSourceSelection(available: addons, stored: ["Removed"])
        XCTAssertTrue(stale.allowsEverything)
        let partial = AllowedSourceSelection(available: addons, stored: ["Removed", "Comet"])
        XCTAssertEqual(partial.allowed, ["Comet"])
    }

    // MARK: - Source group

    func testThePlayingStreamsOwnGroupWins() {
        XCTAssertEqual(BingeGroupMemory.preferred(playing: "  torrentio|4k ", parentMetaId: "tt1", reuseRemembered: false),
                       "torrentio|4k")
        XCTAssertEqual(BingeGroupMemory.preferred(playing: "torrentio|4k", parentMetaId: "tt1", reuseRemembered: true),
                       "torrentio|4k")
    }

    func testWithoutAGroupAndWithoutTheSettingThereIsNoPreference() {
        XCTAssertNil(BingeGroupMemory.preferred(playing: nil, parentMetaId: "tt1", reuseRemembered: false))
        XCTAssertNil(BingeGroupMemory.preferred(playing: "   ", parentMetaId: "tt1", reuseRemembered: false))
    }
}
