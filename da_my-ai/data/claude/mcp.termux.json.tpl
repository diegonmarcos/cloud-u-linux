{
  "_warning": "GENERATED — DO NOT EDIT. Derived from cloud-infra/1_cloud-configs/dist/mcp.json + mcp-policy.json by cloud-u-linux da_my-ai/data/claude/gen-mcp-tpl.sh. Hand-editing this file is the bug it exists to prevent: edit the service declaration or mcp-policy.json and regenerate.",
  "_doc": "HTTP-ONLY by decree (2026-08-08): each stdio/tsx spawn transpiles TypeScript through proot-taxed IO and cost 30s+ of claude startup.",
  "_exposure": {
    "_doc": "Only mcpServers below are registered and preload tool schemas. Every server in _mcp_catalogue is reachable but NOT preloaded: run tools/list against its url at the moment you need it.",
    "budget_tokens": 20000,
    "projected_tokens": 6702
  },
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
    }
  },
  "_mcp_catalogue": {
    "cloud-drive-mcp": {
      "url": "https://mcp.diegonmarcos.com/cloud-drive-mcp/mcp",
      "exposure": "names_only",
      "tools": "run tools/list against this url when you need it"
    },
    "cloud-infra-mcp": {
      "url": "https://mcp.diegonmarcos.com/c3-infra-mcp/mcp",
      "exposure": "names_only",
      "tools": "run tools/list against this url when you need it"
    },
    "cloud-mail-mcp": {
      "url": "https://mcp.diegonmarcos.com/mail-mcp/mcp",
      "exposure": "names_only",
      "tools": "run tools/list against this url when you need it"
    },
    "cloud-mattermost-mcp": {
      "url": "https://mcp.diegonmarcos.com/mattermost-mcp/mcp",
      "exposure": "names_only",
      "tools": "run tools/list against this url when you need it"
    },
    "cloud-services-mcp": {
      "url": "https://mcp.diegonmarcos.com/c3-services-mcp/mcp",
      "exposure": "names_only",
      "tools": "run tools/list against this url when you need it"
    },
    "cloud-superapp-mcp": {
      "url": "https://mcp.diegonmarcos.com/cloud-superapp-mcp/mcp",
      "exposure": "names_only",
      "tools": "run tools/list against this url when you need it"
    },
    "cloud-vault-mcp": {
      "url": "http://10.0.0.6:3111/mcp",
      "exposure": "names_only",
      "tools": "run tools/list against this url when you need it"
    },
    "google-personal-mcp": {
      "url": "https://mcp.diegonmarcos.com/g-personal/mcp",
      "exposure": "names_only",
      "tools": "run tools/list against this url when you need it"
    },
    "google-workspace-mcp": {
      "url": "https://mcp.diegonmarcos.com/g-workspace/mcp",
      "exposure": "names_only",
      "tools": "run tools/list against this url when you need it"
    }
  }
}
