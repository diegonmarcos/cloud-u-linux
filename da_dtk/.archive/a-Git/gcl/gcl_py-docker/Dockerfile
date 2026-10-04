# Dockerfile for gcl.py - Git Clone/Pull/Push Manager
# Creates a sandboxed, cross-platform environment

FROM python:3.11-slim

# Install system dependencies
RUN apt-get update && \
    apt-get install -y \
    git \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /workspace

# Copy the gcl.py script
COPY gcl.py /usr/local/bin/gcl.py

# Make it executable
RUN chmod +x /usr/local/bin/gcl.py

# Set environment variables for proper terminal display
ENV TERM=xterm-256color
ENV PYTHONUNBUFFERED=1

# Default command: launch the TUI
ENTRYPOINT ["python3", "/usr/local/bin/gcl.py"]
CMD []
