{
  "_doc": "HTTP-ONLY by decree (2026-08-08): stdio/tsx servers are BANNED on the phone — each spawn transpiles TypeScript through proot-taxed IO and cost 30s+ of claude startup. Everything runs as an HTTP endpoint behind mcp.diegonmarcos.com instead. The desktop-only stdio entries (cloud-cgc-pub-mcp-local, cloud-vault-mcp) live in the desktop tpl / git history if ever needed. Server keys follow the new cloud-<name>-mcp pattern; route slugs are unchanged. Source of truth for the HTTP set: cloud-infra/1_cloud-configs/dist/mcp.json.",
  "mcpServers": {
    "cloud-infra-mcp": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/c3-infra-mcp/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      },
      "alwaysLoad": false
    },
    "cloud-cgc-pub-mcp": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/cloud-cgc-pub-mcp/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      },
      "alwaysLoad": false
    },
    "cloud-drive-mcp": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/cloud-drive-mcp/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      },
      "alwaysLoad": false
    },
    "cloud-services-mcp": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/c3-services-mcp/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      },
      "alwaysLoad": false
    },
    "cloud-mail-mcp": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/mail-mcp/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      },
      "alwaysLoad": false
    },
    "cloud-mattermost-mcp": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/mattermost-mcp/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      },
      "alwaysLoad": false
    },
    "google-workspace-mcp": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/g-workspace/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      },
      "alwaysLoad": false
    },
    "google-personal-mcp": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/g-personal/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      },
      "alwaysLoad": false
    }
  }
}
