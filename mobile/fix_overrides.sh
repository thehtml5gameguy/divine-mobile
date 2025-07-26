#!/bin/bash

# Script to add missing @override annotations based on analyzer output

echo "Fixing missing @override annotations..."

# Get all files with missing @override annotations
flutter analyze 2>&1 | grep "annotate_overrides" | awk -F':' '{print $1}' | sort -u > files_to_fix.txt

# Count total files
total_files=$(wc -l < files_to_fix.txt)
echo "Found $total_files files with missing @override annotations"

# Process each file
while IFS= read -r file; do
    if [ -f "$file" ]; then
        echo "Processing: $file"
        
        # Get all methods needing @override in this file
        flutter analyze 2>&1 | grep "$file" | grep "annotate_overrides" | while IFS= read -r line; do
            # Extract the line number and method name
            line_num=$(echo "$line" | awk -F':' '{print $2}')
            method_info=$(echo "$line" | sed -n "s/.*The member '\([^']*\)' overrides.*/\1/p")
            
            if [ -n "$line_num" ] && [ -n "$method_info" ]; then
                # Add @override annotation before the line
                # Using awk to insert @override before the method
                awk -v line="$line_num" 'NR==line{print "  @override"} {print}' "$file" > "${file}.tmp"
                mv "${file}.tmp" "$file"
                echo "  Added @override before line $line_num for '$method_info'"
            fi
        done
    fi
done < files_to_fix.txt

rm -f files_to_fix.txt

echo "Done fixing @override annotations"