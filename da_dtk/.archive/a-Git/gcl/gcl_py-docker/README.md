# 🐳 Docker Setup for gcl.py

## 📋 Files Created

- `Dockerfile` - Defines the container image
- `docker-compose.yml` - Simplifies running the container (includes build config)
- `.dockerignore` - Excludes unnecessary files from build

## 🚀 Quick Start

### **First Time Setup**

```bash
# Navigate to directory
cd /home/diego/Documents/Git/ops-Tooling/Git

# Build the image (docker-compose handles this automatically)
docker-compose build

# That's it! You're ready to use it.
```

### **Daily Usage**

```bash
# Launch TUI (interactive mode)
docker-compose run --rm gcl

# Run CLI commands
docker-compose run --rm gcl status
docker-compose run --rm gcl sync
docker-compose run --rm gcl push
docker-compose run --rm gcl pull
docker-compose run --rm gcl help
```

## 🔧 Understanding the Commands

### `docker-compose run --rm gcl`

- `run` - Execute a one-off command (not a service)
- `--rm` - Auto-delete container after exit (keeps things clean)
- `gcl` - The service name from docker-compose.yml

### Automatic Building

**First time you run:**
```bash
docker-compose run --rm gcl
```

Docker Compose will:
1. See there's no image built yet
2. Automatically run `docker build` using the Dockerfile
3. Create the `gcl-manager:latest` image
4. Run your container

**Subsequent runs:**
- Uses existing image (instant startup)
- Only rebuilds if you change Dockerfile or gcl.py

### Force Rebuild

If you modify `gcl.py`:
```bash
# Rebuild the image
docker-compose build

# Or rebuild and run in one command
docker-compose run --rm --build gcl
```

## 📁 What Gets Mounted

Your host directories mounted into container:

| Host Path | Container Path | Purpose |
|-----------|----------------|---------|
| `~/.ssh` | `/root/.ssh` | SSH keys for git (read-only) |
| `~/Documents/Git` | `/workspace` | Your repositories (read-write) |
| `~/.gitconfig` | `/root/.gitconfig` | Git configuration (read-only) |

## 🔒 Security Features

✅ **SSH keys mounted read-only** - Container can't modify your keys
✅ **Isolated filesystem** - Can't access files outside mounted volumes
✅ **Isolated processes** - Container processes separate from host
✅ **Auto-cleanup** - `--rm` flag removes container after exit

## 🛠️ Customization

### Change Working Directory

Edit `docker-compose.yml`:
```yaml
volumes:
  - /path/to/your/repos:/workspace  # Change this line
```

### Add Resource Limits

Uncomment in `docker-compose.yml`:
```yaml
deploy:
  resources:
    limits:
      cpus: '1.0'    # Max 1 CPU core
      memory: 512M   # Max 512MB RAM
```

### Use Different Git Config

```yaml
volumes:
  - ~/my-custom-gitconfig:/root/.gitconfig:ro
```

## 🧹 Cleanup

### Remove Image
```bash
docker-compose down --rmi all
```

### Remove All Containers
```bash
docker-compose down -v
```

### See What's Running
```bash
docker ps
```

## 🐛 Troubleshooting

### "Permission denied" for SSH keys
```bash
# Make sure SSH keys have correct permissions on host
chmod 600 ~/.ssh/id_rsa
chmod 644 ~/.ssh/id_rsa.pub
```

### "Cannot connect to Docker daemon"
```bash
# Start Docker service
sudo systemctl start docker   # Linux
# or just start Docker Desktop  # Mac/Windows
```

### Rebuild from scratch
```bash
# Remove old image and rebuild
docker-compose build --no-cache
```

## 📊 File Structure

```
ops-Tooling/Git/
├── Dockerfile              # Container definition
├── docker-compose.yml      # Easy run config (includes build)
├── .dockerignore          # Build optimization
├── gcl.py                 # Your script
├── gcl.sh                 # Shell version
└── DOCKER-README.md       # This file
```

## 💡 Tips

1. **Fast startup**: First run builds image (~30 sec), subsequent runs instant
2. **Updates**: When you edit gcl.py, run `docker-compose build` to update image
3. **Portability**: Share Dockerfile + docker-compose.yml with others
4. **Cross-platform**: Works identically on Linux, Mac, Windows
5. **Clean exit**: Always use 'q' to quit properly

## 🎯 Common Workflows

### Morning Routine - Check All Repos
```bash
docker-compose run --rm gcl status
```

### Sync Everything
```bash
docker-compose run --rm gcl     # Opens TUI
# Press 'a' to select all
# Press 's' for sync
# Press Enter to run
```

### Quick Push
```bash
docker-compose run --rm gcl push
```

---

**Need help?** Check the main gcl.py help:
```bash
docker-compose run --rm gcl help
```
