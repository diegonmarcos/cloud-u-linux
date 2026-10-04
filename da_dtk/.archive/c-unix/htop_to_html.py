#!/usr/bin/env python3
"""Convert htop ANSI output to HTML with CSS styling."""
import re
import sys
from pathlib import Path
from datetime import datetime

# ANSI color code mappings to CSS classes
ANSI_COLORS = {
    # Foreground colors
    '30': 'fg-black',
    '31': 'fg-red',
    '32': 'fg-green',
    '33': 'fg-yellow',
    '34': 'fg-blue',
    '35': 'fg-magenta',
    '36': 'fg-cyan',
    '37': 'fg-white',
    '39': 'fg-default',
    '90': 'fg-bright-black',
    '91': 'fg-bright-red',
    '92': 'fg-bright-green',
    '93': 'fg-bright-yellow',
    '94': 'fg-bright-blue',
    '95': 'fg-bright-magenta',
    '96': 'fg-bright-cyan',
    '97': 'fg-bright-white',
    # Background colors
    '40': 'bg-black',
    '41': 'bg-red',
    '42': 'bg-green',
    '43': 'bg-yellow',
    '44': 'bg-blue',
    '45': 'bg-magenta',
    '46': 'bg-cyan',
    '47': 'bg-white',
    '49': 'bg-default',
    '100': 'bg-bright-black',
    '101': 'bg-bright-red',
    '102': 'bg-bright-green',
    '103': 'bg-bright-yellow',
    '104': 'bg-bright-blue',
    '105': 'bg-bright-magenta',
    '106': 'bg-bright-cyan',
    '107': 'bg-bright-white',
}

ANSI_STYLES = {
    '0': 'reset',
    '1': 'bold',
    '2': 'dim',
    '3': 'italic',
    '4': 'underline',
    '7': 'inverse',
    '22': 'normal-intensity',
    '23': 'no-italic',
    '24': 'no-underline',
    '27': 'no-inverse',
}

def parse_ansi_to_html(text):
    """Parse ANSI escape codes and convert to HTML with CSS classes."""
    # Remove control sequences we don't need
    text = re.sub(r'\x1b\[\?[\d;]*[hl]', '', text)  # Mode changes
    text = re.sub(r'\x1b\[[\d;]*[tHJKr]', '', text)  # Cursor/clear operations
    text = re.sub(r'\x1b\(B', '', text)  # Character set
    text = re.sub(r'\x1b\][\d;]*\x07', '', text)  # OSC sequences
    text = re.sub(r'\x1b>', '', text)  # Normal keypad mode

    result = []
    current_classes = set()
    i = 0

    while i < len(text):
        # Check for ANSI escape sequence
        if text[i:i+2] == '\x1b[':
            # Find the end of the escape sequence
            match = re.match(r'\x1b\[([0-9;]*)m', text[i:])
            if match:
                codes = match.group(1).split(';') if match.group(1) else ['0']

                # Process each code
                for code in codes:
                    if code == '0' or code == '':
                        # Reset all
                        if current_classes:
                            result.append('</span>')
                            current_classes = set()
                    elif code in ANSI_COLORS:
                        # Add color class
                        current_classes.add(ANSI_COLORS[code])
                    elif code in ANSI_STYLES:
                        # Add style class
                        if ANSI_STYLES[code] == 'reset':
                            if current_classes:
                                result.append('</span>')
                                current_classes = set()
                        else:
                            current_classes.add(ANSI_STYLES[code])

                # Apply current classes
                if current_classes and (not result or result[-1] != '</span>'):
                    if result and not result[-1].startswith('<span'):
                        # Close previous span before opening new one
                        pass
                    result.append(f'<span class="{" ".join(sorted(current_classes))}">')

                i += len(match.group(0))
                continue

        # Regular character
        char = text[i]
        if char == '<':
            result.append('&lt;')
        elif char == '>':
            result.append('&gt;')
        elif char == '&':
            result.append('&amp;')
        elif char == '\n':
            if current_classes:
                result.append('</span>')
            result.append('<br>\n')
            if current_classes:
                result.append(f'<span class="{" ".join(sorted(current_classes))}">')
        else:
            result.append(char)

        i += 1

    # Close any open spans
    if current_classes:
        result.append('</span>')

    return ''.join(result)

def generate_html(htop_content, input_file):
    """Generate complete HTML document."""
    html_content = parse_ansi_to_html(htop_content)

    # Get timestamp
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    html = f'''<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>htop Export</title>
    <style>
        * {{
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }}

        body {{
            background-color: #000000;
            color: #c0c0c0;
            font-family: 'Monaco', 'Menlo', 'Ubuntu Mono', 'Consolas', 'Courier New', monospace;
            font-size: 13px;
            line-height: 1.2;
            padding: 20px;
        }}

        .htop-container {{
            background-color: #000000;
            border: 2px solid #333;
            border-radius: 8px;
            padding: 15px;
            max-width: 100%;
            overflow-x: auto;
            box-shadow: 0 4px 6px rgba(0, 0, 0, 0.3);
        }}

        .htop-content {{
            white-space: pre;
            letter-spacing: 0;
        }}

        /* Foreground colors */
        .fg-black {{ color: #2e3436; }}
        .fg-red {{ color: #cc0000; }}
        .fg-green {{ color: #4e9a06; }}
        .fg-yellow {{ color: #c4a000; }}
        .fg-blue {{ color: #3465a4; }}
        .fg-magenta {{ color: #75507b; }}
        .fg-cyan {{ color: #06989a; }}
        .fg-white {{ color: #d3d7cf; }}
        .fg-default {{ color: #c0c0c0; }}

        .fg-bright-black {{ color: #555753; }}
        .fg-bright-red {{ color: #ef2929; }}
        .fg-bright-green {{ color: #8ae234; }}
        .fg-bright-yellow {{ color: #fce94f; }}
        .fg-bright-blue {{ color: #729fcf; }}
        .fg-bright-magenta {{ color: #ad7fa8; }}
        .fg-bright-cyan {{ color: #34e2e2; }}
        .fg-bright-white {{ color: #eeeeec; }}

        /* Background colors */
        .bg-black {{ background-color: #2e3436; }}
        .bg-red {{ background-color: #cc0000; }}
        .bg-green {{ background-color: #4e9a06; }}
        .bg-yellow {{ background-color: #c4a000; }}
        .bg-blue {{ background-color: #3465a4; }}
        .bg-magenta {{ background-color: #75507b; }}
        .bg-cyan {{ background-color: #06989a; }}
        .bg-white {{ background-color: #d3d7cf; }}
        .bg-default {{ background-color: transparent; }}

        .bg-bright-black {{ background-color: #555753; }}
        .bg-bright-red {{ background-color: #ef2929; }}
        .bg-bright-green {{ background-color: #8ae234; }}
        .bg-bright-yellow {{ background-color: #fce94f; }}
        .bg-bright-blue {{ background-color: #729fcf; }}
        .bg-bright-magenta {{ background-color: #ad7fa8; }}
        .bg-bright-cyan {{ background-color: #34e2e2; }}
        .bg-bright-white {{ background-color: #eeeeec; }}

        /* Text styles */
        .bold {{ font-weight: bold; }}
        .dim {{ opacity: 0.6; }}
        .italic {{ font-style: italic; }}
        .underline {{ text-decoration: underline; }}
        .inverse {{
            filter: invert(1);
        }}

        /* Header styling */
        .htop-header {{
            margin-bottom: 20px;
            padding-bottom: 10px;
            border-bottom: 1px solid #333;
        }}

        .htop-header h1 {{
            color: #34e2e2;
            font-size: 24px;
            margin-bottom: 5px;
        }}

        .htop-header .timestamp {{
            color: #8ae234;
            font-size: 12px;
        }}

        /* Scrollbar styling */
        .htop-container::-webkit-scrollbar {{
            height: 10px;
        }}

        .htop-container::-webkit-scrollbar-track {{
            background: #1a1a1a;
        }}

        .htop-container::-webkit-scrollbar-thumb {{
            background: #555;
            border-radius: 5px;
        }}

        .htop-container::-webkit-scrollbar-thumb:hover {{
            background: #777;
        }}
    </style>
</head>
<body>
    <div class="htop-header">
        <h1>htop System Monitor Export</h1>
        <div class="timestamp">Generated: {timestamp}</div>
    </div>
    <div class="htop-container">
        <div class="htop-content">{html_content}</div>
    </div>
</body>
</html>'''

    return html

def main():
    if len(sys.argv) < 2:
        print("Usage: htop_to_html.py <input_file> [output_file]")
        sys.exit(1)

    input_file = sys.argv[1]
    output_file = sys.argv[2] if len(sys.argv) > 2 else input_file.replace('.txt', '.html')

    # Read the ANSI input
    with open(input_file, 'rb') as f:
        content = f.read().decode('utf-8', errors='ignore')

    # Generate HTML
    html = generate_html(content, input_file)

    # Write output
    with open(output_file, 'w', encoding='utf-8') as f:
        f.write(html)

    print(f"✓ Converted {input_file} to {output_file}")
    print(f"  Size: {len(content)} bytes → {len(html)} bytes")

if __name__ == '__main__':
    main()
