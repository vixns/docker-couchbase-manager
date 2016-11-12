#!/bin/sh

IFS=$'
'
[ -n "${NS}" ] || NS=""
[ -n "${1}" ] || exit 1

dn="${1}"
for entry in $(dig $NS +short srv $dn | grep ${SRV_PORT:-8091} | awk '{print $NF}')
do
  dig $NS srv +noanswer $dn | grep "$entry" | awk '{print $NF}'
done