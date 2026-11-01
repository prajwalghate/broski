import Foundation
import Testing
@testable import BroskiCore

/// Opening Broski while it's already running (Spotlight finding a build or a kept copy, a second click) must not
/// start a second one: two would both hold the mic and the shortcuts, show two menu-bar icons, and write the same
/// files. The installed copy is the one that stays.
@Suite("One Broski at a time")
struct SingleInstanceTests {
    private let installed = "/Applications/Broski.app"
    private let build = "/tmp/broski/build/Broski.app"
    private let kept = "/tmp/Previous/Broski-0.13.0-31.app"

    private func copy(_ pid: Int32, _ path: String, terminated: Bool = false) -> SingleInstance.Running {
        SingleInstance.Running(pid: pid, path: path, terminated: terminated)
    }

    @Test("a second Broski hands over to the one already running")
    func secondLaunchHandsOver() {
        let running = [copy(100, installed), copy(200, build)]
        #expect(SingleInstance.decide(running, me: 200, installed: installed) == .handOver(100))
        // Two copies that aren't installed: the first one stays.
        #expect(SingleInstance.decide([copy(100, kept), copy(200, build)], me: 200, installed: installed) == .handOver(100))
    }

    @Test("the installed Broski replaces a build or a kept copy that was opened first")
    func installedWins() {
        let running = [copy(100, build), copy(200, installed)]
        #expect(SingleInstance.decide(running, me: 200, installed: installed) == .replace(100))
        #expect(SingleInstance.decide([copy(100, kept), copy(200, installed)], me: 200, installed: installed) == .replace(100))
    }

    @Test("the only Broski keeps running")
    func onlyOneRuns() {
        #expect(SingleInstance.decide([copy(200, installed)], me: 200, installed: installed) == .run)
        #expect(SingleInstance.decide([], me: 200, installed: installed) == .run)
    }

    @Test("a Broski that has already quit doesn't count, so a restart comes up")
    func quitOneDoesNotCount() {
        let running = [copy(100, installed, terminated: true), copy(200, installed)]
        #expect(SingleInstance.decide(running, me: 200, installed: installed) == .run)
    }
}
