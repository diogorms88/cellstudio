#if os(iOS)
import Foundation
import Security
import UIKit

/// Conversa com o Claude pela API (iPhone). As mesmas ferramentas do servidor MCP do Mac
/// (MCPTools) rodam aqui dentro do app; o laço segue enquanto o Claude pedir ferramentas.
@MainActor
final class ClaudeAPIChat {
    static let model = "claude-opus-5-5"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// histórico enviado à API (conteúdo das respostas volta inteiro, inclusive blocos de raciocínio)
    private var history: [[String: Any]] = []

    func reset() { history = [] }

    func send(_ prompt: String, emit: @escaping (ChatMessage) -> Void) async {
        guard let key = Self.apiKey, !key.isEmpty else {
            emit(ChatMessage(role: .error, text: "Informe a chave da API do Claude (botão \"Chave da API\")."))
            return
        }
        let start = history.count
        history.append(["role": "user", "content": prompt])
        let tools = MCPTools.definitions.map { d -> [String: Any] in
            ["name": d["name"] ?? "", "description": d["description"] ?? "", "input_schema": d["inputSchema"] ?? [:]]
        }
        for _ in 0..<40 {
            if Task.isCancelled { emit(ChatMessage(role: .error, text: "Interrompido")); return }
            let body: [String: Any] = [
                "model": Self.model, "max_tokens": 16000,
                "system": ClaudeChat.rules,
                "thinking": ["type": "adaptive"],
                "output_config": ["effort": "high"],
                "fallbacks": "default",
                "tools": tools, "messages": history,
            ]
            let response: [String: Any]
            do { response = try await Self.post(body, key: key) } catch {
                history.removeSubrange(start...)     // a pergunta pode ser repetida do zero
                emit(ChatMessage(role: .error, text: error.localizedDescription))
                return
            }
            let content = response["content"] as? [[String: Any]] ?? []
            history.append(["role": "assistant", "content": content])
            var calls: [(id: String, name: String, input: [String: Any])] = []
            for c in content {
                switch c["type"] as? String {
                case "text":
                    if let t = c["text"] as? String, !t.isEmpty { emit(ChatMessage(role: .assistant, text: t)) }
                case "tool_use":
                    let name = c["name"] as? String ?? ""
                    calls.append((c["id"] as? String ?? "", name, c["input"] as? [String: Any] ?? [:]))
                    emit(ChatMessage(role: .tool, text: name))
                default: break
                }
            }
            switch response["stop_reason"] as? String {
            case "tool_use":
                // todas as respostas das ferramentas vão juntas numa só mensagem
                var results: [[String: Any]] = []
                for call in calls {
                    let (text, isError) = await MCPTools.call(call.name, call.input)
                    results.append(["type": "tool_result", "tool_use_id": call.id, "content": text, "is_error": isError])
                }
                history.append(["role": "user", "content": results])
            case "refusal":
                let why = (response["stop_details"] as? [String: Any])?["explanation"] as? String
                emit(ChatMessage(role: .error, text: "O Claude recusou o pedido" + (why.map { ": \($0)" } ?? ".")))
                return
            case "max_tokens":
                emit(ChatMessage(role: .error, text: "Resposta cortada no limite de tamanho."))
                return
            default:
                return
            }
        }
        emit(ChatMessage(role: .error, text: "Muitas chamadas de ferramenta seguidas; parei aqui."))
    }

    private static func post(_ body: [String: Any], key: String) async throws -> [String: Any] {
        var req = URLRequest(url: endpoint, timeoutInterval: 600)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self)
            let hint = switch status {
            case 401: " (chave da API inválida)"
            case 429: " (limite de uso; tente de novo em instantes)"
            case 500...: " (erro temporário do serviço)"
            default: ""
            }
            throw NSError(domain: "ClaudeAPI", code: status, userInfo: [NSLocalizedDescriptionKey: "API do Claude \(status)\(hint): \(msg)"])
        }
        return json
    }

    // MARK: Chave da API (Keychain do aparelho)

    private static let account = "anthropic-api-key"

    static var apiKey: String? {
        get {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
            return String(data: d, encoding: .utf8)
        }
        set {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
            SecItemDelete(q as CFDictionary)
            guard let v = newValue, !v.isEmpty else { return }
            var add = q
            add[kSecValueData as String] = Data(v.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func askForKey() {
        let current = apiKey.map { _ in "(guardada – digite outra para trocar)" } ?? ""
        if let k = Dialogs.prompt("Chave da API do Claude", "Crie em console.anthropic.com ▸ API Keys. Fica só no Keychain deste aparelho. \(current)",
                                  value: "", ok: "Salvar") {
            apiKey = k
            AppState.shared?.info("Chave da API do Claude salva no aparelho")
        }
    }
}
#endif
