/bin/bash /container/tools/subst \
  /container/secrets/secrets.env \
  /container/config/kartta/config.yml.in   /kartta/config.yml

if [ ! -d /kartta/build ] ; then
  mkdir /kartta/build
  chmod a+rwx /kartta/build
fi

cd /kartta
python ./build-all.py --watch &

cd /kartta/build
python3 -m http.server ${KARTTA_PORT}
