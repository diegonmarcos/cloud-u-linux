function fish-e
    set -l port 7681
    while ss -tln | command grep -q ":$port "
        set port (math $port + 1)
    end

    set -l session "fish-e-$port"
    set -l wg_ip (ip -4 addr show wg0 2>/dev/null | command awk '/inet / {split($2,a,"/"); print a[1]}')

    if test -z "$wg_ip"
        set wg_ip "127.0.0.1"
        set_color yellow
        echo "⚠ WireGuard not active, binding to localhost only"
        set_color normal
    end

    # Create tmux session
    tmux new-session -d -s $session fish

    # Start ttyd in background serving the tmux session
    ttyd --writable -t enableMobileKeyboard=true -p $port tmux attach -t $session &
    set -l ttyd_pid $last_pid

    echo ""
    set_color --bold cyan
    echo "── fish-e: Web Terminal ──────────────────────"
    set_color normal
    set_color green
    echo "  http://$wg_ip:$port"
    set_color normal
    set_color green
    echo "  http://localhost:$port"
    set_color normal
    echo ""
    set_color --bold yellow
    echo "  tmux session: $session"
    set_color normal
    set_color --dim
    echo "  ttyd PID: $ttyd_pid"
    set_color normal
    set_color --dim
    echo "  Stop: fish-e-stop $session $ttyd_pid"
    set_color normal
    echo ""

    # Also display the URL inside the tmux session
    tmux send-keys -t $session "echo '── fish-e: http://$wg_ip:$port ── tmux: $session ──'" Enter

    # Drop into the shared tmux session
    tmux attach -t $session

    # Cleanup: when tmux exits, stop ttyd
    kill $ttyd_pid 2>/dev/null
end
