# -*- coding: utf-8 -*-
"""
This script reads a structured XLSX (Excel) file and converts it into a 
Markdown file with a properly formatted table.

It's designed to work with the output from the json_to_xlsx_converter.py script
but can be adapted for any simple Excel table.

It requires the 'openpyxl' library to be installed.
You can install it by running: pip install openpyxl
"""

import sys

# --- Library Installation Check ---
try:
    import openpyxl
except ImportError:
    print("Error: The 'openpyxl' library is required to run this script.")
    print("Please install it by running: pip install openpyxl")
    sys.exit(1)

def convert_xlsx_to_md(xlsx_file_path, md_file_path):
    """
    Reads an XLSX file and converts the first sheet into a Markdown table.

    Args:
        xlsx_file_path (str): The path to the input Excel file.
        md_file_path (str): The path where the output Markdown file will be saved.
    """
    try:
        # Load the Excel workbook and select the first active sheet
        workbook = openpyxl.load_workbook(xlsx_file_path)
        sheet = workbook.active
    except FileNotFoundError:
        print(f"Error: The file '{xlsx_file_path}' was not found.")
        return
    except Exception as e:
        print(f"An error occurred while opening the Excel file: {e}")
        return

    markdown_table = []
    
    # --- Read the Header Row ---
    header = [str(cell.value) for cell in sheet[1]]
    header_line = "| " + " | ".join(header) + " |"
    markdown_table.append(header_line)
    
    # --- Create the Markdown Separator Line ---
    separator_line = "| " + " | ".join(["---"] * len(header)) + " |"
    markdown_table.append(separator_line)
    
    # --- Read and Format Data Rows ---
    # We iterate from the second row to skip the header
    for row in sheet.iter_rows(min_row=2):
        # Ensure all cell values are converted to string to avoid errors
        row_values = [str(cell.value if cell.value is not None else "") for cell in row]
        row_line = "| " + " | ".join(row_values) + " |"
        markdown_table.append(row_line)
        
    # --- Write to the Markdown File ---
    try:
        with open(md_file_path, 'w', encoding='utf-8') as f:
            for line in markdown_table:
                f.write(line + "\n")
        print(f"✅ Successfully converted '{xlsx_file_path}' to '{md_file_path}'")
    except Exception as e:
        print(f"An error occurred while writing the Markdown file: {e}")

if __name__ == "__main__":
    # Example usage:
    # python xlsx_to_md_converter.py my_timeline.xlsx my_timeline_summary.md
    
    if len(sys.argv) != 3:
        print("Usage: python xlsx_to_md_converter.py <input_xlsx_file> <output_md_file>")
        sys.exit(1)
        
    input_file = sys.argv[1]
    output_file = sys.argv[2]
    
    convert_xlsx_to_md(input_file, output_file)