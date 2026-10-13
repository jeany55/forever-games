#!/bin/bash
# Runs the engine tests. Run from the repository root.
set -e
lua Tests/RunTests.lua "$@"
