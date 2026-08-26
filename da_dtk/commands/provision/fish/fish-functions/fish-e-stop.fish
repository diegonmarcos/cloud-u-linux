function fish-e-stop
    if test (count $argv) -ge 2
        kill $argv[2] 2>/dev/null
        tmux kill-session -t $argv[1] 2>/dev/null
        echo "Stopped ttyd (PID $argv[2]) and tmux session $argv[1]"
    else
        # Kill all fish-e sessions
        for s in (tmux list-sessions -F "#{session_name}" 2>/dev/null | command grep "^fish-e-")
            tmux kill-session -t $s 2>/dev/null
        end
        pkill -f "ttyd.*fish-e" 2>/dev/null
        echo "Stopped all fish-e sessions"
    end
end
