for i in /sys/devices/system/cpu/cpu[0-9]*/cpufreq
  if test -d "$i"
    set -l cur (command cat "$i/scaling_cur_freq" 2>/dev/null)
    set -l max (command cat "$i/scaling_max_freq" 2>/dev/null)
    if test -n "$cur" -a -n "$max"
      set -l core (basename (dirname "$i"))
      printf "%s: %4d MHz / %4d MHz = %3d%%\n" $core (math "$cur / 1000") (math "$max / 1000") (math "$cur * 100 / $max")
    end
  end
end
