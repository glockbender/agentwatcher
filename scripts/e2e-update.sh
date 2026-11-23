#!/bin/sh
exec "$(dirname "$0")/devtool" e2e-update "$@"
