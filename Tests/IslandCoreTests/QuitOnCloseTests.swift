import Testing
@testable import IslandCore

struct QuitOnCloseTests {
    @Test func onlyActualLastWindowCloseCanQuit() {
        #expect(QuitOnCloseRules.shouldQuit(enabled: true, trusted: true, clickedCloseButton: true,
                    windowWasDestroyed: true, remainingWindows: 0, protectedApplication: false))
        for windows in [nil, 1, 4] as [Int?] {
            #expect(!QuitOnCloseRules.shouldQuit(enabled: true, trusted: true, clickedCloseButton: true,
                        windowWasDestroyed: true, remainingWindows: windows, protectedApplication: false))
        }
    }
    @Test func cancelledOrUntrustedCloseCannotTerminate() {
        for (enabled, trusted, clicked, destroyed, protected) in [(false,true,true,true,false), (true,false,true,true,false),
                                                                (true,true,false,true,false), (true,true,true,false,false),
                                                                (true,true,true,true,true)] {
            #expect(!QuitOnCloseRules.shouldQuit(enabled: enabled, trusted: trusted, clickedCloseButton: clicked,
                       windowWasDestroyed: destroyed, remainingWindows: 0, protectedApplication: protected))
        }
    }
}
