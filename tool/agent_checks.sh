#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

dart format lib test
dart analyze lib test/widget_test.dart

if [[ $# -gt 0 ]]; then
  flutter test test/widget_test.dart --name "$1"
else
  flutter test test/widget_test.dart
fi
