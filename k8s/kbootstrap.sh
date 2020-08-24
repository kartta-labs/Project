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

/bin/rm -f kbootstrap.log

(

# Set 'script_dir' to the full path of the directory containing this script
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# Load common functions
. ${script_dir}/functions.sh

# make sure the secrets file is present
secrets_env_file="./container/secrets/secrets.env"

# Uncomment this line to create a backup of secrets.env on every run (useful when editing/debugging this script):
#cp ${secrets_env_file} /tmp/secrets.env.$$

if [ \! -f "${secrets_env_file}" ] ; then
  echo "Before running kbootstrap.sh, you should run ./makesecrets to generate a secrets file,"
  echo "and edit it to set the required values for a k8s deployment."
  exit -1
fi

. ${secrets_env_file}

# set mapwarper rails env to "production" in secrets file
add_secret ${secrets_env_file} MAPWARPER_RAILS_ENV "production"
add_secret ${secrets_env_file} MAPWARPER_SECRET_KEY_BASE $(generate_secret_key)
add_secret ${secrets_env_file} ID_DEV ""
add_secret ${secrets_env_file} FORCE_HTTPS "true"

set -x

###
### general gcp setup
###
gcloud config set project ${GCP_PROJECT_ID}
gcloud config set compute/zone ${GCP_ZONE}
gcloud services enable cloudbuild.googleapis.com container.googleapis.com containerregistry.googleapis.com file.googleapis.com redis.googleapis.com servicenetworking.googleapis.com sql-component.googleapis.com sqladmin.googleapis.com storage-api.googleapis.com storage-component.googleapis.com vision.googleapis.com
gcloud container clusters create kartta-cluster1  --zone ${GCP_ZONE} --release-channel stable --enable-ip-alias --machine-type "n1-standard-4" --num-nodes=3
gcloud compute addresses create google-managed-services-default --global --purpose=VPC_PEERING --prefix-length=20 --network=default
gcloud services vpc-peerings connect --service=servicenetworking.googleapis.com --network=default --ranges=google-managed-services-default
cloudbuild_logs_bucket_suffix=$(generate_bucket_suffix)
add_secret ${secrets_env_file} CLOUDBUILD_LOGS_BUCKET "gs://cloudbuild-logs-${cloudbuild_logs_bucket_suffix}"
gsutil mb -p ${GCP_PROJECT_ID} ${CLOUDBUILD_LOGS_BUCKET}
PROJECT_NUMBER=`gcloud projects list "--filter=${GCP_PROJECT_ID}" "--format=value(PROJECT_NUMBER)"`
gsutil iam ch serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com:objectAdmin,objectCreator,objectViewer,legacyBucketWriter ${CLOUDBUILD_LOGS_BUCKET}

#TODO: determine whether mapwarper really uses this service account, and if not, get rid of it
gcloud iam service-accounts create mapwarper-sa --display-name 'mapwarper access for storage and cloud sql'
gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} --member=serviceAccount:mapwarper-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com --role=roles/cloudsql.admin
gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} --member=serviceAccount:mapwarper-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com --role=roles/cloudsql.client
gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} --member=serviceAccount:mapwarper-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com --role=roles/cloudsql.editor
gcloud iam service-accounts keys create /tmp/mapwarper-service-account.json --iam-account mapwarper-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com

set +x
add_secret_from_file ${secrets_env_file} MAPWARPER_SA_KEY_JSON /tmp/mapwarper-service-account.json
rm -f /tmp/mapwarper-service-account.json
set -x

###
### mapwarper storage buckets
###
set +x
BUCKET_SUFFIX=$(generate_bucket_suffix)
add_secret ${secrets_env_file} MAPWARPER_WARPER_BUCKET "warper-${BUCKET_SUFFIX}"
add_secret ${secrets_env_file} MAPWARPER_TILES_BUCKET "tiles-${BUCKET_SUFFIX}"
set -x
gsutil mb -p ${GCP_PROJECT_ID} gs://${MAPWARPER_WARPER_BUCKET}
gsutil mb -p ${GCP_PROJECT_ID} gs://${MAPWARPER_TILES_BUCKET}

#  give service account "mapwarper-sa" access to those buckets
gsutil iam ch serviceAccount:mapwarper-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com:objectAdmin,objectCreator,objectViewer gs://${MAPWARPER_WARPER_BUCKET}
gsutil iam ch serviceAccount:mapwarper-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com:objectAdmin,objectCreator,objectViewer gs://${MAPWARPER_TILES_BUCKET}

# create tiles-backend-bucket
gcloud compute backend-buckets create tiles-backend-bucket --enable-cdn --gcs-bucket-name=${MAPWARPER_TILES_BUCKET}

# set up url maps and public ip for tiles-backend-bucket
gcloud compute url-maps create mapwarper-tiles-url-map --default-backend-bucket=tiles-backend-bucket
gcloud compute url-maps add-path-matcher mapwarper-tiles-url-map --default-backend-bucket tiles-backend-bucket --path-matcher-name mapwarper-tiles-bucket-matcher '--backend-bucket-path-rules=/*=tiles-backend-bucket'
gcloud compute target-http-proxies create http-tiles-lb-proxy --url-map mapwarper-tiles-url-map
gcloud compute addresses create mapwarper-tiles-ip --global
gcloud compute forwarding-rules create tiles-http-forwarding-rule --address=mapwarper-tiles-ip --global --target-http-proxy http-tiles-lb-proxy --ports=80


###
### mapwarper managed NAS file storage
###
gcloud filestore instances create mapwarper-fs --project=${GCP_PROJECT_ID} --zone=${GCP_ZONE} --tier=STANDARD --file-share=name=mapfileshare,capacity=1TB --network=name=default
set +x
add_secret ${secrets_env_file} MAPWARPER_NFS_SERVER "`gcloud filestore instances describe mapwarper-fs --zone=us-east4-a --format="value(networks[0].ipAddresses[0])"`"
set -x
# create PersistentVolume (nfs mount) called mapwarper-fileserver
${script_dir}/kapply k8s/mapwarper-filestore-storage.yaml.in


###
### create services
###
${script_dir}/kcreate k8s/cgimap-service.yaml.in
${script_dir}/kcreate k8s/editor-service.yaml.in
${script_dir}/kcreate k8s/fe-service.yaml.in
${script_dir}/kcreate k8s/mapwarper-service.yaml.in
${script_dir}/kcreate k8s/oauth-proxy-service.yaml.in
${script_dir}/kcreate k8s/h3dmr-service.yaml.in

###
### clone code repos
###
git clone ${EDITOR_REPO} editor-website
git clone ${MAPWARPER_REPO} mapwarper
git clone ${CGIMAP_REPO} openstreetmap-cgimap
git clone ${RESERVOIR_REPO} reservoir


###
### build & tag latest images
###


# oauth-proxy
export OAUTH_PROXY_SHORT_SHA=`cat Dockerfile-oauth-proxy container/config/oauth-proxy/* | md5sum  | sed -e 's/\(.\{7\}\).*/\1/'`
gcloud builds submit "--gcs-log-dir=${CLOUDBUILD_LOGS_BUCKET}/oauth_proxy" "--substitutions=SHORT_SHA=${OAUTH_PROXY_SHORT_SHA}"  --config k8s/cloudbuild-oauth-proxy.yaml .
gcloud container images add-tag --quiet "gcr.io/${GCP_PROJECT_ID}/oauth-proxy:${OAUTH_PROXY_SHORT_SHA}" "gcr.io/${GCP_PROJECT_ID}/oauth-proxy:latest"

# fe
export FE_SHORT_SHA=`cat Dockerfile-fe container/config/fe/* | md5sum  | sed -e 's/\(.\{7\}\).*/\1/'`
gcloud builds submit "--gcs-log-dir=${CLOUDBUILD_LOGS_BUCKET}/fe" "--substitutions=SHORT_SHA=${FE_SHORT_SHA}"  --config k8s/cloudbuild-fe.yaml .
gcloud container images add-tag --quiet "gcr.io/${GCP_PROJECT_ID}/fe:${FE_SHORT_SHA}" "gcr.io/${GCP_PROJECT_ID}/fe:latest"

# editor
export EDITOR_SHORT_SHA=`(cd editor-website ; git rev-parse --short HEAD)`
gcloud builds submit "--gcs-log-dir=${CLOUDBUILD_LOGS_BUCKET}/editor" "--substitutions=SHORT_SHA=${EDITOR_SHORT_SHA}"  --config k8s/cloudbuild-editor.yaml .
gcloud container images add-tag --quiet "gcr.io/${GCP_PROJECT_ID}/editor:${EDITOR_SHORT_SHA}" "gcr.io/${GCP_PROJECT_ID}/editor:latest"

# cgimap
export CGIMAP_SHORT_SHA=`(cd openstreetmap-cgimap ; git rev-parse --short HEAD)`
gcloud builds submit "--gcs-log-dir=${CLOUDBUILD_LOGS_BUCKET}/cgimap" "--substitutions=SHORT_SHA=${CGIMAP_SHORT_SHA}"  --config k8s/cloudbuild-cgimap.yaml .
gcloud container images add-tag --quiet "gcr.io/${GCP_PROJECT_ID}/cgimap:${CGIMAP_SHORT_SHA}" "gcr.io/${GCP_PROJECT_ID}/cgimap:latest"

# mapwarper
export MAPWARPER_SHORT_SHA=`(cd mapwarper ; git rev-parse --short HEAD)`
gcloud builds submit "--gcs-log-dir=${CLOUDBUILD_LOGS_BUCKET}/mapwarper" "--substitutions=SHORT_SHA=${MAPWARPER_SHORT_SHA}"  --config k8s/cloudbuild-mapwarper.yaml .
gcloud container images add-tag --quiet "gcr.io/${GCP_PROJECT_ID}/mapwarper:${MAPWARPER_SHORT_SHA}" "gcr.io/${GCP_PROJECT_ID}/mapwarper:latest"

# Reservoir
export RESERVOIR_SHORT_SHA=`(cd reservoir ; git rev-parse --short HEAD)`
gcloud builds submit "--gcs-log-dir=${CLOUDBUILD_LOGS_BUCKET}/reservoir" "--substitutions=SHORT_SHA=${RESERVOIR_SHORT_SHA}" --config k8s/cloudbuild-mapwarper.yaml ./reservoir
gcloud container images add-tag --quiet "gcr.io/${GCP_PROJECT_ID}/reservoir:${RESERVOIR_SHORT_SHA}" "gcr.io/${GCP_PROJECT_ID}/reservoir:latest"



###
### editor database
###

# create the sql instance
#   Note we set temp_file_limit=2147483647, which is the max allowd value per
#   https://cloud.google.com/sql/docs/postgres/flags#gcloud, because a large limit is needed to support generating data
#   exports with osmosis.
gcloud beta sql instances create editor-sql --cpu=1 --memory=3840MiB --database-version=POSTGRES_11 --zone=${GCP_ZONE} --storage-type=SSD --network=default --database-flags temp_file_limit=2147483647 --no-assign-ip

set +x
echo "generating passwords and storing secrets..."
# store sql instance ip in secrets
add_secret ${secrets_env_file} EDITOR_DB_HOST `gcloud beta sql instances describe editor-sql --format="value(ipAddresses.ipAddress)"`
# generate passwords and store in secrets
add_secret ${secrets_env_file} EDITOR_DB_USER karttaweb
add_secret ${secrets_env_file} EDITOR_SQL_POSTGRES_PASSWORD $(generate_password)
add_secret ${secrets_env_file} EDITOR_SQL_KARTTAWEB_PASSWORD $(generate_password)
set -x

# set the generated passwords
gcloud beta sql users set-password postgres --instance=editor-sql "--password=${EDITOR_SQL_POSTGRES_PASSWORD}"
gcloud beta sql users create karttaweb --instance=editor-sql "--password=${EDITOR_SQL_KARTTAWEB_PASSWORD}"

# perform database migration; note this uses the gcr.io editor image built above to run a job
${script_dir}/resecret
${script_dir}/kcreate k8s/editor-db-migration-job.yaml.in
set +x
wait_for_k8s_job editor-db-migration
set -x
# Don't delete this job for now, to make it possible to view its logs.
#kubectl delete job editor-db-migration






###
### mapwarper database
###

#  create sql instance, store ip, generate and store password
gcloud beta sql instances create mapwarper-sql --cpu=1 --memory=3840MiB --database-version=POSTGRES_9_6 --zone=${GCP_ZONE} --storage-type=SSD --network=default --no-assign-ip
set +x
echo "generating passwords and storing secrets..."
add_secret ${secrets_env_file} MAPWARPER_DB_HOST `gcloud beta sql instances describe mapwarper-sql --format="value(ipAddresses.ipAddress)"`
add_secret ${secrets_env_file} MAPWARPER_POSTGRES_PASSWORD $(generate_password)
set -x

# set the generated password
gcloud sql users set-password postgres --instance=mapwarper-sql "--password=${MAPWARPER_POSTGRES_PASSWORD}"

# create mapwarper_production database
gcloud sql databases create mapwarper_production --instance=mapwarper-sql


# perform database migration; note this uses the gcr.io mapwarper image built above to run a job
${script_dir}/resecret
${script_dir}/kcreate k8s/mapwarper-db-migration-job.yaml.in
set +x
wait_for_k8s_job mapwarper-db-migration
set -x
# Don't delete this job for now, to make it possible to view its logs.
#kubectl delete job mapwarper-db-migration

 

###
### mapwarper redis instance
###
gcloud beta redis instances create mapwarper-redis --size=2 --region=${GCP_REGION} --zone=${GCP_ZONE} --redis-version=redis_4_0 --redis-config maxmemory-policy=allkeys-lru
set +x
add_secret ${secrets_env_file} MAPWARPER_REDIS_HOST "`gcloud redis instances describe mapwarper-redis --region=${GCP_REGION} --format="value(host)"`"
add_secret ${secrets_env_file} MAPWARPER_REDIS_URL "redis://${MAPWARPER_REDIS_HOST}:6379/0/cache"
set -x


###
### mapwarper file storage initialization
###
${script_dir}/resecret
${script_dir}/kcreate k8s/mapwarper-fs-initialization-job.yaml.in
set +x
wait_for_k8s_job mapwarper-fs-initialization
set -x
# Don't delete this job for now, to make it possible to view its logs.
#kubectl delete job mapwarper-fs-initialization


###
### deploy applications
###
${script_dir}/resecret
${script_dir}/kcreate k8s/cgimap-deployment.yaml.in
${script_dir}/kcreate k8s/editor-deployment.yaml.in
${script_dir}/kcreate k8s/fe-deployment.yaml.in
${script_dir}/kcreate k8s/oauth-proxy-deployment.yaml.in
${script_dir}/kcreate k8s/mapwarper-deployment.yaml.in


###
### create ssl cert and https ingress
###
${script_dir}/kcreate k8s/managed-certificate.yaml.in
${script_dir}/kcreate k8s/backend-config.yaml.in
${script_dir}/kcreate k8s/nodeport-service.yaml.in
${script_dir}/kcreate k8s/ingress.yaml.in
set +x
wait_for_ingress_ip "kartta-ingress"
add_secret ${secrets_env_file} INGRESS_IP ${INGRESS_IP}
echo "got INGRESS_IP=${INGRESS_IP}"
set -x


set +x
echo ""
echo "########################################################################################"
echo ""
echo "Everything is launched.  Excellent!"
echo ""
echo "Run"
echo "    kubectl get pods"
echo "to see the list of running pods.  It might take a few minutes for all pods to"
echo "become ready."
echo ""
echo "You should now create a public DNS entry to associate the name ${SERVER_NAME}"
echo "with the ip address ${INGRESS_IP}."
echo ""
echo "After creating the public DNS entry, run the command"
echo "    kubectl describe managedcertificate"
echo "every few minutes until the domain status says 'Active'. It might take 15-30"
echo "minutes or so.  If the domain status says 'FailedNotVisible', it means the"
echo "the DNS name isn't recognized yet.  If that happens, double-check that you"
echo "correctly created the DNS entry, and wait a few more minutes and check again."
echo "GKE will repeatedly try to provision the certificate every few minutes."
echo ""
echo "Once the certificate is provisioned, you can access the site at"
echo "    https://${SERVER_NAME}"
echo ""
echo "It's normal to get 'Error: Server Error' 502 errors for the first few minutes"
echo "after the certificate is provisioned.  If that happens, wait a few minutes and"
echo "reload the page."
echo ""

) 2>&1 | tee kbootstrap.log
