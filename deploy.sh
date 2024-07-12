#!/bin/bash
set -e -u -o pipefail

rsync -avP --exclude=data --exclude='*.xml' "$(pwd)" zaudera2:src/
