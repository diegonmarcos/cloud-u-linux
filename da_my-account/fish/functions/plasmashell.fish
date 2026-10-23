# plasmashell [start|stop|restart|status] — default restart.
#
# restart is deliberately stop-then-start, not `systemctl --user restart`: the unit runs
# plasmashell with --no-respawn, so the two-step form makes a failed start visible as a
# down shell rather than systemd quietly leaving the old one in place. Anything that
# isn't one of the four verbs is passed through to the real binary (e.g. --replace), so
# this wrapper can shadow plasmashell on PATH without taking any usage away.
set -l unit plasma-plasmashell.service

switch "$argv[1]"
    case '' restart
        systemctl --user stop $unit
        systemctl --user start $unit
    case start
        systemctl --user start $unit
    case stop
        systemctl --user stop $unit
    case status
        systemctl --user status $unit --no-pager
        return
    case '*'
        command plasmashell $argv
        return
end

# --no-respawn means a start that fails just stays dead and silent — say which it was.
sleep 1
echo "plasmashell: "(systemctl --user is-active $unit)
