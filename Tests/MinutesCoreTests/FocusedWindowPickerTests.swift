import Testing
import MinutesCore

@Suite struct FocusedWindowPickerTests {
    private func window(
        _ id: UInt32, pid: Int32, layer: Int = 0, _ width: Double = 1000, _ height: Double = 700
    ) -> ScreenWindow {
        ScreenWindow(windowID: id, ownerPID: pid, layer: layer, width: width, height: height)
    }

    @Test func picksTheTopmostNormalWindowOfTheFrontmostApp() {
        let windows = [
            window(1, pid: 10),          // other app, above
            window(2, pid: 20),          // frontmost app, topmost
            window(3, pid: 20),          // frontmost app, behind
        ]
        #expect(FocusedWindowPicker.pick(among: windows, frontmostPID: 20, excludingPID: 99) == 2)
    }

    @Test func skipsFloatingLayersAndSmallWindows() {
        let windows = [
            window(1, pid: 20, layer: 3),       // floating panel or picture in picture
            window(2, pid: 20, 280, 700),       // too narrow
            window(3, pid: 20, 1000, 150),      // too short
            window(4, pid: 20),
        ]
        #expect(FocusedWindowPicker.pick(among: windows, frontmostPID: 20, excludingPID: 99) == 4)
    }

    @Test func returnsNilForOwnAppOrWhenTheFrontmostAppHasNoWindow() {
        let windows = [window(1, pid: 99), window(2, pid: 10)]
        #expect(FocusedWindowPicker.pick(among: windows, frontmostPID: 99, excludingPID: 99) == nil)
        #expect(FocusedWindowPicker.pick(among: windows, frontmostPID: 30, excludingPID: 99) == nil)
        #expect(FocusedWindowPicker.pick(among: windows, frontmostPID: nil, excludingPID: 99) == nil)
    }
}

@Suite struct FocusDebouncerTests {
    @Test func switchesOnlyAfterTheSameWindowIsSeenTwice() {
        var debouncer = FocusDebouncer(current: 1)
        #expect(debouncer.observe(2) == nil)
        #expect(debouncer.observe(2) == 2)
        #expect(debouncer.current == 2)
        #expect(debouncer.observe(2) == nil)
    }

    @Test func aPassingWindowNeverWins() {
        var debouncer = FocusDebouncer(current: 1)
        #expect(debouncer.observe(2) == nil)   // quick Cmd-Tab through another app
        #expect(debouncer.observe(1) == nil)
        #expect(debouncer.observe(3) == nil)
        #expect(debouncer.observe(1) == nil)
        #expect(debouncer.current == 1)
    }

    @Test func noCandidateKeepsTheCurrentWindow() {
        var debouncer = FocusDebouncer(current: 1)
        #expect(debouncer.observe(nil) == nil)
        #expect(debouncer.observe(nil) == nil)
        #expect(debouncer.current == 1)
    }

    @Test func resetMovesTheCurrentWindowWithoutAPendingSwitch() {
        var debouncer = FocusDebouncer(current: 1)
        #expect(debouncer.observe(2) == nil)
        debouncer.reset(to: 1)
        #expect(debouncer.observe(2) == nil)
        #expect(debouncer.observe(2) == 2)
    }
}
