#!/bin/bash
#
# Copyright 2020 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

/bin/rm -f bootstrap.log

(

secrets_env_file="./container/secrets/secrets.env"

if [ \! -f "${secrets_env_file}" ] ; then
  echo "Before running bootstrap.sh, you should run ./makesecrets to generate a secrets file."
  exit -1
fi

. ${secrets_env_file}

set -x

LOG_INFO() {
    echo "[bootstrap.sh INFO $(date +"%Y-%m-%d %T %Z")] $1"
}

if [ "${MAP_REPO}" != "" ] ; then
  git clone ${MAP_REPO} map
  # map repo needs a copy of antqiue repo under it.  There are definitely better ways to do this
  # (git submodule?), but for now we just clone it manually:
  (cd map ; git clone ${ANTIQUE_REPO} antique)
fi

git clone ${EDITOR_REPO} editor-website
mkdir editor-website/tmp editor-website/log
./fixperms
sudo ./dcwrapper up editor-db &
sleep 60 # wait a min to give editor-db time to spin up
sudo ./dcwrapper build oauth-proxy
sudo ./dcwrapper build editor
sudo ./dcwrapper run --entrypoint 'bash /container/config/editor/db-initialize' editor
sudo ./dcwrapper down


git clone ${MAPWARPER_REPO} mapwarper
mkdir mapwarper/tmp
(cd mapwarper ; bash ./lib/cloudbuild/copy_configs.sh)
./fixperms
sudo ./dcwrapper up mapwarper-db &
sleep 60 # wait a min to give mapwarper-db time to spin up
sudo ./dcwrapper build mapwarper
sudo ./dcwrapper run --entrypoint 'bash /container/config/mapwarper/db-initialize' mapwarper
sudo ./dcwrapper down

git clone ${CGIMAP_REPO} openstreetmap-cgimap
sudo ./dcwrapper build cgimap

git clone ${ID_REPO} iD
sudo ./dcwrapper build id

sudo ./dcwrapper build fe


if [ ! -d "./h3dmr" ]
then
    LOG_INFO "Cloning Reservoir (h3dmr) repository."
    git clone ${H3DMR_REPO} h3dmr
else
    LOG_INFO "Pulling latest Reservoir (h3dmr) repository."
    git -C ./h3dmr pull origin proxy
fi

# Hack to ensure all files in h3dmr sub-project are read/write-able by any user (including root).
./fixperms

LOG_INFO "Building Reservoir image."
sudo ./dcwrapper -f ./h3dmr/docker-compose.yml build h3dmr

if [ "${MAP_REPO}" != "" ] ; then
  sudo ./dcwrapper build map
fi

) 2>&1 | tee bootstrap.log
