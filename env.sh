#!/bin/sh

rel_path=$(dirname $0)
export PATH="$(cd $rel_path; pwd)/vendor/Nim/bin:$PATH"
exec "$@"
