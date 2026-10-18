#!/bin/bash

# Generate all icon enums properly from the lucide-icons directory
odin run generate.odin -file

# Main app now has access to Lucide_Icons :: enum { ... }
odin build .
