#!/bin/sh
set -eu

ssh macmini '
sw_vers
uname -m
printf "\n== printers ==\n"
lpstat -p || true
printf "\n== device uris ==\n"
lpstat -v || true
'
