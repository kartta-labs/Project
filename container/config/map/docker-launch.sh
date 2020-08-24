/bin/bash /container/tools/subst \
  /container/secrets/secrets.env \
  /container/config/map/config.env.in   /map/config.env

if [ ! -d /map/build ] ; then
  mkdir /map/build
fi

cd /map
python ./build-all.py --watch &

cd /map/build
python -m SimpleHTTPServer ${MAP_PORT}
