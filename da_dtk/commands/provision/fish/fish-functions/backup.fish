function backup
    if test -f $argv[1]
        set -l timestamp (date +%Y%m%d_%H%M%S)
        cp $argv[1] "$argv[1].backup.$timestamp"
        echo "Backup created: $argv[1].backup.$timestamp"
    else
        echo "File not found: $argv[1]"
    end
end
