#!/bin/sh
# Copy every DLL the given PE files import (recursively) from DLLDIR into DEST.
# usage: bundle-dlls.sh OBJDUMP DLLDIR DEST FILE...
set -eu
objdump=$1 dlldir=$2 dest=$3
shift 3

queue="$*"
while [ -n "$queue" ]; do
    next=""
    for f in $queue; do
        [ -f "$f" ] || continue
        for dll in $("$objdump" -p "$f" | sed -n 's/^[[:space:]]*DLL Name: //p' | tr -d '\r'); do
            [ -f "$dlldir/$dll" ] || continue
            [ -f "$dest/$dll" ] && continue
            cp "$dlldir/$dll" "$dest/"
            next="$next $dest/$dll"
        done
    done
    queue=$next
done
