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

if [ "${ENABLE_KARTTA}" != "" ] ; then
  git clone ${KARTTA_REPO} kartta
  # kartta repo needs a copy of antqiue repo under it.  There are definitely better ways to do this
  # (git submodule?), but for now we just clone it manually:
  (cd kartta ; git clone ${ANTIQUE_REPO} antique)
  sudo ./dcwrapper -f docker-compose-kartta.yml build kartta
fi

git clone ${EDITOR_REPO} editor-website
mkdir editor-website/tmp editor-website/log
./fixperms
sudo ./dcwrapper up editor-db &
sleep 60 # wait a min to give editor-db time to spin up
sudo ./dcwrapper build oauth-proxy
sudo ./dcwrapper build editor
sudo ./dcwrapper run --entrypoint '/bin/sh /container/config/editor/db-initialize' editor
sudo ./dcwrapper down


git clone ${MAPWARPER_REPO} warper
mkdir warper/tmp
(cd warper ; bash ./lib/cloudbuild/copy_configs.sh)
./fixperms
sudo ./dcwrapper up warper-db &
sleep 60 # wait a min to give warper-db time to spin up
sudo ./dcwrapper build warper
sudo ./dcwrapper run --entrypoint '/bin/sh /container/config/warper/db-initialize' warper
sudo ./dcwrapper down

git clone ${CGIMAP_REPO} openstreetmap-cgimap
sudo ./dcwrapper build cgimap

if [ "${ENABLE_FE_ID}" != "" ] ; then
  git clone ${ID_REPO} iD
  sudo ./dcwrapper -f docker-compose-id.yml build id
fi

sudo ./dcwrapper build fe

if [ "${ENABLE_RESERVOIR}" != "" ] ; then
  if [ ! -d "./reservoir" ] ; then
    LOG_INFO "Cloning Reservoir repository."
    git clone ${RESERVOIR_REPO} reservoir
  else
    LOG_INFO "Pulling latest Reservoir repository."
    git -C ./reservoir pull origin master
  fi

  # Hack to ensure all files in Reservoir sub-project are read/write-able by any user (including root).
  ./fixperms

  LOG_INFO "Building Reservoir image."
  sudo ./dcwrapper -f ./reservoir/docker-compose.yml build reservoir
fi

if [ "${ENABLE_NOTER}" != "" ] ; then
  git clone ${NOTER_BACKEND_REPO} noter-backend
  git clone ${NOTER_FRONTEND_REPO} noter-frontend
  sudo ./dcwrapper build noter-backend
  sudo ./dcwrapper build noter-frontend
fi


) 2>&1 | tee bootstrap.log
