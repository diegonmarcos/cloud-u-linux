# -*- coding: utf-8 -*-
"""
This script converts a JSON file containing semantic location history 
(like Google Timeline data) into a human-readable Markdown file.

It processes and summarizes segments like paths, visits, and activities,
grouping them by date.
"""

import json
import sys
from datetime import datetime

def format_segment(segment):
    """
    Formats a single JSON segment into a Markdown list item.

    Args:
        segment (dict): A dictionary representing a single semantic segment.

    Returns:
        str: A Markdown-formatted string for the segment.
    """
    try:
        # Extract and format start and end times
        start_time_str = segment.get('startTime', '')
        end_time_str = segment.get('endTime', '')
        
        start_time = datetime.fromisoformat(start_time_str).strftime('%H:%M:%S')
        end_time = datetime.fromisoformat(end_time_str).strftime('%H:%M:%S')

        time_range = f"**{start_time} to {end_time}**"

        # Case 1: The segment is a visit to a specific place
        if "visit" in segment:
            visit_info = segment["visit"]["topCandidate"]
            place_type = visit_info.get("semanticType", "Unknown Place")
            location = visit_info.get("placeLocation", {}).get("latLng", "N/A")
            return f"- {time_range}: Visited **{place_type}** at location `{location}`."

        # Case 2: The segment is a travel path
        elif "timelinePath" in segment:
            num_points = len(segment["timelinePath"])
            return f"- {time_range}: Traveled along a path with {num_points} recorded point(s)."
        
        # Case 3: The segment is a specific activity (like walking, driving)
        elif "activity" in segment:
            activity_info = segment["activity"]["topCandidate"]
            activity_type = activity_info.get("type", "Unknown").replace('_', ' ').title()
            distance = round(segment["activity"].get("distanceMeters", 0))
            return f"- {time_range}: Activity: **{activity_type}** for {distance} meters."
        
        # Fallback for unknown segment types
        else:
            return f"- {time_range}: An unknown activity occurred."

    except (KeyError, TypeError, ValueError) as e:
        # Handle cases where data might be missing or malformed
        print(f"Warning: Skipping a malformed segment. Error: {e}")
        return None


def convert_json_to_md(json_file_path, md_file_path):
    """
    Reads a JSON timeline file, converts its content to Markdown, and saves it.

    Args:
        json_file_path (str): The path to the input JSON file.
        md_file_path (str): The path where the output Markdown file will be saved.
    """
    try:
        with open(json_file_path, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except FileNotFoundError:
        print(f"Error: The file '{json_file_path}' was not found.")
        return
    except json.JSONDecodeError:
        print(f"Error: The file '{json_file_path}' is not a valid JSON file.")
        return

    segments = data.get("semanticSegments")
    if not segments:
        print("Error: No 'semanticSegments' found in the JSON file.")
        return

    # Group segments by date
    grouped_segments = {}
    for segment in segments:
        try:
            date_key = datetime.fromisoformat(segment['startTime']).strftime('%Y-%m-%d, %A')
            if date_key not in grouped_segments:
                grouped_segments[date_key] = []
            grouped_segments[date_key].append(segment)
        except (KeyError, ValueError):
            print(f"Warning: Skipping segment with invalid startTime: {segment.get('startTime')}")
            continue
            
    # Start building the Markdown content
    markdown_lines = [f"# Timeline from {json_file_path}\n"]

    # Sort dates chronologically and add formatted segments to the output
    for date in sorted(grouped_segments.keys()):
        markdown_lines.append(f"## {date}\n")
        for segment in grouped_segments[date]:
            formatted_line = format_segment(segment)
            if formatted_line:
                markdown_lines.append(formatted_line)
        markdown_lines.append("") # Add a blank line for spacing

    # Write the Markdown content to the output file
    try:
        with open(md_file_path, 'w', encoding='utf-8') as f:
            f.write("\n".join(markdown_lines))
        print(f"Successfully converted '{json_file_path}' to '{md_file_path}'")
    except Exception as e:
        print(f"An error occurred while writing the Markdown file: {e}")


if __name__ == "__main__":
    # This allows the script to be run from the command line.
    # Example usage:
    # python json_to_md_converter.py input.json output.md
    
    if len(sys.argv) != 3:
        print("Usage: python json_to_md_converter.py <input_json_file> <output_md_file>")
        sys.exit(1)
        
    input_file = sys.argv[1]
    output_file = sys.argv[2]
    
    convert_json_to_md(input_file, output_file)