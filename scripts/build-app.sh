#!/bin/sh
exec "$(dirname "$0")/devtool" build-app "$@"
