#!/usr/bin/env python3
import re
import subprocess
import os

def get_override_issues():
    """Get all @override issues from flutter analyze"""
    result = subprocess.run(['flutter', 'analyze'], capture_output=True, text=True)
    issues = []
    
    for line in result.stdout.split('\n'):
        if 'annotate_overrides' in line:
            match = re.search(r'(\S+\.dart):(\d+):(\d+)', line)
            if match:
                file_path = match.group(1)
                line_num = int(match.group(2))
                col_num = int(match.group(3))
                issues.append((file_path, line_num, col_num))
    
    return issues

def fix_override(file_path, line_num):
    """Add @override annotation before the specified line"""
    if not os.path.exists(file_path):
        print(f"File not found: {file_path}")
        return False
    
    with open(file_path, 'r') as f:
        lines = f.readlines()
    
    if line_num <= 0 or line_num > len(lines):
        print(f"Invalid line number {line_num} for {file_path}")
        return False
    
    # Find the correct indentation
    target_line = lines[line_num - 1]
    indent_match = re.match(r'^(\s*)', target_line)
    indent = indent_match.group(1) if indent_match else ''
    
    # Check if @override already exists (sometimes analyzer is outdated)
    if line_num > 1:
        prev_line = lines[line_num - 2].strip()
        if prev_line == '@override':
            print(f"@override already exists before line {line_num} in {file_path}")
            return False
    
    # Insert @override with same indentation
    lines.insert(line_num - 1, f"{indent}@override\n")
    
    with open(file_path, 'w') as f:
        f.writelines(lines)
    
    return True

def main():
    print("Fixing missing @override annotations...")
    
    issues = get_override_issues()
    print(f"Found {len(issues)} missing @override annotations")
    
    # Group by file to process efficiently
    files_to_fix = {}
    for file_path, line_num, col_num in issues:
        if file_path not in files_to_fix:
            files_to_fix[file_path] = []
        files_to_fix[file_path].append(line_num)
    
    fixed_count = 0
    for file_path, line_nums in files_to_fix.items():
        print(f"\nProcessing {file_path}...")
        # Sort line numbers in reverse to avoid offset issues
        for line_num in sorted(line_nums, reverse=True):
            if fix_override(file_path, line_num):
                fixed_count += 1
                print(f"  Added @override before line {line_num}")
    
    print(f"\nFixed {fixed_count} @override annotations")
    
    # Run analyzer again to check
    print("\nRunning analyzer again to verify...")
    subprocess.run(['flutter', 'analyze'])

if __name__ == "__main__":
    main()