# -*- coding: utf-8 -*-
"""
This script converts a JSON file containing semantic location history 
into a structured XLSX (Excel) file with geocoding.

This version includes a fix for environments like Termux where multiprocessing
can fail, by forcing the geocoder to run in single-threaded mode.

Required libraries: pip install openpyxl reverse-geocoder
"""

import json
import sys
from datetime import datetime

# --- Library Installation Check ---
try:
    import openpyxl
except ImportError:
    print("Error: The 'openpyxl' library is required.")
    print("Please install it by running: pip install openpyxl")
    sys.exit(1)

try:
    import reverse_geocoder as rg
except ImportError:
    print("Error: The 'reverse-geocoder' library is required for this script.")
    print("Please install it by running: pip install reverse-geocoder")
    sys.exit(1)

# --- Geocoding Function ---
def get_location_details(coord_string):
    """
    Converts a coordinate string into a city and country using offline reverse geocoding.

    Args:
        coord_string (str): A string containing latitude and longitude, e.g., "42.44, 19.26".

    Returns:
        tuple: A tuple containing the city and country code (e.g., ("Podgorica", "ME")).
               Returns ("N/A", "N/A") if input is invalid or location is not found.
    """
    if not coord_string or ',' not in coord_string:
        return "N/A", "N/A"
    
    try:
        # The library expects a tuple of (latitude, longitude) as numbers.
        lat, lon = map(float, coord_string.split(','))
        coordinates = (lat, lon)
        
        # --- THE FIX IS HERE ---
        # We add `mode=1` to force single-threaded operation, which is compatible with Termux.
        # The default mode (2) uses multiprocessing and can cause errors on some systems.
        results = rg.search(coordinates, mode=1)
        
        if results:
            location_info = results[0]
            city = location_info.get('name', 'Unknown City')
            country_code = location_info.get('cc', '??')
            return city, country_code
        else:
            return "Not Found", "N/A"
    except (ValueError, IndexError) as e:
        print(f"Warning: Could not process coordinates '{coord_string}'. Error: {e}")
        return "Invalid Coords", "N/A"

# --- Main Data Processing Function ---
def get_segment_details(segment):
    """
    Extracts detailed information from a JSON segment, including geocoded locations.

    Args:
        segment (dict): A dictionary representing a single semantic segment.

    Returns:
        dict: A dictionary containing structured data for an Excel row.
    """
    details = {
        "Segment Type": "Unknown",
        "Start Time": segment.get("startTime", ""),
        "End Time": segment.get("endTime", ""),
        "Duration (minutes)": "",
        "Details": "",
        "Start Coordinates": "", "Start City": "", "Start Country": "",
        "End Coordinates": "", "End City": "", "End Country": "",
        "Distance (meters)": ""
    }

    try:
        # Calculate duration
        start_time = datetime.fromisoformat(details["Start Time"])
        end_time = datetime.fromisoformat(details["End Time"])
        duration = (end_time - start_time).total_seconds() / 60
        details["Duration (minutes)"] = round(duration, 2)

        start_coord_str, end_coord_str = "", ""

        # --- Extract Coordinates Based on Segment Type ---
        if "visit" in segment:
            details["Segment Type"] = "Visit"
            visit_info = segment["visit"]["topCandidate"]
            place_type = visit_info.get("semanticType", "Unknown Place")
            details["Details"] = f"Type: {place_type}"
            start_coord_str = visit_info.get("placeLocation", {}).get("latLng", "").replace('°', '')

        elif "timelinePath" in segment:
            details["Segment Type"] = "Path"
            path_points = segment.get("timelinePath", [])
            num_points = len(path_points)
            details["Details"] = f"{num_points} GPS point(s)"
            if num_points > 0:
                start_coord_str = path_points[0].get("point", "").replace('°', '')
                end_coord_str = path_points[-1].get("point", "").replace('°', '')

        elif "activity" in segment:
            details["Segment Type"] = "Activity"
            activity_data = segment["activity"]
            activity_type = activity_data.get("topCandidate", {}).get("type", "Unknown").replace('_', ' ').title()
            details["Details"] = activity_type
            details["Distance (meters)"] = round(activity_data.get("distanceMeters", 0))
            start_coord_str = activity_data.get("start", {}).get("latLng", "").replace('°', '')
            end_coord_str = activity_data.get("end", {}).get("latLng", "").replace('°', '')

        # --- Perform Geocoding ---
        if start_coord_str:
            details["Start Coordinates"] = start_coord_str
            details["Start City"], details["Start Country"] = get_location_details(start_coord_str)
        
        if end_coord_str:
            details["End Coordinates"] = end_coord_str
            details["End City"], details["End Country"] = get_location_details(end_coord_str)

    except (KeyError, TypeError, ValueError) as e:
        print(f"Warning: Could not fully parse a segment. Error: {e}")
    
    return details

# --- File Conversion Logic ---
def convert_json_to_xlsx(json_file_path, xlsx_file_path):
    """
    Reads a JSON file, converts its content to XLSX with geocoding, and saves it.
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
        
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "Timeline Data"
    
    headers = [
        "Segment Type", "Start Time", "End Time", "Duration (minutes)", 
        "Details", "Start Coordinates", "Start City", "Start Country",
        "End Coordinates", "End City", "End Country", "Distance (meters)"
    ]
    ws.append(headers)
    
    # Process each segment and write it as a new row
    # Sorting by start time to ensure chronological order
    for segment in sorted(segments, key=lambda x: x.get('startTime', '')):
        segment_details = get_segment_details(segment)
        row_data = [segment_details.get(h, "") for h in headers]
        ws.append(row_data)

    try:
        wb.save(xlsx_file_path)
        print(f"Successfully converted and geocoded '{json_file_path}' to '{xlsx_file_path}'")
    except Exception as e:
        print(f"An error occurred while saving the Excel file: {e}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        # Adjusted the file name in the usage instructions
        print("Usage: python json_to_xlsx_converter_fixed.py <input_json_file> <output_xlsx_file>")
        sys.exit(1)
        
    input_file = sys.argv[1]
    output_file = sys.argv[2]
    
    print("Starting conversion and geocoding process in compatibility mode...")
    print("This may take a few moments as the geocoding data is loaded into memory.")
    convert_json_to_xlsx(input_file, output_file)