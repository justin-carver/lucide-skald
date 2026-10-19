#!/bin/bash

# NOTE: Update the $test_suites variable with more packages that require checks
# in the future.

# Will add more to these later if this grows...
# just wanted to avoid typing these out manually each time
test_suites=("parser" "icon")

ACTION="$1"

if [ "$ACTION" = "test" ]; then
  echo "Starting test runner..."

  for suite in "${test_suites[@]}"; do
    echo "Running test suite: $suite"

    odin test "$suite" -all-packages

    if [ $? -ne 0 ]; then
      echo "Error: Test suite '$suite' failed!"
      exit 1
    fi
  done

  echo "All test suites passed successfully."
  exit 0
else
  # Generate all icon enums properly from the lucide-icons directory
  odin run src/generate.odin -file

  # Main app now has access to Lucide_Icons :: enum { ... }
  odin build src/

  exit 1
fi
