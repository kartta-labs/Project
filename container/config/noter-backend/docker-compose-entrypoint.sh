#!/bin/bash

until psql $DATABASE_URL -c '\l'; do
    >&2 echo "Posgres is unavailable - sleeping."
done

psql $DATABASE_URL -c "create database ${NOTER_DB_NAME}"

python3 /noter-backend/noter_backend/manage.py makemigrations
python3 /noter-backend/noter_backend/manage.py migrate
python3 /noter-backend/noter_backend/manage.py shell -c "from django.contrib.auth.models import User; User.objects.create_superuser('admin', 'admin@example.com', 'dontusethispassword')"
python3 /noter-backend/noter_backend/manage.py shell < /noter-backend/late_migrate.py

# /usr/local/bin/supervisord
# uwsgi /noter-backend/etc/uwsgi.ini

if [[ -z "${NOTER_GS_MEDIA_BUCKET_NAME}" ]]; then
  export PROTECTED_MEDIA_URL="alias /media/;"
else
  export PROTECTED_MEDIA_URL="proxy_pass https://${NOTER_GS_MEDIA_BUCKET_NAME}.storage.googleapis.com/;"
fi
envsubst "\$PROTECTED_MEDIA_URL" < /etc/nginx/sites-available/noter.conf.template > /etc/nginx/sites-available/noter.conf
ln -s /etc/nginx/sites-available/noter.conf /etc/nginx/sites-enabled/noter.conf

service nginx start && python3 /noter-backend/noter_backend/manage.py runserver 127.0.0.1:3000
