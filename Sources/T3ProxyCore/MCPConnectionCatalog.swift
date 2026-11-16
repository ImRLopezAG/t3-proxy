import Foundation

/// Public server definitions only; every addition receives its own account and credential identity.
public struct MCPConnectionPreset: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let endpoint: String
    public let authentication: MCPAuthentication
    public let documentation: String

    public func makeConnection(name: String? = nil, identity: String? = nil,
                               targets: [MCPClientTarget] = [.codex, .claude]) -> ServiceConnection {
        ServiceConnection(provider: .remoteMCP, name: name ?? self.name, identity: identity,
                          endpoint: endpoint, authentication: authentication, targets: targets)
    }
}

public enum MCPConnectionCatalog {
    // Provider documentation checked 2026-11-14. See docs/connectors.md for sources and verification limits.
    public static let presets: [MCPConnectionPreset] = [
        .init(id: "gmail-pipedream", name: "Gmail via Pipedream",
              summary: "Hosted by Pipedream; choose Gmail during browser sign-in",
              endpoint: "https://mcp.pipedream.net/v2", authentication: .oauth,
              documentation: "https://mcp.pipedream.com/app/gmail"),
        .init(id: "linear", name: "Linear", summary: "Issues, projects and teams",
              endpoint: "https://mcp.linear.app/mcp", authentication: .oauth,
              documentation: "https://linear.app/docs/mcp"),
        .init(id: "notion", name: "Notion", summary: "Pages, databases and workspace search",
              endpoint: "https://mcp.notion.com/mcp", authentication: .oauth,
              documentation: "https://developers.notion.com/docs/get-started-with-mcp"),
        .init(id: "github", name: "GitHub", summary: "Repositories, issues and pull requests",
              endpoint: "https://api.githubcopilot.com/mcp/", authentication: .bearer,
              documentation: "https://github.com/github/github-mcp-server/blob/main/docs/host-integration.md"),
        .init(id: "neon", name: "Neon", summary: "Postgres projects, branches and queries",
              endpoint: "https://mcp.neon.tech/mcp", authentication: .oauth,
              documentation: "https://neon.com/docs/ai/neon-mcp-server"),
        .init(id: "vercel", name: "Vercel", summary: "Projects, deployments and logs",
              endpoint: "https://mcp.vercel.com", authentication: .oauth,
              documentation: "https://vercel.com/docs/mcp/vercel-mcp"),
        .init(id: "workos", name: "WorkOS", summary: "Organizations, users and authentication",
              endpoint: "https://mcp.workos.com/mcp", authentication: .oauth,
              documentation: "https://workos.com/docs/mcp"),
        .init(id: "firecrawl", name: "Firecrawl", summary: "Web search, scraping and crawling",
              endpoint: "https://mcp.firecrawl.dev/v2/mcp-oauth", authentication: .oauth,
              documentation: "https://docs.firecrawl.dev/mcp-server"),
    ]
}
