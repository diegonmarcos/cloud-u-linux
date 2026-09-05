{
  "_doc": "HTTP-ONLY by decree (2026-08-08): each stdio/tsx spawn transpiles TypeScript through proot-taxed IO and cost 30s+ of claude startup.",
  "mcpServers": {
    "cloud-cgc-pub-mcp": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/cloud-cgc-pub-mcp/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      }
    },
    "cloud-cgc-pvt-mcp": {
      "type": "http",
      "url": "http://10.0.0.6:3107/mcp"
    },
    "cloud-drive-mcp": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/cloud-drive-mcp/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      }
    },
    "cloud-infra-mcp": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/c3-infra-mcp/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      }
    },
    "cloud-mail-mcp": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/mail-mcp/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      }
    },
    "cloud-mattermost-mcp": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/mattermost-mcp/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      }
    },
    "cloud-services-mcp": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/c3-services-mcp/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      }
    },
    "cloud-superapp-mcp": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/cloud-superapp-mcp/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      }
    },
    "cloud-vault-mcp": {
      "type": "http",
      "url": "http://10.0.0.6:3111/mcp"
    },
    "google-personal-mcp": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/g-personal/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      }
    },
    "google-workspace-mcp": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/g-workspace/mcp",
      "headers": {
        "Authorization": "Bearer ${AUTHELIA_OIDC_TOKEN_CLAUDE-ADMIN}"
      }
    }
  }
}
