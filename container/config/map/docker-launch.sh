/bin/bash /container/tools/subst \
  /container/secrets/secrets.env \
  /container/config/map/config.yml.in   /map/config.yml

if [ ! -d /map/build ] ; then
  mkdir /map/build
  chmod a+rwx /map/build
fi

cd /map
python ./build-all.py --watch &

cd /map/build
python3 -m http.server ${MAP_PORT}
