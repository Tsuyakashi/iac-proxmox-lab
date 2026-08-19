#!/bin/bash

set -e

apt-get update && apt-get install -y nfs-kernel-server

mkdir -p /srv/shared-storage

chown nobody:nogroup /srv/shared-storage

grep -q "^/srv/shared-storage" /etc/exports 2>/dev/null || \
  echo "/srv/shared-storage 192.168.100.0/24(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports


# pvesm add nfs shared-storage \
#   --server 192.168.100.30 \
#   --export /srv/shared-storage \
#   --content iso,vztmpl,backup,snippets,images

# connect with ^