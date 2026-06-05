#!/bin/sh
# NDM filesystem hook — executed when /opt is mounted on Keenetic OS5.
# Place at /opt/etc/ndm/fs.d/100-vpnd.sh and chmod +x
[ -x /opt/etc/init.d/S99vpnd ] && /opt/etc/init.d/S99vpnd start
