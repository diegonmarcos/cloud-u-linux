from PIL import Image
import numpy as np
import argparse
from potrace import Bitmap

def raster_to_svg_potrace(image_path, output_svg_path, threshold=128, invert=False):
    # 1. Load the image using Pillow
    img = Image.open(image_path).convert('L') # Convert to grayscale

    # 2. Convert to a 1-bit (black and white) image for Potrace
    binary_img = img.point(lambda p: 0 if p < threshold else 255, '1')

    # Invert if needed
    if invert:
        binary_img = Image.fromarray(np.invert(np.array(binary_img)))

    # 3. Create a Potrace bitmap
    bm = Bitmap(binary_img)

    # 4. Trace the bitmap
    plist = bm.trace()

    # 5. Save the SVG
    with open(output_svg_path, "w") as fp:
        fp.write(f'<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="{img.width}" height="{img.height}" viewBox="0 0 {img.width} {img.height}">')
        for curve in plist:
            fp.write('<path d="')
            start = curve.start_point
            fp.write(f'M{start.x},{start.y}')
            for segment in curve:
                if segment.is_corner:
                    c = segment.c
                    end = segment.end_point
                    fp.write(f'L{c.x},{c.y}L{end.x},{end.y}')
                else:
                    c1 = segment.c1
                    c2 = segment.c2
                    end = segment.end_point
                    fp.write(f'C{c1.x},{c1.y} {c2.x},{c2.y} {end.x},{end.y}')
            fp.write('Z"/>')
        fp.write('</svg>')

    print(f"SVG saved to {output_svg_path}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Convert a raster image to SVG using Potrace.')
    parser.add_argument('input_file', help='The input raster image file (e.g., PNG, JPG).')
    parser.add_argument('output_file', help='The output SVG file.')
    parser.add_argument('--threshold', type=int, default=128, help='The threshold for converting to a binary image (0-255).')
    parser.add_argument('--invert', action='store_true', help='Invert the colors of the image before tracing.')
    args = parser.parse_args()

    raster_to_svg_potrace(args.input_file, args.output_file, args.threshold, args.invert)