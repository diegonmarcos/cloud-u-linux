# -*- coding: utf-8 -*-
"""
This script converts a JSON file containing semantic location history 
(like Google Timeline data) into a KML file that can be viewed in Google Earth.

It processes segments that are either paths (LineString) or visits (Point).
"""

import json
from xml.etree.ElementTree import Element, SubElement, tostring, ElementTree
from xml.dom.minidom import parseString
import sys

def create_placemark(segment):
    """
    Creates a KML <Placemark> element from a single JSON segment.

    Args:
        segment (dict): A dictionary representing a single semantic segment from the JSON file.

    Returns:
        Element: An XML Element object for the KML Placemark.
    """
    placemark = Element("Placemark")
    
    # Set the name of the placemark
    name_text = "Path" # Default name
    if "visit" in segment and "topCandidate" in segment["visit"]:
        visit_info = segment["visit"]["topCandidate"]
        # Use semanticType if available, otherwise use placeId
        name_text = visit_info.get("semanticType", visit_info.get("placeId", "Visit"))
    
    name_element = SubElement(placemark, "name")
    name_element.text = name_text
    
    # Create a detailed description for the placemark's popup balloon
    description_text = (
        f"<b>Start Time:</b> {segment.get('startTime', 'N/A')}<br/>"
        f"<b>End Time:</b> {segment.get('endTime', 'N/A')}"
    )
    description_element = SubElement(placemark, "description")
    description_element.text = description_text

    # Check if the segment is a path with coordinates
    if "timelinePath" in segment and segment["timelinePath"]:
        linestring = SubElement(placemark, "LineString")
        # tessellate allows the line to follow the curvature of the Earth
        tessellate = SubElement(linestring, "tessellate")
        tessellate.text = "1"
        coordinates = SubElement(linestring, "coordinates")
        
        # Format coordinates: KML expects (longitude, latitude, altitude)
        coords_text = []
        for p in segment["timelinePath"]:
            try:
                # Remove degree symbol and split into latitude and longitude
                lat_str, lon_str = p["point"].replace('°', '').split(',')
                lat = float(lat_str.strip())
                lon = float(lon_str.strip())
                # Append in lon,lat,alt format
                coords_text.append(f"{lon},{lat},0")
            except (ValueError, IndexError) as e:
                print(f"Warning: Could not parse point data: {p['point']}. Error: {e}")
                continue
        coordinates.text = " ".join(coords_text)

    # Check if the segment is a single visit point
    elif "visit" in segment and "topCandidate" in segment["visit"]:
        visit_location = segment["visit"]["topCandidate"].get("placeLocation", {}).get("latLng")
        if visit_location:
            point = SubElement(placemark, "Point")
            coordinates = SubElement(point, "coordinates")
            try:
                lat_str, lon_str = visit_location.replace('°', '').split(',')
                lat = float(lat_str.strip())
                lon = float(lon_str.strip())
                coordinates.text = f"{lon},{lat},0"
            except (ValueError, IndexError) as e:
                print(f"Warning: Could not parse visit location: {visit_location}. Error: {e}")

    return placemark

def convert_json_to_kml(json_file_path, kml_file_path):
    """
    Reads a JSON file, converts its content to KML format, and saves it.

    Args:
        json_file_path (str): The path to the input JSON file.
        kml_file_path (str): The path where the output KML file will be saved.
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
    except Exception as e:
        print(f"An unexpected error occurred while reading the file: {e}")
        return

    # Create the root KML structure
    kml = Element("kml", xmlns="http://www.opengis.net/kml/2.2")
    document = SubElement(kml, "Document")
    
    # Add a name and description for the KML document itself
    doc_name = SubElement(document, "name")
    doc_name.text = f"Timeline from {json_file_path}"
    doc_description = SubElement(document, "description")
    doc_description.text = "Location history converted from JSON."

    segments = data.get("semanticSegments")
    if not segments:
        print("Error: No 'semanticSegments' found in the JSON file.")
        return

    # Process each segment and add it to the document
    for segment in segments:
        placemark = create_placemark(segment)
        document.append(placemark)

    # Pretty-print the XML to make it readable
    xml_string = tostring(kml, 'utf-8')
    pretty_xml_string = parseString(xml_string).toprettyxml(indent="  ")

    # Write the KML content to the output file
    try:
        with open(kml_file_path, 'w', encoding='utf-8') as f:
            f.write(pretty_xml_string)
        print(f"Successfully converted '{json_file_path}' to '{kml_file_path}'")
    except Exception as e:
        print(f"An error occurred while writing the KML file: {e}")


if __name__ == "__main__":
    # This allows the script to be run from the command line.
    # Example usage:
    # python json_to_kml_converter.py input.json output.kml
    
    if len(sys.argv) != 3:
        print("Usage: python json_to_kml_converter.py <input_json_file> <output_kml_file>")
        sys.exit(1)
        
    input_file = sys.argv[1]
    output_file = sys.argv[2]
    
    convert_json_to_kml(input_file, output_file)