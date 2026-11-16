import SwiftUI
import AppKit
import T3ProxyCore

struct ClientSetupSnippets: View {
    let base: String
    @State private var copied: String?
    private static let keyPlaceholder = "<your client key>"
    var body: some View {
            Section {
                snippet("Claude Code", "export ANTHROPIC_BASE_URL='\(base)'\nexport ANTHROPIC_AUTH_TOKEN='\(Self.keyPlaceholder)'\nclaude")
                snippet("Codex (~/.codex/config.toml)", """
                    model_provider = "cliproxyapi"

                    [model_providers.cliproxyapi]
                    name = "CLIProxyAPI"
                    base_url = "\(base)/v1"
                    wire_api = "responses"
                    env_key = "CLIPROXYAPI_KEY"
                    """)
                snippet("Codex (shell)", "export CLIPROXYAPI_KEY='\(Self.keyPlaceholder)'\ncodex")
                snippet("OpenAI-compatible", "export OPENAI_BASE_URL='\(base)/v1'\nexport OPENAI_API_KEY='\(Self.keyPlaceholder)'")
            } header: {
                Text("Quick Start")
            } footer: {
                Text("Replace \(Self.keyPlaceholder) with one of the hub's client API keys (not the management key). T3 Proxy never shows or copies keys.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
    }
    private func snippet(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button(copied == title ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = title
                }
            }
            Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

}
