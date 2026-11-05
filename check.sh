#!/bin/bash
# check.sh, checks script.sh

exitCode=0

for n in 1 2 3 4; do
	inputDir="Testcase$n"
	outputDir="Testcase${n}Diff"

	# testFail = 0 if testcase passed, 1 if failed
	# numDiff stores the number of pairs that are different
	testFail = 0
	numDiff = 0

	for file1 in "inputDir"/*1.txt;do
		file2="${file1%.1.txt}.2.txt"

		baseName=$(basename "$file1" .1.txt)
		outputFile="$outputDir/${baseName}Diff.txt"

		# Check if files are identical, if they are they should not have an output file
		if cmp -s "$file1" "$file2";then
			if [ -f "$outputFile" ];then
				echo "error: $outputFile should not exist (files are identical)" >&2
				testFail=1
			fi
		else
			# Files do differ, check if the output file exists and if it matches diff
			numDiff=$((numDiff + 1))

			# Check if diff output exists
			if [ ! -f "$outputFile"]; then
				echo "error: $outputFile is missing" >&2
				testFail=1
			# Check if diff output matches
		elif ! cmp -s <(tail -n +3 <(diff -u "$file1" "$file2")) <(tail -n +3 "$outputFile"); then
				echo "error: diff output does not match in $outputFile" >&2
				testFail=1
			fi
		fi
	done

	if [ "$numDiff" -gt 0 ]; then
        	# Check if directory exists for different files
		if [ ! -d "$outputDir" ]; then
            		echo "error: missing directory $outputDir" >&2
            		testFail=1
        	fi
	# Directory should not exist if there are no files that differ
    	elif [ -d "$outputDir" ]; then
        	echo "check: $outputDir should not exist (no differences)" >&2
        	testFail=1
    	fi

	# Print pass or fail then exit
	if [ "$testFail" -eq 0 ]; then
		echo "Testcase$n: PASS"
	else
		echo "Testcase$n: FAIL"
		exitCode=1
	fi
done

exit $exitCode
