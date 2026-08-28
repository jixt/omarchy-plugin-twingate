#!/usr/bin/env bash
set -euo pipefail

source_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$source_root"

for command_name in qmllint omarchy; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "test.sh: missing test command: $command_name" >&2
    exit 1
  }
done

qml_test_runner=/usr/lib/qt6/bin/qmltestrunner
[[ -x $qml_test_runner ]] || {
  echo "test.sh: Qt 6 qmltestrunner is missing: $qml_test_runner" >&2
  exit 1
}

omarchy plugin validate .
qmllint -I /usr/share/omarchy/shell BarWidget.qml Panel.qml TwingateGlyph.qml Parsing.js \
  ResourceRow.qml KubeResourceRow.qml ResourceListView.qml

QT_QPA_PLATFORM=offscreen "$qml_test_runner" \
  -input tests \
  -import "$source_root" \
  -o -,txt

echo "All validation and tests passed."
