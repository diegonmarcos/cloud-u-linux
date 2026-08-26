# --- DELAYED IMPORTS ---
# Python imports are placed inside a try/except block to provide the user
# with clear instructions on missing dependencies BEFORE the script crashes.
try:
    from PIL import Image
    import pytesseract
    import os
    import sys
    from glob import glob
except ImportError:
    print("\n[SETUP REQUIRED] Python dependencies 'pytesseract' and 'Pillow' are missing.")
    print("\nACTION: Please install the Python packages:")
    print("1. Activate your virtual environment (recommended).")
    print("2. Run: pip install pytesseract Pillow")
    sys.exit(1)


# ==============================================================================
# BATCH/SINGLE IMAGE-TO-MARKDOWN CONVERTER (Flexible Input)
#
# Processes either a single image file or all images in a specified directory.
#
# PREREQUISITES:
# 1. System: Tesseract OCR Engine (e.g., sudo apt install tesseract-ocr)
# 2. Python: pytesseract, Pillow (pip install pytesseract Pillow)
#
# USAGE:
#   1. Process a folder: python3 batch_ocr_flexible.py <path_to_folder>
#   2. Process a file:   python3 batch_ocr_flexible.py <path_to_image_file>
# ==============================================================================

# --- Configuration ---
OUTPUT_SUBDIR_NAME = 'md_files'

# Supported image extensions (for validation and glob search)
VALID_IMAGE_EXTENSIONS = ('.jpg', '.jpeg', '.png', '.tiff', '.tif')

# Tesseract configuration string (optional)
TESSERACT_CONFIG = '--oem 3 --psm 3'


def print_usage_and_exit(exit_code=0):
    """Prints usage information and exits the script."""
    script_name = os.path.basename(sys.argv[0])

    print("\n--- OCR BATCH/SINGLE CONVERTER ---")
    print("Converts image files or all images in a folder into Markdown files.")

    print("\nUSAGE:")
    print(f"  python3 {script_name} <path_to_source>")

    print("\nEXAMPLES:")
    print("  1. Process a Directory:")
    print(f"     python3 {script_name} /home/user/project_docs")
    print(f"     -> Output is saved to: /home/user/project_docs/{OUTPUT_SUBDIR_NAME}/")
    print("  2. Process a Single File:")
    print(f"     python3 {script_name} /home/user/notes/diagram.png")
    print(f"     -> Output is saved to: /home/user/notes/diagram.md (next to the image)")

    print("\nNOTE:")
    print(f"  - Supported file types: {', '.join(VALID_IMAGE_EXTENSIONS)}")
    print("---------------------------\n")
    sys.exit(exit_code)


def check_tesseract_availability():
    """Checks if the Tesseract executable is installed and accessible."""
    try:
        pytesseract.get_tesseract_version()
        print("[SUCCESS] Tesseract executable found and accessible.")
        return True
    except pytesseract.TesseractNotFoundError:
        print("\n[CRITICAL ERROR] Tesseract executable not found.")
        print("ACTION: The Tesseract OCR Engine must be installed system-wide.")
        print("For Debian/Ubuntu/Mint, run: sudo apt update && sudo apt install tesseract-ocr")
        print("For Fedora/CentOS/RHEL, run: sudo dnf install tesseract")
        return False
    except Exception as e:
        print(f"[ERROR] An unexpected error occurred while checking Tesseract: {e}")
        return False


def convert_and_save(image_path: str, output_dir: str) -> bool:
    """
    Extracts text from a single image and saves it as a Markdown file.
    """
    try:
        img = Image.open(image_path)

        # Perform OCR
        markdown_text = pytesseract.image_to_string(img, config=TESSERACT_CONFIG)

        # Determine output file path
        base_name = os.path.splitext(os.path.basename(image_path))[0]
        output_filename = f"{base_name}.md"
        output_filepath = os.path.join(output_dir, output_filename)

        # Write the text to the Markdown file
        with open(output_filepath, 'w', encoding='utf-8') as f:
            f.write(f"# OCR Result for: {os.path.basename(image_path)}\n\n")
            f.write("--- Extracted Text ---\n\n")
            f.write(markdown_text.strip())
            f.write("\n\n--- End of Text ---")

        print(f"   [DONE] Converted to {output_filepath}")
        return True

    except Exception as e:
        print(f"   [ERROR] Failed to convert {os.path.basename(image_path)}: {e}")
        return False


def handle_batch_conversion(source_dir):
    """Handles conversion for all images in a directory."""

    # 1. Setup Output Directory (inside source_dir)
    output_dir = os.path.join(source_dir, OUTPUT_SUBDIR_NAME)
    if not os.path.exists(output_dir):
        os.makedirs(output_dir)
        print(f"[SETUP] Created output directory: {output_dir}/")

    print(f"\n--- Starting Batch OCR Conversion in: {source_dir} ---")

    # 2. Find Images
    image_files = []
    # Search for files within the source_dir
    for ext in VALID_IMAGE_EXTENSIONS:
        # glob expects the full path pattern
        image_files.extend(glob(os.path.join(source_dir, f'*{ext}')))

    if not image_files:
        print("\n[INFO] No supported image files found in the source directory.")
        return

    print(f"\n[INFO] Found {len(image_files)} image(s) to process.")

    successful_conversions = 0

    for i, file_path in enumerate(image_files, 1):
        print(f"\nProcessing {i}/{len(image_files)}: {os.path.basename(file_path)}")
        if convert_and_save(file_path, output_dir):
            successful_conversions += 1

    # 3. Summary
    print("\n--- Batch Conversion Complete ---")
    print(f"Total Images Scanned: {len(image_files)}")
    print(f"Successful Conversions: {successful_conversions}")
    print(f"All Markdown files are saved in the '{output_dir}/' folder.")
    print("---------------------------------")


def handle_single_file_conversion(source_file):
    """Handles conversion for a single image file."""

    print(f"\n--- Starting Single File OCR Conversion ---")

    # The output directory is the directory containing the source file
    output_dir = os.path.dirname(source_file)

    print(f"Processing: {os.path.basename(source_file)}")

    if convert_and_save(source_file, output_dir):
        print("\n--- Single Conversion Complete ---")
        print(f"Markdown file saved next to the source image.")
        print("----------------------------------")
    else:
        print("\n--- Single Conversion FAILED ---")


if __name__ == "__main__":
    # Check for correct number of arguments: script name + one path argument
    if len(sys.argv) != 2:
        print_usage_and_exit()

    # Get the absolute path of the argument
    source_path = os.path.abspath(sys.argv[1])

    # 1. Global Pre-Check (Tesseract)
    if not check_tesseract_availability():
        sys.exit(1)

    try:
        if os.path.isdir(source_path):
            # Argument is a directory -> Batch Mode
            handle_batch_conversion(source_path)

        elif os.path.isfile(source_path):
            # Argument is a file -> Single File Mode

            # Check if the file is a supported image type
            file_extension = os.path.splitext(source_path)[1].lower()
            if file_extension in VALID_IMAGE_EXTENSIONS:
                handle_single_file_conversion(source_path)
            else:
                print(f"\n[ERROR] File extension '{file_extension}' not supported.")
                print_usage_and_exit(1)

        else:
            # Argument is neither a valid file nor a directory
            print(f"\n[ERROR] Invalid input: '{source_path}' is neither a file nor a directory.")
            print_usage_and_exit(1)

    except Exception as e:
        print(f"\n[CRITICAL ERROR] Script failed during execution: {e}")
        sys.exit(1)
