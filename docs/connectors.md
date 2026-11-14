# MCP connection manager

T3 Proxy manages existing MCP connections and shares each account binding between selected clients.
It does not implement Gmail or other service APIs and does not publish an aggregate connector toolkit.

The native manager stores connection metadata in `~/Library/Application Support/T3 Proxy/Connectors/`.
Each immutable connection UUID determines a unique MCP server name and private runtime home. Both client
registrations invoke the same bundled connection helper with that UUID. The helper uses the installed
Codex app-server's MCP transport and authentication, never `turn/start`. Tool definitions, structured
results, images and embedded attachment resources are forwarded from the existing MCP server. Resource
listing and reads are supported; prompts, subscriptions and interactive elicitation are not.

Bearer tokens and local credential variables live in T3 Proxy Keychain items. Codex owns MCP OAuth in
Keychain. Its OAuth identity includes the unique server name and endpoint; separate connections to the
same URL therefore keep separate grants. Original client OAuth files are never read or copied by the
manager. The transport subprocess receives an allowlisted environment plus the selected connection's
credentials. Inference uses the existing proxy clients and hub, independently of these accounts.

Setup preserves existing client configuration and T3 fields, makes private backups before replacement,
refuses symlinked configuration paths, and only replaces marked/recognized managed entries. Configuration
changes need fresh client sessions. Removing a connection also stops existing relays from forwarding its
next request; revoke provider consent separately when needed.

## Quick connections

Settings → Connectors → Add MCP Connection offers a searchable list. Selecting a service fills in its
documented endpoint and authentication method. You can rename the connection, identify its account or
workspace, and choose either or both proxy clients. Adding it again creates a separate connection UUID.
OAuth sign-in remains an explicit action after saving. Custom MCP retains manual HTTP and local stdio setup.
Choosing another service clears any token and local credential fields in the unsaved form.

Provider definitions checked against these first-party sources on 2026-11-14:

| Service | Endpoint | Authentication | Source |
| --- | --- | --- | --- |
| Gmail via Pipedream | `https://mcp.pipedream.net/v2` | OAuth | [Pipedream Gmail](https://mcp.pipedream.com/app/gmail), [MCP setup](https://pipedream.com/docs/connect/mcp/users) |
| Linear | `https://mcp.linear.app/mcp` | OAuth | [Linear](https://linear.app/docs/mcp) |
| Notion | `https://mcp.notion.com/mcp` | OAuth | [Notion](https://developers.notion.com/docs/get-started-with-mcp) |
| GitHub | `https://api.githubcopilot.com/mcp/` | Bearer token | [GitHub hosted server](https://github.com/github/github-mcp-server/blob/main/docs/remote-server.md), [authentication](https://github.com/github/github-mcp-server/blob/main/docs/host-integration.md) |
| Neon | `https://mcp.neon.tech/mcp` | OAuth | [Neon](https://neon.com/docs/ai/neon-mcp-server) |
| Vercel | `https://mcp.vercel.com` | OAuth | [Vercel](https://vercel.com/docs/mcp/vercel-mcp) |
| WorkOS | `https://mcp.workos.com/mcp` | OAuth | [WorkOS](https://workos.com/docs/mcp) |
| Firecrawl | `https://mcp.firecrawl.dev/v2/mcp-oauth` | OAuth | [Firecrawl](https://docs.firecrawl.dev/mcp-server) |

GitHub accepts personal access tokens; browser OAuth requires a registered client, which this manager
does not supply. Choose token permissions appropriate to the repositories you want to access. The
Firecrawl preset uses its OAuth endpoint; API keys are never placed in URLs. Convex's documented MCP
uses a local CLI and project directory, so it remains available through Custom MCP.

The Gmail preset is explicitly hosted by Pipedream, an external service. Pipedream documents a shared
MCP endpoint and browser flow: sign in or create a Pipedream MCP account, select the apps to enable,
then authorize access. Choose Gmail and the intended Google account in that flow. This uses the existing
MCP service rather than a T3-built Gmail integration and does not require your own Google Cloud OAuth
client. The shared endpoint can expose other apps you authorize; the preset does not filter its tools
to Gmail. Separate T3 connection UUIDs isolate local grants, but do not prove separate upstream Gmail
account selection. Verify the returned identity and actual tools for each connection before using it.
Pipedream's account requirements, terms and permissions apply. Alternative Gmail MCP servers remain
available through Custom MCP; a ChatGPT/Claude Gmail web connection is not a server URL.

This catalog verifies provider documentation, not live account access. Endpoints, client registration
requirements and tool availability can change. Successful sign-in, discovery and authorized tool calls
must be verified separately for each real account. Merely choosing or saving a preset proves none of these.

## Evidence and prerequisites

Verified installed-client characterization on 2026-11-14: Codex 0.169.0 accepted a private MCP-only home,
an ephemeral thread, `mcpServerStatus/list` and `mcpServer/tool/call` against a local fixture server, without
a model turn or ChatGPT account. The bundled relay also passed actual Codex discovery/calls and Claude
Code 2.1.325 connection checks. A fresh Claude session using the existing proxy inference settings called
the fixture tool and received its result. These are fixture checks, not Gmail access or real OAuth grants.

Tests cover idempotent setup, existing configuration preservation, target selection, removal, separate
accounts at one URL, unchanged upstream tool definitions and attachment payloads, and refusal to route a
removed or unknown connection. Fixture results are not live service data.

Protocol optional fields emitted as null by app-server are omitted for MCP client compatibility; arbitrary
schema and service payload nulls are preserved. Input reading continues during calls so cancellation can
retire the owned transport. A cancelled or timed-out remote action may already have completed; the relay
does not automatically retry it. Tools use a 600-second upstream limit with a 610-second transport limit,
separate from discovery checks. Setup permits cancellation before its commit boundary; applying prepared
configuration writes finishes with Cancel disabled in the panel.

Supported interfaces used:

- [Codex MCP configuration and OAuth](https://developers.openai.com/codex/mcp/).
- Installed `codex app-server generate-json-schema --experimental`: thread/start, mcpServerStatus/list,
  mcpServer/tool/call, mcpServer/resource/read, mcpServer/oauth/login and OAuth completion notifications.
- [Upstream OAuth credential storage](https://github.com/openai/codex/blob/main/codex-rs/rmcp-client/src/oauth/credential_store.rs):
  source evidence for server-name/endpoint identity; upstream can differ from the installed version.
- [Claude MCP configuration](https://code.claude.com/docs/en/mcp): stdio MCP registrations for Claude Proxy.

Live Gmail search, mail reads, attachments, two real account grants and use from both proxy clients remain
acceptance work until an existing Gmail MCP server is selected and authorized. No Google Cloud Desktop
OAuth client or direct Gmail integration is required by this manager. Availability and consent requirements
come from the chosen MCP service. No provider endpoint is invented or assumed to exist.
