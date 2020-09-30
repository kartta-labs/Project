#!/bin/bash

echo "foo"

. /container/secrets/secrets.env

function log {
    echo "[runmodwsgi entrypoint $(date)]: $1"
}

log "Changing permissions on fs mount."

log "RESERVOIR_DEBUG: ${RESERVOIR_DEBUG}"

log "RESERVOIR_SITE_PREFIX: ${RESERVOIR_SITE_PREFIX}"

log "RESERVOIR_STATIC_URL: ${RESERVOIR_STATIC_URL}"

log "RESERVOIR_MODEL_DIR: ${RESERVOIR_MODEL_DIR}"

log "RESERVOIR_DB_HOST: $RESERVOIR_DB_HOST"

log "RESERVOIR_DB_PORT: $RESERVOIR_DB_PORT"

chown -R :www-data /reservoir/models
chmod -R a+wr /reservoir/models

log "Checking permissions for /reservoir/models: $(ls -laF /reservoir/models)"

CONNECTION_URL="postgresql://${RESERVOIR_DB_USER}:${RESERVOIR_DB_PASSWORD}@${RESERVOIR_DB_HOST}:${RESERVOIR_DB_PORT}/${RESERVOIR_DB_NAME}"

until psql ${CONNECTION_URL} -c '\l'; do
  >&2 echo "Waiting for postgres, sleeping."
  sleep 10s
done

log "Starting runmodwsgi process."

cd /reservoir

log "Running migrations."
python manage.py makemigrations
python manage.py migrate
log "Migrations complete."

python manage.py runmodwsgi --port 80 --user=www-data --group=www-data \
       --server-root=/etc/mod_wsgi-express-80 --error-log-format "%M" --log-to-terminal
