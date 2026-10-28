import CoreGraphics
import Testing
import MinutesCore

@Suite struct FocusedDisplayPickerTests {
    // Three displays side by side in global coordinates (top-left origin), like a laptop plus two monitors.
    private let displays: [(id: UInt32, frame: CGRect)] = [
        (1, CGRect(x: 0, y: 0, width: 1280, height: 832)),
        (2, CGRect(x: 1280, y: 0, width: 1920, height: 1080)),
        (3, CGRect(x: 3200, y: 0, width: 2560, height: 1440)),
    ]

    @Test func picksTheDisplayContainingTheWindowCenter() {
        let window = CGRect(x: 3400, y: 100, width: 1200, height: 800)
        #expect(FocusedDisplayPicker.pick(windowFrame: window, displays: displays) == 3)
    }

    @Test func picksTheDisplayHoldingMostOfAWindowThatSpansTwo() {
        // The center falls below the laptop display, on no display; most of the window is on display 1.
        let window = CGRect(x: 200, y: 700, width: 1200, height: 400)
        #expect(FocusedDisplayPicker.pick(windowFrame: window, displays: displays) == 1)
    }

    @Test func returnsNilWhenTheWindowIsOnNoDisplay() {
        let window = CGRect(x: -5000, y: -5000, width: 800, height: 600)
        #expect(FocusedDisplayPicker.pick(windowFrame: window, displays: displays) == nil)
        #expect(FocusedDisplayPicker.pick(windowFrame: nil, displays: displays) == nil)
    }
}
