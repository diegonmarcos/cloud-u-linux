function nixos-rebuild --description "nixos-rebuild wrapped w/ global start/finish notify-send popup"
    _notify_wrap nixos-rebuild $argv
end
