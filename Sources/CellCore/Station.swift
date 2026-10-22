import Foundation

/// Bits de colisão da estação, com a mesma regra do simulador do DXQ (`ES_RCS.Simulation…IO.CollisionBits`):
/// - o bit é um "dono de zona" compartilhado entre os robôs da estação (mesmo nome = mesma zona);
/// - `SET(bit, High)` pede a zona: se livre, o robô vira dono; se tem dono, o pedido fica na fila
///   (ordem: tempo, depois nome do robô) até o dono liberar com `SET(bit, Low)`;
/// - `RECEIVE(bit, High)` só passa para o dono; `RECEIVE(bit, Low)` passa se a zona está livre ou é de outro;
/// - quando um robô termina o programa, as zonas dele são liberadas.
public final class CollisionBits {
    struct Info { var owner: String?; var high: Bool? }
    struct Request { var robot: String; var high: Bool; var time: Double }

    public struct Change: Hashable {
        public var time: Double
        public var pin: String
        public var owner: String?
        public var previousOwner: String?
        public var high: Bool
    }

    var bits: [String: Info] = [:]
    var queue: [String: [Request]] = [:]
    var pending: [String: [String: Int]] = [:]   // robô → bit → pedidos ainda não processados

    public init() {}

    public func set(robot: String, pin: String, high: Bool, time: Double) {
        if bits[pin] == nil { bits[pin] = Info() }
        var q = queue[pin, default: []]
        let r = Request(robot: robot, high: high, time: time)
        let at = q.firstIndex { $0.time > time || ($0.time == time && $0.robot > robot) } ?? q.count
        q.insert(r, at: at)
        queue[pin] = q
        pending[robot, default: [:]][pin, default: 0] += 1
    }

    public func hasPending(robot: String, pin: String) -> Bool { (pending[robot]?[pin] ?? 0) > 0 }

    public func receive(robot: String, pin: String, high: Bool) -> Bool {
        guard let info = bits[pin] else { return !high }
        if high { return info.owner == robot && info.high == true }
        if info.owner != nil || info.high != false { return info.owner != robot }
        return true
    }

    public func owner(_ pin: String) -> String? { bits[pin]?.owner }

    /// Bits atualmente com dono, por robô.
    public func owned(by robot: String) -> [String] {
        bits.filter { $0.value.owner == robot }.map(\.key).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func consumed(_ r: Request, _ pin: String) {
        if let n = pending[r.robot]?[pin] { pending[r.robot]?[pin] = max(0, n - 1) }
    }

    private func dequeue(_ pin: String) -> Request? {
        guard var q = queue[pin], !q.isEmpty else { return nil }
        let info = bits[pin] ?? Info()
        defer { queue[pin] = q }
        if let owner = info.owner {
            guard let i = q.firstIndex(where: { $0.robot == owner }) else { return nil }
            return q.remove(at: i)
        }
        while !q.isEmpty {
            let r = q.removeFirst()
            if info.high == true || r.high { return r }
            consumed(r, pin)          // "Low" com a zona livre: nada a fazer
        }
        return nil
    }

    /// Processa a fila; devolve as mudanças de dono.
    @discardableResult
    public func update() -> [Change] {
        var changes: [Change] = []
        for pin in bits.keys.sorted() {
            while let r = dequeue(pin) {
                consumed(r, pin)
                let prev = bits[pin]?.owner
                bits[pin] = Info(owner: r.high ? r.robot : nil, high: r.high)
                changes.append(Change(time: r.time, pin: pin, owner: r.high ? r.robot : nil, previousOwner: prev, high: r.high))
            }
        }
        return changes
    }

    /// Robô terminou o programa: libera as zonas que ele detém.
    public func release(robot: String, time: Double) {
        for pin in owned(by: robot) { set(robot: robot, pin: pin, high: false, time: time) }
    }
}

/// Simulação conjunta da estação: cada robô percorre sua trajetória, executando SET/RECEIVE/DELAY
/// no relógio comum; quem espera um bit fica parado no lugar.
public enum StationScheduler {
    public struct Input {
        public var robot: String
        public var samples: [TrajectorySample]     // trajetória sem esperas (Trajectory.sample)
        public var actions: [EcoTalkSyncAction]
        public var pointCount: Int
        public var start: JointState
        public init(robot: String, samples: [TrajectorySample], actions: [EcoTalkSyncAction], pointCount: Int, start: JointState) {
            self.robot = robot; self.samples = samples; self.actions = actions; self.pointCount = pointCount; self.start = start
        }
    }

    public struct Event: Hashable {
        public enum Kind: Hashable { case claimed, released, waiting, resumed, deadlock, finished }
        public var time: Double
        public var robot: String
        public var kind: Kind
        public var pin: String
        public var text: String
    }

    /// Período em que um robô foi dono de uma zona (bit High).
    public struct ZoneInterval: Hashable {
        public var pin: String
        public var owner: String
        public var start: Double
        public var end: Double
    }

    /// Período em que um robô ficou parado num RECEIVE esperando um bit.
    public struct WaitInterval: Hashable {
        public var robot: String
        public var pin: String
        public var high: Bool
        public var start: Double
        public var end: Double
        public var blockedBy: String?
        public var program: String
        public var line: Int
        public var forced: Bool
    }

    public struct Output {
        public var samples: [String: [TrajectorySample]]
        public var events: [Event]
        public var duration: Double
        public var waitTime: [String: Double]
        public var zones: [ZoneInterval] = []
        public var waits: [WaitInterval] = []
    }

    enum Step { case motion(Range<Int>), set(EcoTalkSyncAction), receive(EcoTalkSyncAction), delay(EcoTalkSyncAction) }

    static func steps(_ inp: Input) -> [Step] {
        // amostras contíguas por ponto
        var ranges: [Int: Range<Int>] = [:]
        var i = 0
        while i < inp.samples.count {
            let k = inp.samples[i].pointIndex
            var j = i
            while j < inp.samples.count && inp.samples[j].pointIndex == k { j += 1 }
            ranges[k] = i..<j
            i = j
        }
        var out: [Step] = []
        let byPoint = Dictionary(grouping: inp.actions, by: \.afterPoint)
        for k in 0...max(inp.pointCount, 0) {
            for a in byPoint[k] ?? [] {
                switch a.kind {
                case .set: out.append(.set(a))
                case .receive: out.append(.receive(a))
                case .delay: out.append(.delay(a))
                }
            }
            if k < inp.pointCount, let r = ranges[k] { out.append(.motion(r)) }
        }
        return out
    }

    public static func run(_ inputs: [Input], dt: Double = 0.02, deadlockAfter: Double = 30, maxTime: Double = 7200) -> Output {
        struct Track {
            var steps: [Step]
            var cursor = 0
            var offset = 0          // amostra dentro do movimento
            var delayLeft: Double?
            var state: JointState
            var point = 0
            var brush = 1
            var waitingSince: Double?
            var waitPin = ""
            var waitAction: EcoTalkSyncAction?
            var waitOwner: String?
            var finished = false
        }
        let order = inputs.sorted { $0.robot < $1.robot }
        var tracks = order.map { Track(steps: steps($0), state: $0.start) }
        var out: [String: [TrajectorySample]] = Dictionary(uniqueKeysWithValues: order.map { ($0.robot, []) })
        var waitTime: [String: Double] = [:]
        var events: [Event] = []
        let bits = CollisionBits()
        var t = 0.0
        var stalled = 0.0
        var zones: [ZoneInterval] = []
        var waits: [WaitInterval] = []
        var openZone: [String: (owner: String, start: Double)] = [:]

        while tracks.contains(where: { !$0.finished }) && t < maxTime {
            t += dt
            var progressed = false
            for (ri, inp) in order.enumerated() {
                var tr = tracks[ri]
                if tr.finished { continue }
                var emitted = false
                loop: while true {
                    guard tr.cursor < tr.steps.count else {
                        tr.finished = true
                        bits.release(robot: inp.robot, time: t)
                        events.append(Event(time: t, robot: inp.robot, kind: .finished, pin: "", text: "\(inp.robot): fim do programa"))
                        break loop
                    }
                    switch tr.steps[tr.cursor] {
                    case .set(let a):
                        bits.set(robot: inp.robot, pin: a.pin, high: a.high, time: t)
                        tr.cursor += 1; progressed = true
                    case .receive(let a):
                        let ok = !bits.hasPending(robot: inp.robot, pin: a.pin) && bits.receive(robot: inp.robot, pin: a.pin, high: a.high)
                        if ok {
                            if let since = tr.waitingSince {
                                if t - since > 0.1 {
                                    waitTime[inp.robot, default: 0] += t - since
                                    let who = tr.waitPin.isEmpty ? "" : tr.waitPin
                                    events.append(Event(time: since, robot: inp.robot, kind: .waiting, pin: a.pin,
                                                        text: "\(inp.robot) parado aguardando \(who) \(a.high ? "High" : "Low") – \(a.program):\(a.line)"))
                                    events.append(Event(time: t, robot: inp.robot, kind: .resumed, pin: a.pin,
                                                        text: String(format: "%@ liberado em %@ após %.1f s", inp.robot, a.pin, t - since)))
                                    waits.append(WaitInterval(robot: inp.robot, pin: a.pin, high: a.high, start: since, end: t,
                                                              blockedBy: tr.waitOwner, program: a.program, line: a.line, forced: false))
                                }
                            }
                            tr.waitingSince = nil
                            tr.cursor += 1; progressed = true
                        } else {
                            if tr.waitingSince != nil && tr.waitOwner == nil { tr.waitOwner = bits.owner(a.pin) }   // dono definido no mesmo passo
                            if tr.waitingSince == nil {
                                tr.waitingSince = t
                                tr.waitAction = a
                                tr.waitOwner = bits.owner(a.pin)
                                tr.waitPin = a.pin + (bits.owner(a.pin).map { " (zona com \($0))" } ?? "")
                            }
                            break loop
                        }
                    case .delay(let a):
                        let left = (tr.delayLeft ?? a.seconds) - dt
                        progressed = true
                        if left <= 1e-9 { tr.delayLeft = nil; tr.cursor += 1 } else { tr.delayLeft = left }
                        break loop
                    case .motion(let r):
                        let s = inp.samples[r.lowerBound + tr.offset]
                        tr.state = s.state; tr.point = s.pointIndex; tr.brush = s.brush
                        var ns = s; ns.time = t
                        out[inp.robot]!.append(ns)
                        emitted = true; progressed = true
                        tr.offset += 1
                        if r.lowerBound + tr.offset >= r.upperBound { tr.offset = 0; tr.cursor += 1 }
                        break loop
                    }
                }
                if !emitted {
                    // parado (espera/DELAY/fim): mantém a pose
                    out[inp.robot]!.append(TrajectorySample(time: t, state: tr.state, paintOn: false, brush: tr.brush, pointIndex: tr.point))
                }
                tracks[ri] = tr
            }
            for c in bits.update() {
                // novo SET High do próprio dono não abre outra zona (mantém o trecho contínuo)
                if c.high, let o = c.owner, openZone[c.pin]?.owner == o { continue }
                if let z = openZone.removeValue(forKey: c.pin) {
                    zones.append(ZoneInterval(pin: c.pin, owner: z.owner, start: z.start, end: t))
                }
                if c.high, let o = c.owner { openZone[c.pin] = (o, t) }
                if c.high, let o = c.owner {
                    events.append(Event(time: t, robot: o, kind: .claimed, pin: c.pin, text: "\(o) assumiu a zona \(c.pin)"))
                } else if let p = c.previousOwner {
                    events.append(Event(time: t, robot: p, kind: .released, pin: c.pin, text: "\(p) liberou a zona \(c.pin)"))
                }
            }
            // impasse: todos os que faltam estão esperando bits
            if progressed { stalled = 0 } else {
                stalled += dt
                if stalled >= deadlockAfter {
                    let waiting = tracks.indices.filter { !tracks[$0].finished && tracks[$0].waitingSince != nil }
                    let desc = waiting.map { "\(order[$0].robot) espera \(tracks[$0].waitPin)" }.joined(separator: ", ")
                    events.append(Event(time: t, robot: "", kind: .deadlock, pin: "",
                                        text: "Impasse de bits de colisão: \(desc). Forçando a passagem do primeiro para continuar a simulação."))
                    if let first = waiting.min(by: { (tracks[$0].waitingSince ?? 0) < (tracks[$1].waitingSince ?? 0) }) {
                        waitTime[order[first].robot, default: 0] += t - (tracks[first].waitingSince ?? t)
                        if let a = tracks[first].waitAction {
                            waits.append(WaitInterval(robot: order[first].robot, pin: a.pin, high: a.high,
                                                      start: tracks[first].waitingSince ?? t, end: t, blockedBy: tracks[first].waitOwner,
                                                      program: a.program, line: a.line, forced: true))
                        }
                        tracks[first].waitingSince = nil
                        tracks[first].cursor += 1
                    }
                    stalled = 0
                }
            }
        }
        for (pin, z) in openZone { zones.append(ZoneInterval(pin: pin, owner: z.owner, start: z.start, end: t)) }
        events.sort { $0.time < $1.time }
        return Output(samples: out, events: events, duration: t, waitTime: waitTime,
                      zones: zones.sorted { ($0.pin, $0.start) < ($1.pin, $1.start) }, waits: waits.sorted { $0.start < $1.start })
    }
}
