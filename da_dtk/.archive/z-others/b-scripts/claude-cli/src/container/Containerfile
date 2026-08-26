FROM node:20-slim

# All dependencies Claude Code needs to function
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        curl \
        wget \
        openssh-client \
        ripgrep \
        jq \
        less \
        procps \
        python3 \
        python3-pip \
        bash \
        fish \
        sudo \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g @anthropic-ai/claude-code \
    && npm cache clean --force

# Non-root user with sudo access
RUN useradd -m -s /bin/bash claude && \
    echo "claude ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER claude
WORKDIR /workspace

ENTRYPOINT ["claude"]
