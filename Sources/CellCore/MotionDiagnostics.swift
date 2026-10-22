import Foundation

// Erros e avisos de cinemática da simulação, como no DXQ:
// - Verificação de limites dos eixos: porte de `RcsDevice.CheckJointLimits` (ES_RCS.Simulation), inclusive a
//   correção ±360° em eixos rotativos (`tryToFix`).
// - Avisos configuráveis: `JointLimitWarningInfo` (margem por eixo) e `SingularityWarningState`
//   (|A5| mod 360 ≤ limite, `RobotTypeHelper.CalculateSingularityValue`). No DXQ ambos vêm desligados.
// - Erros do interpolador (MCU): códigos e textos de `McuErrors.ini` (500–575), recalculados aqui porque
//   o MCU original é código nativo do controlador.

public enum LimitCheck: Int, Comparable {
    case ok, warning, error
    public static func < (a: LimitCheck, b: LimitCheck) -> Bool { a.rawValue < b.rawValue }
}

public struct JointViolation: Hashable {
    /// índice do eixo principal (0 = A1) ou -1 = trilho (eixo auxiliar E1)
    public var joint: Int
    public var name: String
    public var unit: String
    public var value: Double
    public var min: Double
    public var max: Double

    /// Limite ultrapassado e quanto (em % da faixa do eixo).
    public var limit: Double { value > max ? max : min }
    public var excess: Double { value > max ? value - max : min - value }
    public var percent: Double { (max - min) > 0 ? excess / (max - min) * 100 : 0 }
    /// A1–A3 = eixos base, A4–A6 = punho (MCU 502/503/504)
    public var group: String { joint < 0 ? "auxiliar" : (joint < 3 ? "base" : "punho") }
}

public struct MotionIssue: Hashable {
    public enum Severity: Hashable { case error, warning, info }
    public enum Kind: Hashable {
        case positionNotReachable      // MCU 571
        case orientationNotReachable   // MCU 572
        case jointLimit                // MCU 536 – posição final do segmento fora do limite
        case jointLimitOnPath          // MCU 502/503/504 – limite ultrapassado durante o movimento
        case wristSingular             // MCU 574
        case jointVelocity             // MCU 507/508/509
        case jointLeap                 // MCU 545
        case jointLimitWarning         // DXQ Simulation_JointLimitWarning
        case singularityWarning        // DXQ Simulation_SingularityWarning
    }
    public var kind: Kind
    public var severity: Severity
    public var code: Int
    public var pointIndex: Int
    public var pointName: String
    public var time: Double
    public var text: String
}

/// Avisos configuráveis por robô (no DXQ: SimulationInfo → "Limites de aviso"). Desligados por padrão, como lá.
public struct SimulationWarningSettings: Codable, Hashable {
    public var enableJointLimitWarnings = false
    /// margem de aviso antes do limite, por eixo (A1…A6) – mínimo e máximo, na unidade do eixo
    public var jointWarningMin: [Double] = []
    public var jointWarningMax: [Double] = []
    public var railWarningMin = 0.0
    public var railWarningMax = 0.0
    /// |A5| ≤ este valor (graus) gera aviso de singularidade; 0 = desligado
    public var singularityWarningLimit = 0.0
    public init() {}
}

public enum JointLimits {
    static let eps = 1e-9

    /// Porte de `RcsDevice.CheckJointLimits(jointPosition, objectFrame, tryToFix)`:
    /// eixo fora do limite → erro; com `tryToFix`, eixo rotativo é trazido ±360° se couber.
    @discardableResult
    public static func check(_ s: inout JointState, robot: RobotModel, tryToFix: Bool = false) -> (LimitCheck, [JointViolation]) {
        var result = LimitCheck.ok
        var violations: [JointViolation] = []
        for (i, j) in robot.joints.enumerated() where i < s.q.count {
            let v = s.q[i]
            let belowMax = v <= j.max + eps
            let aboveMin = v >= j.min - eps
            if belowMax && aboveMin { continue }
            if tryToFix && j.kind == .revolute {
                if belowMax && v + 360 <= j.max { s.q[i] += 360; continue }
                if aboveMin && v - 360 >= j.min { s.q[i] -= 360; continue }
            }
            result = .error
            violations.append(JointViolation(joint: i, name: j.name, unit: j.kind == .revolute ? "°" : "mm", value: v, min: j.min, max: j.max))
        }
        if robot.railEnabled, s.rail > robot.railMax + eps || s.rail < robot.railMin - eps {
            result = .error
            violations.append(JointViolation(joint: -1, name: "E1", unit: "mm", value: s.rail, min: robot.railMin, max: robot.railMax))
        }
        return (result, violations)
    }

    /// `CheckUserDefinedWarningLimits` / `CheckAndRaiseWarnings`: eixos dentro da margem de aviso e singularidade.
    public static func warnings(_ s: JointState, robot: RobotModel, settings: SimulationWarningSettings) -> [String] {
        var out: [String] = []
        if settings.singularityWarningLimit > 0, s.q.count > 4 {
            let value = abs(s.q[4]).truncatingRemainder(dividingBy: 360)
            if value <= settings.singularityWarningLimit {
                out.append(String(format: "Robô próximo de uma singularidade (limite %.0f°, valor atual %.1f°)", settings.singularityWarningLimit, value))
            }
        }
        guard settings.enableJointLimitWarnings else { return out }
        func check(_ name: String, _ unit: String, _ v: Double, _ min: Double, _ max: Double, _ offMin: Double, _ offMax: Double) {
            guard offMin > 0 || offMax > 0 else { return }       // JointLimitWarningInfo.IsEnabled
            let wMin = min + offMin, wMax = max - offMax
            if v >= wMax || v <= wMin {
                out.append(String(format: "Eixo '%@' atingiu o limite de aviso: %.3f%@, mín. %.3f%@, máx. %.3f%@", name, v, unit, wMin, unit, wMax, unit))
            }
        }
        for (i, j) in robot.joints.enumerated() where i < s.q.count {
            check(j.name, j.kind == .revolute ? "°" : "mm", s.q[i], j.min, j.max,
                  i < settings.jointWarningMin.count ? settings.jointWarningMin[i] : 0,
                  i < settings.jointWarningMax.count ? settings.jointWarningMax[i] : 0)
        }
        if robot.railEnabled { check("E1", "mm", s.rail, robot.railMin, robot.railMax, settings.railWarningMin, settings.railWarningMax) }
        return out
    }
}

/// Textos (pt-BR) dos erros do MCU usados pela simulação. Número = chave em McuErrors.ini.
public enum McuMessage {
    static func n(_ v: Double) -> String { String(format: "%.2f", v) }

    public static func jointLimitAtEnd(_ v: JointViolation, segment: String, kinematic: String) -> (Int, String) {
        (536, "Posição final do segmento \(segment) excede o limite do eixo \(v.name) em \(String(format: "%.1f", v.percent)) % " +
              "(valor: \(n(v.value))\(v.unit), limite: \(n(v.limit))\(v.unit)) da cinemática \(kinematic)")
    }

    public static func jointLimitOnPath(_ v: JointViolation, command: String) -> (Int, String) {
        let code = v.joint < 0 ? 504 : (v.joint < 3 ? 502 : 503)
        return (code, "Posição do eixo \(v.group) \(v.name) excede o limite (\(n(v.limit))\(v.unit)); valor: \(n(v.value))\(v.unit), comando de movimento \(command)")
    }

    public static func positionNotReachable(kinematic: String, at: String) -> (Int, String) {
        (571, "Posição não alcançável pela cinemática \(kinematic) em \(at)")
    }

    public static func orientationNotReachable(kinematic: String, at: String) -> (Int, String) {
        (572, "Orientação não alcançável pela cinemática \(kinematic) em \(at)")
    }

    public static func wristSingular(kinematic: String, at: String) -> (Int, String) {
        (574, "Eixos do punho da cinemática \(kinematic) estão singulares em \(at)")
    }

    public static func jointVelocity(joint: Int, name: String, unit: String, value: Double, limit: Double, command: String) -> (Int, String) {
        let code = joint < 0 ? 509 : (joint < 3 ? 507 : 508)
        let group = joint < 0 ? "eixo auxiliar" : (joint < 3 ? "eixo base" : "eixo do punho")
        let pct = limit > 0 ? (value - limit) / limit * 100 : 0
        return (code, "Velocidade do eixo excede o limite em \(String(format: "%.0f", pct)) %, \(group): \(name); valor: \(n(value))\(unit)/s, limite: \(n(limit))\(unit)/s, comando de movimento \(command)")
    }

    public static func jointLeap(kinematic: String, name: String, from: Double, to: Double, at: String) -> (Int, String) {
        (545, "Eixo \(name) da cinemática \(kinematic) salta da posição \(n(from)) para \(n(to)) em \(at)")
    }
}
