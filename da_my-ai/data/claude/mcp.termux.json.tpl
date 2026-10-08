{
  "_warning": "GENERATED — DO NOT EDIT. Derived from cloud-infra/1_cloud-configs/dist/mcp.json + mcp-policy.json by cloud-u-linux da_my-ai/data/claude/gen-mcp-tpl.sh. Hand-editing this file is the bug it exists to prevent: edit the service declaration or mcp-policy.json and regenerate.",
  "_doc": "HTTP-ONLY by decree (2026-08-08): each stdio/tsx spawn transpiles TypeScript through proot-taxed IO and cost 30s+ of claude startup.",
  "_exposure": {
    "_doc": "Only mcpServers below are registered and preload tool schemas. Every server in _mcp_catalogue is reachable but NOT preloaded: run tools/list against its url at the moment you need it.",
    "budget_tokens": 20000,
    "projected_tokens": 20705
  },
  "mcpServers": {
    "cloud-cgc-pub-mcp": {
      "type": "http",
      "url": "https://mcp.diegonmarcos.com/cloud-cgc-pub-mcp/mcp",
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
    }
  },
  "_mcp_catalogue": {}
}
