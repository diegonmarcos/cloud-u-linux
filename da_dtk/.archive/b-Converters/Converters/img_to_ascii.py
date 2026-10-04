from PIL import Image

# ASCII characters from darkest to lightest
CHARSETS = {
    "detailed": "@%#*+=-:. ",
    "blocks": "█▓▒░ ",
    "simple": "@#S%?*+;:,. ",
    "binary": "█ ",
    "dots": "●◉◎○· ",
    "stars": "★☆✦✧✶· ",
    "arrows": "▶▷►▻> ",
    "hearts": "♥♡❤❥· ",
    "numbers": "0123456789 ",
    "letters": "MWNXKODB8@#%&$*+=;:,. ",
    "braille": "⣿⣷⣯⣟⡿⢿⣻⣽⣾⣶⣦⣤⣄⡀ ",
    "shade": "▉▊▋▌▍▎▏ ",
    "box": "╬╫╪┼┴┬├┤│─ ",
    "slashes": "▓▒/\\|─ ",
    "matrix": "ﾊﾐﾋｰｳｼﾅﾓﾆｻﾜﾂｵﾘｱﾎﾃﾏｹﾒｴｶｷﾑﾕﾗｾﾈｽﾀﾇﾍ ",
    "emoji": "😀😃😄😁😆😅🤣😂🙂🙃 ",
    "cats": "🐱😺😸😹😻😼😽🙀😿😾 ",
    "ascii_art": "$@B%8&WM#*oahkbdpqwmZO0QLCJUYXzcvunxrjft/\\|()1{}[]?-_+~<>i!lI;:,\"^`'. ",
}


def list_charsets():
    """List all available character sets."""
    print("Available charsets:")
    print("-" * 50)
    for name, chars in CHARSETS.items():
        preview = chars[:10] + "..." if len(chars) > 10 else chars
        print(f"  {name:12} : {preview}")
    print("-" * 50)
    print("You can also use custom chars: --chars='@#$%& '")


def image_to_ascii(image_path, output_width=100, charset="detailed", invert=False, custom_chars=None):
    """
    Converts an image to ASCII art text.

    :param image_path: Path to image file (.jpg, .png, etc.)
    :param output_width: Character width of output
    :param charset: Name of charset from CHARSETS dict
    :param invert: Invert brightness (for dark backgrounds)
    :param custom_chars: Custom character string (darkest to lightest)
    :return: ASCII art string
    """
    # Select character set
    if custom_chars:
        chars = custom_chars
    elif charset in CHARSETS:
        chars = CHARSETS[charset]
    else:
        print(f"Unknown charset '{charset}', using 'detailed'")
        chars = CHARSETS["detailed"]

    if invert:
        chars = chars[::-1]

    try:
        img = Image.open(image_path)

        # Calculate height (ASCII chars are ~2x taller than wide)
        aspect_ratio = img.size[1] / img.size[0]
        output_height = int(output_width * aspect_ratio * 0.5)

        # Resize and convert to grayscale
        img = img.resize((output_width, output_height), Image.Resampling.LANCZOS)
        img = img.convert("L")  # Grayscale

        pixels = img.load()
        width, height = img.size

        ascii_art = []
        for y in range(height):
            row = ""
            for x in range(width):
                brightness = pixels[x, y]
                # Map brightness (0-255) to character index
                char_idx = int(brightness / 256 * len(chars))
                char_idx = min(char_idx, len(chars) - 1)
                row += chars[char_idx]
            ascii_art.append(row)

        return "\n".join(ascii_art)

    except Exception as e:
        return f"Error: {e}"


def save_ascii_art(image_path, output_file="ascii_art.txt", output_width=100, charset="detailed", invert=False):
    """
    Converts image to ASCII and saves to file.
    """
    ascii_art = image_to_ascii(image_path, output_width, charset, invert)
    with open(output_file, "w") as f:
        f.write(ascii_art)
    print(f"ASCII art saved to {output_file}")
    return ascii_art


def export_all_charsets(image_path, output_file="ascii_all_charsets.txt", output_width=80, invert=False):
    """
    Exports ASCII art using ALL available charsets to a single file.
    """
    results = []

    for charset_name in CHARSETS.keys():
        header = f"\n{'='*80}\n"
        header += f"  CHARSET: {charset_name.upper()}\n"
        header += f"  Characters: {CHARSETS[charset_name][:20]}{'...' if len(CHARSETS[charset_name]) > 20 else ''}\n"
        header += f"{'='*80}\n\n"

        ascii_art = image_to_ascii(image_path, output_width, charset_name, invert)
        results.append(header + ascii_art)

    full_output = "\n".join(results)

    with open(output_file, "w") as f:
        f.write(full_output)

    print(f"All {len(CHARSETS)} charsets exported to {output_file}")
    return full_output


def image_to_html_ascii(image_path, output_file="ascii_art.html", output_width=100, charset="detailed", invert=False, colored=True):
    """
    Converts an image to colored ASCII art in HTML format.

    :param image_path: Path to image file
    :param output_file: Output HTML file
    :param output_width: Character width of output
    :param charset: Name of charset from CHARSETS dict
    :param invert: Invert brightness
    :param colored: If True, each character gets the pixel's color
    :return: HTML string
    """
    if charset in CHARSETS:
        chars = CHARSETS[charset]
    else:
        chars = CHARSETS["detailed"]

    if invert:
        chars = chars[::-1]

    try:
        img = Image.open(image_path)

        # Calculate height (ASCII chars are ~2x taller than wide)
        aspect_ratio = img.size[1] / img.size[0]
        output_height = int(output_width * aspect_ratio * 0.5)

        # Resize
        img_resized = img.resize((output_width, output_height), Image.Resampling.LANCZOS)

        # Get grayscale for character selection
        img_gray = img_resized.convert("L")
        pixels_gray = img_gray.load()

        # Get color for HTML
        img_rgb = img_resized.convert("RGB")
        pixels_rgb = img_rgb.load()

        width, height = img_resized.size

        html_lines = []
        for y in range(height):
            row = ""
            for x in range(width):
                brightness = pixels_gray[x, y]
                char_idx = int(brightness / 256 * len(chars))
                char_idx = min(char_idx, len(chars) - 1)
                char = chars[char_idx]

                # Escape HTML special chars
                if char == '<':
                    char = '&lt;'
                elif char == '>':
                    char = '&gt;'
                elif char == '&':
                    char = '&amp;'
                elif char == '"':
                    char = '&quot;'
                elif char == ' ':
                    char = '&nbsp;'

                if colored:
                    r, g, b = pixels_rgb[x, y]
                    row += f'<span style="color:rgb({r},{g},{b})">{char}</span>'
                else:
                    row += char
            html_lines.append(row)

        ascii_html = "<br>".join(html_lines)

        html_output = f"""<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>ASCII Art - {image_path}</title>
    <style>
        body {{
            background-color: #1a1a1a;
            display: flex;
            justify-content: center;
            padding: 20px;
        }}
        pre {{
            font-family: 'Courier New', monospace;
            font-size: 8px;
            line-height: 8px;
            letter-spacing: 0px;
            background-color: #000;
            padding: 20px;
            border-radius: 10px;
        }}
    </style>
</head>
<body>
    <pre>{ascii_html}</pre>
</body>
</html>"""

        with open(output_file, "w") as f:
            f.write(html_output)

        print(f"Colored HTML ASCII art saved to {output_file}")
        return html_output

    except Exception as e:
        print(f"Error: {e}")
        return None


def generate_pixel_art_css(image_path, output_width=64, pixel_size=5):
    """
    Converts an image to a CSS box-shadow pixel art string.

    :param image_path: Path to your downloaded .jpg or .png file
    :param output_width: How many 'pixels' wide the art should be (e.g., 64)
    :param pixel_size: The visual size of each pixel in the CSS
    """
    try:
        # Open the image
        img = Image.open(image_path)

        # Calculate height to keep aspect ratio
        w_percent = (output_width / float(img.size[0]))
        h_size = int((float(img.size[1]) * float(w_percent)))

        # Resize using NEAREST to maintain hard pixel edges
        img = img.resize((output_width, h_size), Image.Resampling.NEAREST)
        img = img.convert("RGB")

        pixels = img.load()
        width, height = img.size

        box_shadows = []

        # Iterate through pixels to create shadows
        for y in range(height):
            for x in range(width):
                r, g, b = pixels[x, y]
                # x-offset, y-offset, color
                box_shadows.append(f"{x * pixel_size}px {y * pixel_size}px rgb({r},{g},{b})")

        # Join all shadows
        css_shadow = ",".join(box_shadows)

        # Generate the full HTML/CSS block
        html_output = f"""
<div style="
    width: {pixel_size}px;
    height: {pixel_size}px;
    background: transparent;
    box-shadow: {css_shadow};
"></div>
        """

        # Save to file
        with open("pixel_art.html", "w") as f:
            f.write(html_output)

        print(f"Success! pixel_art.html generated with grid size {width}x{height}.")

    except Exception as e:
        print(f"Error: {e}")


if __name__ == "__main__":
    import sys

    if len(sys.argv) < 2:
        print("Image to ASCII/CSS Converter")
        print("=" * 60)
        print("")
        print("MODES:")
        print("  ascii    - Convert to text ASCII art")
        print("  html     - Convert to colored HTML ASCII art")
        print("  css      - Convert to CSS box-shadow pixel art")
        print("  all      - Export ALL charsets to single file")
        print("  list     - Show available charsets")
        print("")
        print("Usage:")
        print("  python img_to_ascii.py ascii <image> [width] [charset] [invert]")
        print("  python img_to_ascii.py html <image> [width] [charset] [invert]")
        print("  python img_to_ascii.py css <image> [width] [pixel_size]")
        print("  python img_to_ascii.py all <image> [width] [invert]")
        print("  python img_to_ascii.py list")
        print("")
        print("Examples:")
        print("  python img_to_ascii.py ascii cat.jpg 80 blocks")
        print("  python img_to_ascii.py ascii cat.jpg 100 braille invert")
        print("  python img_to_ascii.py html cat.jpg 120 dots")
        print("  python img_to_ascii.py all cat.jpg 80")
        print("  python img_to_ascii.py css cat.jpg 64 5")
        print("")
        list_charsets()
        sys.exit(1)

    mode = sys.argv[1]

    if mode == "list":
        list_charsets()

    elif mode == "ascii":
        if len(sys.argv) < 3:
            print("Error: image path required")
            sys.exit(1)
        image_path = sys.argv[2]
        output_width = int(sys.argv[3]) if len(sys.argv) > 3 else 100
        charset = sys.argv[4] if len(sys.argv) > 4 else "detailed"
        invert = "invert" in sys.argv

        art = save_ascii_art(image_path, "ascii_art.txt", output_width, charset, invert)
        print(art)

    elif mode == "html":
        if len(sys.argv) < 3:
            print("Error: image path required")
            sys.exit(1)
        image_path = sys.argv[2]
        output_width = int(sys.argv[3]) if len(sys.argv) > 3 else 100
        charset = sys.argv[4] if len(sys.argv) > 4 else "detailed"
        invert = "invert" in sys.argv

        image_to_html_ascii(image_path, "ascii_art_colored.html", output_width, charset, invert, colored=True)

    elif mode == "all":
        if len(sys.argv) < 3:
            print("Error: image path required")
            sys.exit(1)
        image_path = sys.argv[2]
        output_width = int(sys.argv[3]) if len(sys.argv) > 3 else 80
        invert = "invert" in sys.argv

        export_all_charsets(image_path, "ascii_all_charsets.txt", output_width, invert)

    elif mode == "css":
        if len(sys.argv) < 3:
            print("Error: image path required")
            sys.exit(1)
        image_path = sys.argv[2]
        output_width = int(sys.argv[3]) if len(sys.argv) > 3 else 64
        pixel_size = int(sys.argv[4]) if len(sys.argv) > 4 else 5
        generate_pixel_art_css(image_path, output_width, pixel_size)

    else:
        print(f"Unknown mode: {mode}. Use 'ascii', 'html', 'css', 'all', or 'list'")
