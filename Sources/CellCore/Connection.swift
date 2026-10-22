import Foundation
import simd

/// Dados recebidos de um robô/controlador em tempo real.
public struct RobotTelemetry: Equatable {
    public var timestamp: Date
    public var joints: JointState
    public var paintOn: Bool
    public var programName: String
    public var status: String
}

public enum ConnectionState: Equatable {
    case disconnected, connecting, connected, failed(String)
}

/// Contrato comum a todas as conexões. Os protocolos reais da Dürr (RPC/CommLib, OPC DA)
/// ficam para a fase de comunicação; por enquanto há o robô virtual e um cliente TCP genérico.
public protocol RobotConnection: AnyObject {
    var name: String { get }
    var onTelemetry: ((RobotTelemetry) -> Void)? { get set }
    var onState: ((ConnectionState) -> Void)? { get set }
    func connect()
    func disconnect()
}

/// Robô virtual: percorre uma trajetória em loop, útil para testar o monitor online sem planta.
public final class VirtualRobotConnection: RobotConnection {
    public let name = "Robô virtual"
    public var onTelemetry: ((RobotTelemetry) -> Void)?
    public var onState: ((ConnectionState) -> Void)?
    private var timer: Timer?
    private let samples: [TrajectorySample]
    private let programName: String
    private var i = 0

    public init(samples: [TrajectorySample], programName: String) {
        self.samples = samples
        self.programName = programName
    }

    public func connect() {
        onState?(.connecting)
        guard !samples.isEmpty else { onState?(.failed("Programa vazio")); return }
        onState?(.connected)
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            guard let self else { return }
            let s = self.samples[self.i % self.samples.count]
            self.i += 1
            self.onTelemetry?(RobotTelemetry(timestamp: Date(), joints: s.state, paintOn: s.paintOn, programName: self.programName, status: "AUTO – ponto \(s.pointIndex + 1)"))
        }
    }

    public func disconnect() {
        timer?.invalidate(); timer = nil
        onState?(.disconnected)
    }
}

/// Cliente TCP de texto: cada linha "J rail q1 q2 q3 q4 q5 q6 paint" atualiza o robô.
/// Serve de ponte para um gateway (ex.: um PC Windows rodando OPC) até termos os protocolos nativos.
public final class TCPLineConnection: RobotConnection {
    public var name: String { "TCP \(host):\(port)" }
    public var onTelemetry: ((RobotTelemetry) -> Void)?
    public var onState: ((ConnectionState) -> Void)?
    let host: String
    let port: Int
    private var input: InputStream?
    private var thread: Thread?
    private var running = false

    public init(host: String, port: Int) { self.host = host; self.port = port }

    public func connect() {
        onState?(.connecting)
        var inS: InputStream?, outS: OutputStream?
        Stream.getStreamsToHost(withName: host, port: port, inputStream: &inS, outputStream: &outS)
        guard let inS else { onState?(.failed("Não foi possível abrir \(host):\(port)")); return }
        input = inS
        running = true
        let t = Thread { [weak self] in self?.readLoop(inS) }
        thread = t
        t.start()
    }

    private func readLoop(_ s: InputStream) {
        s.open()
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        var announced = false
        while running {
            if s.streamStatus == .error || s.streamStatus == .atEnd {
                let msg = s.streamError?.localizedDescription ?? "Conexão encerrada"
                DispatchQueue.main.async { self.onState?(.failed(msg)) }
                return
            }
            if !s.hasBytesAvailable { Thread.sleep(forTimeInterval: 0.005); continue }
            if !announced { announced = true; DispatchQueue.main.async { self.onState?(.connected) } }
            let n = s.read(&bytes, maxLength: bytes.count)
            if n <= 0 { continue }
            buffer.append(bytes, count: n)
            while let nl = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                if let t = Self.parse(line) { DispatchQueue.main.async { self.onTelemetry?(t) } }
            }
        }
        s.close()
    }

    static func parse(_ line: String) -> RobotTelemetry? {
        let p = line.split(separator: " ")
        guard p.count >= 8, p[0] == "J" else { return nil }
        let v = p.dropFirst().compactMap { Double($0) }
        guard v.count >= 7 else { return nil }
        return RobotTelemetry(timestamp: Date(), joints: JointState(rail: v[0], q: Array(v[1...6])), paintOn: v.count > 7 && v[7] != 0, programName: "", status: "TCP")
    }

    public func disconnect() {
        running = false
        input?.close()
        onState?(.disconnected)
    }
}
