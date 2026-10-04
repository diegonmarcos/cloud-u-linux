# htop HTML Export

Export htop system monitor output to a styled HTML file with CSS.

## Files

- **htop_export.py** - Captures htop output with ANSI colors
- **htop_to_html.py** - Converts ANSI-colored text to HTML/CSS
- **htop_export_html.sh** - Complete pipeline script
- **htop_export.sh** - Simple wrapper for htop_export.py

## Usage

### Quick Export (Recommended)

```bash
./htop_export_html.sh [output.html]
```

This will:
1. Capture a live htop snapshot
2. Convert it to HTML with CSS styling
3. Save to `htop_export.html` (or your specified filename)

### Manual Steps

**Step 1: Capture htop output**
```bash
python3 htop_export.py htop_layout.txt
```

**Step 2: Convert to HTML**
```bash
python3 htop_to_html.py htop_layout.txt htop_export.html
```

### View the Output

```bash
xdg-open htop_export.html
# or
firefox htop_export.html
```

## Features

- **ANSI Color Support** - Preserves all htop colors (green, red, cyan, yellow, etc.)
- **Text Styling** - Bold, dim, underline effects
- **Monospace Font** - Terminal-style display
- **Dark Theme** - Black background matching terminal
- **Responsive** - Horizontal scrolling for wide content
- **Styled Scrollbar** - Custom dark theme scrollbar

## Color Mapping

The converter maps ANSI color codes to CSS classes:

| ANSI | CSS Class | Color |
|------|-----------|-------|
| 30-37 | .fg-* | Standard foreground colors |
| 90-97 | .fg-bright-* | Bright foreground colors |
| 40-47 | .bg-* | Standard background colors |
| 100-107 | .bg-bright-* | Bright background colors |

## Requirements

- Python 3
- htop installed
- Terminal with 256 color support

## Example Output

The HTML export preserves:
- CPU/Memory/Swap usage bars with colors
- Process list with colored columns
- System information (uptime, load, tasks)
- Function key menu at bottom
