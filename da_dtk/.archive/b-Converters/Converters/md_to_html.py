# -*- coding: utf-8 -*-
"""
This script performs a static conversion of a Markdown file into a 
single, self-contained HTML file with embedded CSS for styling.

It correctly handles headings, bold, italic, lists, and tables, removing
the Markdown syntax characters in the process.

This requires the 'Markdown' library to be installed.
You can install it by running: pip install Markdown
"""

import sys

# --- Library Installation Check ---
try:
    import markdown
except ImportError:
    print("Error: The 'Markdown' library is required to run this script.")
    print("Please install it by running: pip install Markdown")
    sys.exit(1)

def convert_md_to_static_html(md_file_path, html_file_path):
    """
    Reads a Markdown file, converts it to HTML, and saves it as a single
    file with embedded CSS.
    """
    try:
        print(f"Reading content from '{md_file_path}'...")
        with open(md_file_path, 'r', encoding='utf-8') as f:
            markdown_content = f.read()
    except FileNotFoundError:
        print(f"Error: The file '{md_file_path}' was not found.")
        return
    except Exception as e:
        print(f"An error occurred while reading the Markdown file: {e}")
        return

    # --- Convert Markdown to HTML using the library ---
    # The 'tables' extension is included to properly handle Markdown tables.
    print("Converting Markdown to HTML...")
    html_body_content = markdown.markdown(markdown_content, extensions=['tables'])

    # --- Define the embedded CSS for styling ---
    css_style = """
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            line-height: 1.6;
            color: #333;
            background-color: #fdfdfd;
            max-width: 900px;
            margin: 20px auto;
            padding: 25px;
            border: 1px solid #e1e1e1;
            border-radius: 8px;
            box-shadow: 0 2px 8px rgba(0,0,0,0.05);
        }
        h1, h2, h3, h4, h5, h6 {
            color: #222;
            border-bottom: 1px solid #eaecef;
            padding-bottom: 0.3em;
            margin-top: 24px;
            margin-bottom: 16px;
        }
        p {
            margin-bottom: 1em;
        }
        ul, ol {
            padding-left: 2em;
        }
        li {
            margin-bottom: 0.5em;
        }
        table {
            border-collapse: collapse;
            width: 100%;
            margin: 1.5em 0;
            border: 1px solid #dfe2e5;
            display: block;
            overflow-x: auto; /* For responsive tables */
        }
        th, td {
            border: 1px solid #dfe2e5;
            padding: 10px 14px;
            text-align: left;
        }
        th {
            background-color: #f6f8fa;
            font-weight: 600;
        }
        tr:nth-child(even) {
            background-color: #f6f8fa;
        }
        strong {
            font-weight: 600;
        }
    """

    # --- Create the final HTML document structure ---
    html_template = f"""
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Report</title>
    <style>
        {css_style}
    </style>
</head>
<body>
    {html_body_content}
</body>
</html>
    """

    # --- Write the complete HTML string to the output file ---
    try:
        print(f"Generating static HTML file at '{html_file_path}'...")
        with open(html_file_path, 'w', encoding='utf-8') as f:
            f.write(html_template)
        print(f"✅ Successfully created '{html_file_path}'.")
    except Exception as e:
        print(f"An error occurred while writing the HTML file: {e}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python md_to_html_converter.py <input_md_file> <output_html_file>")
        print("Example: python md_to_html_converter.py my_report.md my_static_report.html")
        sys.exit(1)
        
    input_file = sys.argv[1]
    output_file = sys.argv[2]
    
    convert_md_to_static_html(input_file, output_file)