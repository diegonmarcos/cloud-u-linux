command ip addr show | command grep 'inet ' | command grep -v 127.0.0.1 | awk '{print $2}'
