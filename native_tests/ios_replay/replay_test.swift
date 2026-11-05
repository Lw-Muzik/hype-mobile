// Host test for DSPReplayLog: the log must replay each setting's LAST value,
// in the order the settings were first recorded.
import Foundation

final class FakeEngine {
    var applied: [String] = []
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8))
    exit(1)
}

@main
struct ReplayTest {
    static func main() {
        let log = DSPReplayLog()
        let fake = FakeEngine()
        let ptr = Unmanaged.passUnretained(fake).toOpaque()
        func engine(_ p: UnsafeMutableRawPointer) -> FakeEngine {
            Unmanaged<FakeEngine>.fromOpaque(p).takeUnretainedValue()
        }

        log.record(key: "preamp") { engine($0).applied.append("preamp=3") }
        log.record(key: "eqBand.4") { engine($0).applied.append("eqBand(4)=2") }
        log.record(key: "eqBand.4") { engine($0).applied.append("eqBand(4)=5") }
        log.record(key: "mono") { engine($0).applied.append("mono=true") }

        log.replay(onto: ptr)
        let expected = ["preamp=3", "eqBand(4)=5", "mono=true"]
        if fake.applied != expected { fail("got \(fake.applied), expected \(expected)") }
        if log.count != 3 { fail("count \(log.count)") }

        // A second engine gets the same state; replaying twice is idempotent.
        let other = FakeEngine()
        log.replay(onto: Unmanaged.passUnretained(other).toOpaque())
        if other.applied != expected { fail("second engine got \(other.applied)") }

        // A superseding call removes its family; later entries keep their order.
        let fam = DSPReplayLog()
        let f = FakeEngine()
        fam.record(key: "band.1") { engine($0).applied.append("band1") }
        fam.record(key: "all") { engine($0).applied.append("all") }
        fam.record(key: "band.2") { engine($0).applied.append("band2") }
        fam.removeAll(withPrefix: "band.")
        fam.record(key: "band.2") { engine($0).applied.append("band2b") }
        fam.replay(onto: Unmanaged.passUnretained(f).toOpaque())
        if f.applied != ["all", "band2b"] { fail("family removal: \(f.applied)") }

        // Track gain: set before the engine exists, still there at creation;
        // a released id's gain is dropped and a late set is ignored.
        var book = PlayerValueBook()
        book.set(-6, for: "a")
        if book.value(for: "a") != -6 { fail("early gain lost") }
        book.release("a")
        if book.value(for: "a") != nil { fail("released gain kept") }
        book.set(3, for: "a")
        if book.value(for: "a") != nil { fail("released id resurrected") }
        book.set(2, for: "b")
        if book.value(for: "b") != 2 { fail("other id affected") }

        print("ios_replay: all tests passed")
    }
}
