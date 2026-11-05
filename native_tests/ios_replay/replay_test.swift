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

        // A layout carries its own gains, so it supersedes every earlier
        // graphic gain call; a later set-all-bands still replays after it.
        let lay = DSPReplayLog()
        let l = FakeEngine()
        let gainFamily = ["setGraphicBandGain.", "setGraphicAllBands"]
        lay.record(key: "preamp") { engine($0).applied.append("preamp") }
        lay.record(key: "setGraphicAllBands") { engine($0).applied.append("allBands(A)") }
        lay.record(key: "setGraphicBandGain.3") { engine($0).applied.append("bandGain(3)=x") }
        lay.record(key: "setGraphicLayout", superseding: gainFamily) {
            engine($0).applied.append("layout(L)")
        }
        lay.record(key: "setGraphicAllBands") { engine($0).applied.append("allBands(B)") }
        lay.replay(onto: Unmanaged.passUnretained(l).toOpaque())
        let layExpected = ["preamp", "layout(L)", "allBands(B)"]
        if l.applied != layExpected { fail("layout_supersedes_gains: \(l.applied), expected \(layExpected)") }

        // A second layout supersedes the set-all-bands recorded after the first.
        lay.record(key: "setGraphicLayout", superseding: gainFamily) {
            engine($0).applied.append("layout(M)")
        }
        let l2 = FakeEngine()
        lay.replay(onto: Unmanaged.passUnretained(l2).toOpaque())
        let lay2Expected = ["preamp", "layout(M)"]
        if l2.applied != lay2Expected { fail("second layout: \(l2.applied), expected \(lay2Expected)") }
        if lay.count != 2 { fail("layout log count \(lay.count)") }

        // A prefix that matches nothing leaves the log alone.
        lay.record(key: "mono", superseding: ["nothing."]) { engine($0).applied.append("mono") }
        if lay.count != 3 { fail("unmatched superseding count \(lay.count)") }

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

        // Gapless next-gain keys: however the Dart side escapes a file name,
        // it must land on the key the item's tap derives (the path rebuilt
        // with fileURLWithPath), and re-normalising must change nothing.
        let names = [
            "Beyonc\u{E9}", "Beyonce\u{301}",      // NFC and NFD
            "na\u{EF}ve",
            "\u{D55C}\u{AE00}",                    // Hangul (NFC)
            "\u{1112}\u{1161}\u{11AB}",           // Hangul (jamo)
            "a;b", "a b", "a#b", "a%b", "a?b",
        ]
        for name in names {
            let path = "/Music/\(name).mp3"
            let allowed = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
            let strict = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "/.")))!
            let tapKey = URL(fileURLWithPath: path).absoluteString
            for form in ["file://" + path, "file://" + allowed, "file://" + strict, tapKey] {
                let key = NextGainKey.normalize(form)
                if key != tapKey { fail("key for \(name) via \(form): \(key) != \(tapKey)") }
                if NextGainKey.normalize(key) != key { fail("not idempotent for \(name)") }
            }
        }
        if NextGainKey.normalize("https://x.test/a%20b.mp3?x=1") != "https://x.test/a%20b.mp3?x=1" {
            fail("http key changed")
        }

        // System output volume (linear 0...1) -> dB, floored at -96.
        func near(_ a: Float, _ b: Float, _ tol: Float = 1e-3) -> Bool { abs(a - b) <= tol }
        if !near(SystemVolume.db(fromOutputVolume: 1.0), 0.0) { fail("system_volume_db 1.0") }
        if !near(SystemVolume.db(fromOutputVolume: 0.5), -6.0206) { fail("system_volume_db 0.5") }
        if SystemVolume.db(fromOutputVolume: 0.0) != -96 { fail("system_volume_db 0.0") }
        if SystemVolume.db(fromOutputVolume: 1e-6) != -96 { fail("system_volume_db 1e-6") }
        if SystemVolume.db(fromOutputVolume: -1) != -96 { fail("system_volume_db negative") }

        print("ios_replay: all tests passed")
    }
}
