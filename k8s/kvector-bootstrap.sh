#! /bin/bash
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

# Script to bootstrap vector tile service in its own cluster (separate cluster from the
# maps applications bootstrapped by kbootstrap.sh)

/bin/rm -f kvector-bootstrap.log

(

# Set 'script_dir' to the full path of the directory containing this script
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# Load common functions
. ${script_dir}/functions.sh

# make sure the secrets file is present
secrets_env_file="./container/secrets/secrets.env"

# temporarily back up the secrets file on every run
cp ${secrets_env_file} /tmp/secrets.env.$$

if [ \! -f "${secrets_env_file}" ] ; then
  echo "Before running kbootstrap.sh, you should run ./makesecrets to generate a secrets file,"
  echo "and edit it to set the required values for a k8s deployment."
  echo "You must also run kboostrap.sh before running kvector-bootstrap.sh."
  exit -1
fi

. ${secrets_env_file}

set -x

###
### general gcp setup
###
gcloud config set project ${GCP_PROJECT_ID}
gcloud config set compute/zone ${GCP_ZONE}
gcloud services enable container.googleapis.com containerregistry.googleapis.com cloudbuild.googleapis.com sql-component.googleapis.com sqladmin.googleapis.com redis.googleapis.com servicenetworking.googleapis.com


##xxx  # commands for getting/setting the k8s context (cluster?):
##xxx  # list all contexts (across all gcp projects you have access to):
##xxx  #    k config get-contexts
##xxx  # show which one is current:
##xxx  #    k config current-context
##xxx  # set the current one:
##xxx  #    k config use-context CONTEXT
##xxx  
##xxx  
###
### create cluster
###
gcloud container clusters create "tegola-${GCP_ZONE}" --zone ${GCP_ZONE} --release-channel stable --enable-ip-alias --machine-type "n1-standard-4" --num-nodes=3
#???  $ gcloud container clusters get-credentials tegola-${GCP_ZONE}




###  If the google-managed-services-default resource hasn't been created yet, create it.
###  kbootstrap.sh creates it, so if you've already run kbootstrap.sh, it should exist.
###
set +x
if [ "$(gcloud compute addresses describe google-managed-services-default --global '--format=value(name)' 2>/dev/null)" \
  == "" ] ; then
  set -x
  gcloud compute addresses create google-managed-services-default --global --purpose=VPC_PEERING --prefix-length=20 --network=default
  gcloud services vpc-peerings connect --service=servicenetworking.googleapis.com --network=default --ranges=google-managed-services-default
  set +x
else
  echo "using existing google-managed-services-default network"
fi
set -x

###
### create & configure sql instance
###
gcloud beta sql instances create tegola-sql --cpu=6 --memory=32GiB --database-version=POSTGRES_11 --zone=us-east4-a --storage-type=SSD --network=default --no-assign-ip
set +x
add_secret ${secrets_env_file} TEGOLA_DB_HOST `gcloud beta sql instances describe tegola-sql --format="value(ipAddresses.ipAddress)"`
add_secret ${secrets_env_file} TEGOLA_POSTGRES_PASSWORD $(generate_password)
add_secret ${secrets_env_file} TEGOLA_TEGOLA_PASSWORD $(generate_password)
set -x
gcloud sql users set-password postgres --instance=tegola-sql "--password=${TEGOLA_POSTGRES_PASSWORD}"
gcloud sql users set-password tegola --instance=tegola-sql "--password=${TEGOLA_TEGOLA_PASSWORD}"
gcloud sql databases create antique --instance=tegola-sql


###
### create redis instance
###
gcloud beta redis instances create tegola-redis --size=3 --region=${GCP_REGION} --zone=${GCP_ZONE} --redis-version=redis_4_0 --redis-config maxmemory-policy=allkeys-lru
set +x
add_secret ${secrets_env_file} TEGOLA_REDIS_HOST "`gcloud redis instances describe tegola-redis --region=${GCP_REGION} --format="value(host)"`"
add_secret ${secrets_env_file} TEGOLA_REDIS_ADDRESS "${TEGOLA_REDIS_HOST}:6379"
set -x

###
### clone code repos
###
git clone ${ANTIQUE_REPO} antique_vector
git clone ${TEGOLA_REPO} tegola


###
### build tegola image
###
export TEGOLA_SHORT_SHA=`(cd tegola ; git rev-parse --short HEAD)`
(cd tegola; gcloud builds submit  "--gcs-log-dir=${CLOUDBUILD_LOGS_BUCKET}/tegola" "--substitutions=SHORT_SHA=${TEGOLA_SHORT_SHA}"  --config cloudbuild.yaml .)
gcloud container images add-tag --quiet "gcr.io/${GCP_PROJECT_ID}/tegola-cb:${TEGOLA_SHORT_SHA}" "gcr.io/${GCP_PROJECT_ID}/tegola-cb:latest"

###
### build pgutil image (used for initializing database and doing database imports)
###
export PGUTIL_SHORT_SHA=`cat Dockerfile-pgutil | md5sum  | sed -e 's/\(.\{7\}\).*/\1/'`
gcloud builds submit  "--gcs-log-dir=${CLOUDBUILD_LOGS_BUCKET}/pgutil" "--substitutions=SHORT_SHA=${PGUTIL_SHORT_SHA}"  --config k8s/cloudbuild-pgutil.yaml .
gcloud container images add-tag --quiet "gcr.io/${GCP_PROJECT_ID}/pgutil:${PGUTIL_SHORT_SHA}" "gcr.io/${GCP_PROJECT_ID}/pgutil:latest"


###
### spin up a pgutil pod which will be used to initialize the database
###

${script_dir}/resecret
${script_dir}/kcreate ./k8s/pgutil-deployment.yaml.in
set +x
wait_for_k8s_deployment_app_ready pgutil
pgutil_pod_name=$(kubectl get pods --selector=app=pgutil --field-selector status.phase=Running  -o=jsonpath='{.items[0].metadata.name}')
echo "${pgutil_pod_name} is ready; using it to initialize database"


###
### download natural earth data and transfer it to the pgutil pod
###
if [ -f "natural_earth_vector.sqlite.zip" ] ; then
  /bin/rm -f "natural_earth_vector.sqlite.zip"
fi
echo "downloading http://naciscdn.org/naturalearth/packages/natural_earth_vector.sqlite.zip"
wget -O natural_earth_vector.sqlite.zip http://naciscdn.org/naturalearth/packages/natural_earth_vector.sqlite.zip
mkdir natural_earth_vector.$$
cd natural_earth_vector.$$
unzip ../natural_earth_vector.sqlite.zip
cd ..

echo "building git@github.com:historic-map-stack/natural_earth_edits tarball"
if [ -d "natural_earth_edits" ] ; then
  /bin/rm -rf natural_earth_edits
fi
git clone git@github.com:historic-map-stack/natural_earth_edits
/bin/rm -rf natural_earth_edits/.git
tar cfz natural_earth_edits.tgz natural_earth_edits
/bin/rm -rf natural_earth_edits
set -x

kubectl cp natural_earth_vector.$$/packages/natural_earth_vector.sqlite ${pgutil_pod_name}:/tmp
kubectl cp natural_earth_edits.tgz ${pgutil_pod_name}:/tmp
/bin/rm -f natural_earth_edits.tgz
/bin/rm -f natural_earth_vector.$$
/bin/rm -f natural_earth_vector.sqlite.zip

###
### initialize the database with natural_earth data
###
kubectl exec -it ${pgutil_pod_name} bash /container/config/tegola/db-initialize

###
### TODO: figure out how to handle migrating data from the editor database
###       to the tegola database.  It's not clear that it should always happen
###       when kvector-bootstrap.sh is run (in particular, editor database might
###       not yet have been populated at tat time).  Maybe have
###       kvector-bootstrap.sh write a script that the user can run later to do it?
###
###       Here is the script I ran to do it for vectortiles.canary...
###       I ran this script on the pguitl pod created above:
###           -------------------------------------------------------------------------------
###           #! /bin/bash
###           
###           . /container/secrets/secrets.env
###           
###           osmosis \
###             --read-apidb \
###               host="${EDITOR_DB_HOST}" \
###               database="editor_production" \
###               user="karttaweb" \
###               password="${EDITOR_SQL_KARTTAWEB_PASSWORD}" \
###               validateSchemaVersion=no \
###               --write-xml \
###               file="export.osm"
###           
###           
###           # echo psql -h ${TEGOLA_DB_HOST} -U tegola -d antique
###           
###           #export PGPASS=${TEGOLA_TEGOLA_PASSWORD}
###           
###           echo "enter password ${TEGOLA_TEGOLA_PASSWORD} when prompted below"
###           
###           # TODO; figure out how to feed the password to osm2pgsql without requiring the
###           #   user to enter it in the terminal.  The --help says you can set PGPASS
###           #   environemn variable, but it doesn't seem to work.
###           
###           osm2pgsql \
###             --hstore \
###             -S osm2pgsql.style \
###             --slim \
###             -C 5000 \
###             -d antique \
###             -W \
###             -U tegola \
###             -H ${TEGOLA_DB_HOST} \
###             export.osm
###           -------------------------------------------------------------------------------
###
###       Note the above scrpt leaves a big 'export.osm' file on the pod's
###       filesystem.  I think it's also possible to do the above without
###       writing the file to disk by piping the output of osmosis to the input
###       of osm2pgql.  On the other hand, since the pod's filesystem is
###       empheral and will disappear when the pod is stopped, there's no real
###       harm to creating the large export.osm file (unless it turns out
###       there's not enough space, but that wasn't an issue when I ran it.)
###


###
### deploy the app
###
${script_dir}/resecret
${script_dir}/kcreate ./k8s/tegola-deployment.yaml.in


###
### create public address and https cert
###
gcloud compute addresses create tegola-static-ip --project=${GCP_PROJECT_ID} --global
${script_dir}/resecret
${script_dir}/kapply ./k8s/tegola-certificate.yaml.in

###
### create ingress
###
${script_dir}/resecret
${script_dir}/kcreate ./k8s/tegola-https-ingress.yaml.in

set +x
add_secret ${secrets_env_file} TEGOLA_SERVER_IP "$(gcloud compute addresses describe tegola-static-ip --project=${GCP_PROJECT_ID} --global --format="value(address)")"
echo ""
echo "Vector tile server is now deployed."
echo ""
echo "You should create DNS entry to associate the name ${TEGOLA_SERVER_NAME} with ip address ${TEGOLA_SERVER_IP} at this point"
echo ""

) 2>&1 | tee kvector-bootstrap.log
