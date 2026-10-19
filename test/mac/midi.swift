// CoreMIDI test helper for the MPC's USB MIDI port.
//   swift midi.swift list
//   swift midi.swift send <seconds> [match=MPC]   — MIDI clock (24 ppqn @120 bpm) + a note every 0.5 s to the matching destination
//   swift midi.swift listen <seconds> [match=MPC] — count bytes/messages arriving from the matching source
import CoreMIDI
import Foundation

func name(_ obj: MIDIObjectRef) -> String {
    var s: Unmanaged<CFString>?; MIDIObjectGetStringProperty(obj, kMIDIPropertyDisplayName, &s)
    return (s?.takeRetainedValue() as String?) ?? "?"
}
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "list"
let secs = args.count > 2 ? Double(args[2]) ?? 5 : 5
let match = args.count > 3 ? args[3] : "MPC"
var client = MIDIClientRef(); MIDIClientCreate("mpcaudio-test" as CFString, nil, nil, &client)

if mode == "list" {
    for i in 0..<MIDIGetNumberOfDestinations() { print("dest[\(i)]: \(name(MIDIGetDestination(i)))") }
    for i in 0..<MIDIGetNumberOfSources() { print("src[\(i)]: \(name(MIDIGetSource(i)))") }
    exit(0)
}
if mode == "send" {
    guard let dest = (0..<MIDIGetNumberOfDestinations()).map({ MIDIGetDestination($0) }).first(where: { name($0).contains(match) }) else { print("no destination matching \(match)"); exit(1) }
    var port = MIDIPortRef(); MIDIOutputPortCreate(client, "out" as CFString, &port)
    func send(_ bytes: [UInt8]) {
        var list = MIDIPacketList(); let pkt = MIDIPacketListInit(&list)
        _ = MIDIPacketListAdd(&list, 1024, pkt, 0, bytes.count, bytes); MIDISend(port, dest, &list)
    }
    print("sending to \(name(dest)) for \(secs)s"); send([0xFA])              // start
    let t0 = Date(); var ticks = 0, notes = 0
    while Date().timeIntervalSince(t0) < secs {
        send([0xF8]); ticks += 1                                             // clock: 48/s at 120 bpm
        if ticks % 24 == 0 { send([0x90, 60, 100]); notes += 1 }             // note on every beat (0.5 s)
        if ticks % 24 == 12 { send([0x80, 60, 0]) }                          // note off half a beat later
        Thread.sleep(forTimeInterval: 1.0 / 48.0)
    }
    send([0xFC]); send([0xB0, 123, 0])                                       // stop + all notes off
    print("sent \(ticks) clocks, \(notes) notes")
    exit(0)
}
if mode == "listen" {
    guard let src = (0..<MIDIGetNumberOfSources()).map({ MIDIGetSource($0) }).first(where: { name($0).contains(match) }) else { print("no source matching \(match)"); exit(1) }
    var bytes = 0, pkts = 0
    var port = MIDIPortRef()
    MIDIInputPortCreateWithBlock(client, "in" as CFString, &port) { list, _ in
        var p = list.pointee.packet
        for _ in 0..<list.pointee.numPackets { pkts += 1; bytes += Int(p.length); p = MIDIPacketNext(&p).pointee }
    }
    MIDIPortConnectSource(port, src, nil)
    print("listening to \(name(src)) for \(secs)s")
    RunLoop.main.run(until: Date().addingTimeInterval(secs))
    print("received \(pkts) packets, \(bytes) bytes"); exit(0)
}
