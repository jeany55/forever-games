#!/bin/bash
# Runs one of the bench's Python scripts with a Python that has numpy and Pillow: this one's own
# if it has them, else one installed on Windows (whose paths it is given the Windows way).
#   ./python.sh stitch.py [arguments]
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$1"
shift

if python3 -c "import numpy, PIL" 2>/dev/null; then
  exec python3 "$HERE/$SCRIPT" "$@"
fi
for candidate in /mnt/c/Users/*/AppData/Local/Programs/Python/Python3*/python.exe; do
  if [ -x "$candidate" ] && "$candidate" -c "import numpy, PIL" >/dev/null 2>&1; then
    exec "$candidate" "$(wslpath -w "$HERE/$SCRIPT")" "$@"
  fi
done
echo "No Python with numpy and Pillow: pip install numpy pillow" >&2
exit 1
