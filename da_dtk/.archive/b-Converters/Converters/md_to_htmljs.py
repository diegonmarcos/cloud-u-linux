# -*- coding: utf-8 -*-
"""
This script takes a Markdown file and generates a self-contained HTML file.

Instead of a static conversion, this HTML file includes the 'marked.js' 
JavaScript library to render the Markdown content dynamically in the browser.
This creates a clean, modern, and easily stylable webpage from your data.
"""

import sys
import os

def create_html_renderer(md_file_path, html_file_path):
    """
    Reads a Markdown file and embeds its content into an HTML template
    that uses a JavaScript library to render it.
    """
    try:
        # --- 1. Read the Markdown content from the input file ---
        print(f"Reading content from '{md_file_path}'...")
        with open(md_file_path, 'r', encoding='utf-8') as f:
            markdown_content = f.read()
    except FileNotFoundError:
        print(f"Error: The file '{md_file_path}' was not found.")
        return
    except Exception as e:
        print(f"An error occurred while reading the Markdown file: {e}")
        return

    # --- 2. Create the HTML structure as a template string ---
    # The markdown_content will be safely embedded inside JavaScript backticks (`)
    html_template = f"""
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Markdown Report</title>
    <!-- Include the Marked.js library from a CDN for rendering -->
    <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
    <!-- Basic, clean styling for readability -->
    <style>
        body {{
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            line-height: 1.6;
            color: #333;
            background-color: #fdfdfd;
            max-width: 900px;
            margin: 0 auto;
            padding: 25px;
        }}
        h1, h2, h3 {{
            color: #222;
            border-bottom: 1px solid #eaecef;
            padding-bottom: 0.3em;
        }}
        table {{
            border-collapse: collapse;
            width: 100%;
            margin-top: 1em;
            margin-bottom: 1em;
            border: 1px solid #dfe2e5;
        }}
        th, td {{
            border: 1px solid #dfe2e5;
            padding: 8px 12px;
            text-align: left;
        }}
        th {{
            background-color: #f6f8fa;
            font-weight: 600;
        }}
        tr:nth-child(even) {{
            background-color: #f6f8fa;
        }}
        code {{
            background-color: #f0f0f0;
            padding: 2px 5px;
            border-radius: 4px;
            font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, Courier, monospace;
        }}
        blockquote {{
            border-left: 4px solid #dfe2e5;
            padding-left: 1em;
            color: #6a737d;
        }}
    </style>
</head>
<body>
    <!-- This div is the container where the rendered HTML will be placed -->
    <div id="markdown-content"></div>

    <script>
        // This is where the magic happens!
        
        // 1. Your Markdown content is safely stored in this JavaScript variable.
        const markdownInput = `{markdown_content}`;

        // 2. Get the container element from the page.
        const contentContainer = document.getElementById('markdown-content');

        // 3. Use the marked.js library to parse the Markdown into HTML.
        const renderedHtml = marked.parse(markdownInput);

        // 4. Set the container's inner HTML to the result.
        contentContainer.innerHTML = renderedHtml;
    </script>
</body>
</html>
    """

    # --- 3. Write the complete HTML string to the output file ---
    try:
        print(f"Generating HTML renderer page at '{html_file_path}'...")
        with open(html_file_path, 'w', encoding='utf-8') as f:
            f.write(html_template)
        print(f"✅ Successfully created '{html_file_path}'. Open it in a browser to see your report.")
    except Exception as e:
        print(f"An error occurred while writing the HTML file: {e}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python md_to_html_renderer.py <input_md_file> <output_html_file>")
        print("Example: python md_to_html_renderer.py my_report.md my_report.html")
        sys.exit(1)
        
    input_file = sys.argv[1]
    output_file = sys.argv[2]
    
    create_html_renderer(input_file, output_file)