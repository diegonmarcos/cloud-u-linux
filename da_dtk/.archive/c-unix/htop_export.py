#!/usr/bin/env python3
"""Export htop with ANSI colors to a file."""
import pty
import os
import sys
import time
import select
import struct
import fcntl
import termios

def main():
    output_file = sys.argv[1] if len(sys.argv) > 1 else "htop_layout.txt"

    # Set terminal size (40 rows x 120 cols)
    rows, cols = 40, 120

    # Create PTY
    master, slave = pty.openpty()

    # Set terminal size on the PTY
    winsize = struct.pack('HHHH', rows, cols, 0, 0)
    fcntl.ioctl(slave, termios.TIOCSWINSZ, winsize)

    # Fork htop process
    pid = os.fork()
    if pid == 0:
        # Child process
        os.close(master)
        os.setsid()
        os.dup2(slave, 0)
        os.dup2(slave, 1)
        os.dup2(slave, 2)
        os.close(slave)
        os.environ['TERM'] = 'xterm-256color'
        os.environ['LINES'] = str(rows)
        os.environ['COLUMNS'] = str(cols)
        os.execlp('htop', 'htop', '-d', '5')
    else:
        # Parent process
        os.close(slave)
        output = b''
        start = time.time()

        # Read for 0.6 seconds to let htop draw
        while time.time() - start < 0.6:
            r, _, _ = select.select([master], [], [], 0.1)
            if r:
                try:
                    data = os.read(master, 8192)
                    if data:
                        output += data
                except:
                    break

        # Send 'q' to quit htop
        os.write(master, b'q')
        time.sleep(0.1)

        # Read any remaining output
        while True:
            r, _, _ = select.select([master], [], [], 0.1)
            if r:
                try:
                    data = os.read(master, 8192)
                    if data:
                        output += data
                    else:
                        break
                except:
                    break
            else:
                break

        os.close(master)
        os.waitpid(pid, 0)

        # Write output
        with open(output_file, 'wb') as f:
            f.write(output)

        print(f"Saved to: {output_file} ({len(output)} bytes)")

if __name__ == '__main__':
    main()
