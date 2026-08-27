{
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
    "cloud-cgc-pvt-mcp": {
      "type": "http",
      "url": "http://10.0.0.6:3107/mcp",
      "alwaysLoad": false
    },
    "cloud-cgc-pub-mcp-local": {
      "type": "stdio",
      "command": "/home/diego/.claude/mcp-local-launch.sh",
      "args": [
        "/home/diego/git/cloud-infra/a_solutions/user-ai_cloud-cgc-pub-mcp/src/code/index.ts"
      ],
      "env": {
        "NODE_PATH": "/home/diego/.node_modules/node_modules",
        "CONFIG_PATH": "/home/diego/git/cloud-infra/config.json",
        "GIT_ROOT": "/home/diego/git"
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
    "cloud-vault-mcp": {
      "type": "stdio",
      "command": "/home/diego/.claude/mcp-local-launch.sh",
      "args": [
        "/home/diego/git/cloud-infra/a_solutions/infra-api_cloud-vault-mcp/src/index.ts"
      ],
      "env": {
        "NODE_PATH": "/home/diego/.node_modules/node_modules",
        "VAULT_PATH": "/home/diego/git/cloud-vault",
        "CONFIG_PATH": "/home/diego/git/cloud-infra/config.json"
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
