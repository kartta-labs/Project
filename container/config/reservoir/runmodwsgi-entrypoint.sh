#!/bin/bash

echo "foo"

. /reservoir/container/secrets/secrets.env

function log {
    echo "[runmodwsgi entrypoint $(date)]: $1"
}

log "Changing permissions on fs mount."

log "RESERVOIR_DEBUG: ${RESERVOIR_DEBUG}"

chown -R :www-data /reservoir/models
chmod -R a+wr /reservoir/models

log "Checking permissions for /reservoir/models: $(ls -laF /reservoir/models)"

log "Starting runmodwsgi process."

cd /reservoir
python manage.py runmodwsgi --port 80 --user=www-data --group=www-data \
       --server-root=/etc/mod_wsgi-express-80 --error-log-format "%M" --log-to-terminal
