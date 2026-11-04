# Remote MCP (Streamable HTTP): connect Claude, ChatGPT and other agents

## What this is

The server exposes its lineage catalogue (workspaces, dependencies, object impact, scan status, access roles, run history and more) as a real MCP server, reachable through **one public URL**:

```
https://<the same domain where you see the viewer>/mcp
```

There is nothing to install, no script to download and no repository checkout needed. Any MCP client that can add a remote connector by URL can use it directly. This is what a **hosted** AI product (ChatGPT, Claude on the web and so on) needs to connect: those products cannot launch a process on your machine, they can only reach a URL.

Implementation: `backend/scripts/mcp_http_server.py`, a subprocess that `lineage_web_server.py` starts automatically (on an internal port that is never exposed directly). `backend/scripts/lineage_web/handler.py` acts as a reverse proxy from `/mcp` on the public port. Transport: **Streamable HTTP**, the standard remote transport of the MCP protocol.

## Authentication

A Bearer token, which is exactly the same API key you create in the admin panel's **API keys** tab (see [102](102_admin_panel_and_user_auth.md)). Every call, including the first one (`initialize`), needs this header:

```
Authorization: Bearer <your-api-key>
```

Without it, or with an invalid, expired or revoked key, the server answers `401`. There is no OAuth flow. It is a long-lived static key, which is simpler to set up for a self-hosted deployment like this one. If you later need real OAuth (for example, so that each person has their own identity instead of sharing a key), that would be a much bigger change and it is not built.

## By client

The only stable part is "URL + Bearer token", which is the MCP protocol itself. The exact screens of each product change over time. What follows is the general pattern, not a guarantee that every click is still the same.

### Claude Code (CLI)

```bash
claude mcp add --transport http fabric-lineage https://<your-domain>/mcp --header "Authorization: Bearer <your-api-key>"
```

If your version of `claude mcp add` does not recognise `--transport http` or `--header`, run `claude mcp add --help` to see the flags that version accepts.

### Claude Desktop / claude.ai (connectors)

Settings, then Connectors, then Add a custom connector. Paste the URL (`https://<your-domain>/mcp`) and, if the interface asks for it, the header `Authorization: Bearer <your-api-key>`. If your version of the interface has no custom-header field for remote connectors, use the Claude Code route above instead.

### ChatGPT (Connectors / Apps)

Settings, then Connectors (or Apps, depending on the account), then Add a custom connector. Enter the MCP server URL (`https://<your-domain>/mcp`) and the authentication header when asked. The availability of custom connectors by URL depends on the account type and plan.

### Cursor

`~/.cursor/mcp.json` (or the per-project equivalent, `.cursor/mcp.json`):

```json
{
  "mcpServers": {
    "fabric-lineage": {
      "url": "https://<your-domain>/mcp",
      "headers": { "Authorization": "Bearer <your-api-key>" }
    }
  }
}
```

### Windsurf

Same pattern as Cursor, in its own MCP configuration file (`~/.codeium/windsurf/mcp_config.json` in recent installs), with the same `{"url": ..., "headers": {...}}` shape.

### GitHub Copilot (VS Code)

Copilot Chat in agent mode supports remote MCP servers through `.vscode/mcp.json` in the workspace, with the same `url` plus `headers` shape.

### Any other MCP-compatible client

If your client is not listed, search its documentation for "MCP remote server", "Streamable HTTP" or "custom connector by URL". If it can add a server by URL with a custom header, this URL and this token work the same way as with the clients above.

## Quick check (without an AI client)

```bash
curl -s -D - -X POST https://<your-domain>/mcp \
  -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer <your-api-key>" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke-test","version":"1.0"}}}'
```

A `200` response with `event: message` and a `serverInfo` in the JSON confirms that the server is alive and the key is valid. A `401` means the key is missing or invalid. A `503` means the `mcp_http_server.py` subprocess did not start (check the server's startup log; you probably need `pip install -r requirements-mcp.txt`).

## What this is not

- It does not replace `backend/scripts/mcp_server.py` (local, reads files directly, no network calls) or `backend/scripts/mcp_server_remote.py` (stdio, but calling the REST API). Both still exist for anyone who prefers to run the MCP process on their own machine. Both are documented in the README.
- It does not implement full OAuth 2.1 (dynamic client registration, token issuance and so on). It only verifies a static Bearer token against the keys already issued from the panel. That is enough for "any authenticated agent can connect", and it is not meant for multi-tenant scenarios with per-user identities inside the agent.
