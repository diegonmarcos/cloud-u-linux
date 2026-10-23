function _notify_wrap --description "Run a real binary, popup on start + finish/fail"
    set -l real_cmd $argv[1]
    set -l bin_args $argv[2..-1]

    notify-send -u normal -i nix-snowflake-white "Nix: $real_cmd starting" "$bin_args"

    set -l start (date +%s)
    command $real_cmd $bin_args
    set -l status_code $status
    set -l elapsed (math (date +%s) - $start)

    if test $status_code -eq 0
        notify-send -u normal -i emblem-default "Nix: $real_cmd done ({$elapsed}s)" "$bin_args"
    else
        notify-send -u critical -i emblem-important "Nix: $real_cmd FAILED ({$elapsed}s, exit $status_code)" "$bin_args"
    end

    return $status_code
end
