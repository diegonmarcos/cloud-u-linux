# -*- coding: utf-8 -*-
"""
This script reads a structured XLSX (Excel) file, checks its size, and then 
converts it into a single TXT file with the data formatted as comma-separated
values (CSV).

This method is highly efficient for creating a portable, plain-text version
of the spreadsheet data.

Required library: pip install openpyxl
"""

import sys
import os
import csv

# --- Library Installation Checks ---
try:
    import openpyxl
except ImportError:
    print("Error: The 'openpyxl' library is required for this script.")
    print("Please install it by running: pip install openpyxl")
    sys.exit(1)

def format_bytes(size_bytes):
    """Converts bytes to a human-readable string (KB, MB, GB)."""
    if size_bytes == 0:
        return "0B"
    size_name = ("B", "KB", "MB", "GB", "TB")
    import math
    i = int(math.floor(math.log(size_bytes, 1024)))
    p = math.pow(1024, i)
    s = round(size_bytes / p, 2)
    return f"{s} {size_name[i]}"

def convert_xlsx_to_txt_csv(xlsx_file_path, txt_file_path):
    """
    Reads an XLSX file and converts its first sheet into a single, 
    CSV-formatted TXT file.
    """
    try:
        # --- 1. Check File Size (as requested) ---
        file_size = os.path.getsize(xlsx_file_path)
        print(f"Input file found: '{os.path.basename(xlsx_file_path)}' ({format_bytes(file_size)})")

        # --- 2. Load the Excel Workbook ---
        print("Loading the Excel workbook...")
        workbook = openpyxl.load_workbook(xlsx_file_path)
        sheet = workbook.active
    except FileNotFoundError:
        print(f"Error: The file '{xlsx_file_path}' was not found.")
        return
    except Exception as e:
        print(f"An error occurred while opening the Excel file: {e}")
        return

    # --- 3. Write to the TXT file using the csv module ---
    try:
        print("Converting to CSV-formatted TXT file...")
        # 'newline=""' is important to prevent extra blank rows
        with open(txt_file_path, 'w', newline='', encoding='utf-8') as txtfile:
            # Create a csv writer which will handle proper quoting and commas
            csv_writer = csv.writer(txtfile)
            
            # Efficiently iterate through all rows and write them
            for row in sheet.iter_rows(values_only=True):
                csv_writer.writerow(row)
        
        print(f"✅ Successfully converted '{xlsx_file_path}' to '{txt_file_path}'")
    except Exception as e:
        print(f"An error occurred while writing the TXT file: {e}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python xlsx_to_txt_converter.py <input_xlsx_file> <output_txt_file>")
        print("Example: python xlsx_to_txt_converter.py Cronologia.xlsx Cronologia_data.txt")
        sys.exit(1)
        
    input_file = sys.argv[1]
    output_file = sys.argv[2]
    
    convert_xlsx_to_txt_csv(input_file, output_file)