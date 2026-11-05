#!/bin/bash
# script.sh, compares files using diff
# pchalut

# Loop for each Testcase directory
for n in 1 2 3 4; do
	inputDir="Testcase$n"
	outputDir="Testcase${n}Diff"

	# remove old directory (if it exists)
	rm -rf "$outputDir"

	# Loop through files inside Testcase directory
	for file1 in "$inputDir"/*.1.txt; do
		# Use beginning of file1 name to find matching pair with .2.txt postfix
		file2="${file1%.1.txt}.2.txt"

		# If there is no difference byte wise then skip current iteration
		if cmp -s "$file1" "$file2"; then
			continue
		fi

		# Strip the file path from the beginning to just get file name
		base=$(basename "$file1" .1.txt)
		diffOut="${base}Diff.txt"
		
		# Create diff directory and output diff into a file in that directory
		mkdir -p $outputDir
		diff -u $file1 $file2 > "$outputDir/$diffOut"
	done
done
