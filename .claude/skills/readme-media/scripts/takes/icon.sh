#!/bin/sh
exec "${AW_DEVTOOL:-$(dirname -- "$0")/../../../../../scripts/devtool}" media take icon "$@"
