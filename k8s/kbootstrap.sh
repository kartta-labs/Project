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

###xx # k8s-specific secrets settings which override the defaults:
###xx add_secret ${secrets_env_file} MAPWARPER_RAILS_ENV "production"
###xx add_secret ${secrets_env_file} MAPWARPER_GOOGLE_STORAGE_ENABLED "true"
###xx add_secret ${secrets_env_file} MAPWARPER_SECRET_KEY_BASE $(generate_secret_key)
###xx add_secret ${secrets_env_file} FORCE_HTTPS "true"
###xx add_secret ${secrets_env_file} KLUSTER "${GCP_PROJECT_ID}-k1"
###xx 
###xx set -x
###xx 
###xx ###
###xx ### general gcp setup
###xx ###
###xx gcloud config set project ${GCP_PROJECT_ID}
###xx gcloud config set compute/zone ${GCP_ZONE}
###xx gcloud services enable cloudbuild.googleapis.com container.googleapis.com containerregistry.googleapis.com file.googleapis.com redis.googleapis.com servicenetworking.googleapis.com sql-component.googleapis.com sqladmin.googleapis.com storage-api.googleapis.com storage-component.googleapis.com vision.googleapis.com maps-backend.googleapis.com geolocation.googleapis.com geocoding-backend.googleapis.com
###xx gcloud container clusters create ${KLUSTER} --zone ${GCP_ZONE} --release-channel stable --enable-ip-alias --machine-type "n1-standard-4" --num-nodes=3
###xx gcloud compute addresses create google-managed-services-default --global --purpose=VPC_PEERING --prefix-length=20 --network=default
###xx gcloud services vpc-peerings connect --service=servicenetworking.googleapis.com --network=default --ranges=google-managed-services-default
###xx cloudbuild_logs_bucket_suffix=$(generate_bucket_suffix)
###xx add_secret ${secrets_env_file} CLOUDBUILD_LOGS_BUCKET "gs://cloudbuild-logs-${cloudbuild_logs_bucket_suffix}"
###xx gsutil mb -p ${GCP_PROJECT_ID} ${CLOUDBUILD_LOGS_BUCKET}
###xx PROJECT_NUMBER=`gcloud projects list "--filter=${GCP_PROJECT_ID}" "--format=value(PROJECT_NUMBER)"`
###xx gsutil iam ch serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com:objectAdmin,objectCreator,objectViewer,legacyBucketWriter ${CLOUDBUILD_LOGS_BUCKET}
###xx # create autoscaling node pool for cron jobs
###xx gcloud container node-pools create jobs-pool \
###xx   --cluster=${KLUSTER} --zone=${GCP_ZONE} --project=${GCP_PROJECT_ID} \
###xx   --machine-type=e2-standard-8  --disk-size=500GB --min-nodes=0 --max-nodes=3 \
###xx   --node-labels=load=on-demand --node-taints=reserved-pool=true:NoSchedule --enable-autoscaling
###xx gcloud iam service-accounts create cronjob-sa --display-name 'storage access for cron jobs'
###xx gcloud iam service-accounts keys create /tmp/cronjob-service-account.json --iam-account cronjob-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com
###xx cat /tmp/cronjob-service-account.json > container/secrets/cronjob-service-account.json
###xx rm -f /tmp/cronjob-service-account.json
###xx 
###xx #TODO: determine whether warper really uses this service account, and if not, get rid of it
###xx gcloud iam service-accounts create warper-sa --display-name 'warper access for storage and cloud sql'
###xx gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} --member=serviceAccount:warper-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com --role=roles/cloudsql.admin
###xx gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} --member=serviceAccount:warper-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com --role=roles/cloudsql.client
###xx gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} --member=serviceAccount:warper-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com --role=roles/cloudsql.editor
###xx gcloud iam service-accounts keys create /tmp/warper-service-account.json --iam-account warper-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com
###xx cat /tmp/warper-service-account.json > container/secrets/warper-service-account.json
###xx rm -f /tmp/warper-service-account.json
###xx 
###xx ###
###xx ### warper storage buckets
###xx ###
###xx set +x
###xx add_secret ${secrets_env_file} BUCKET_SUFFIX $(generate_bucket_suffix)
###xx add_secret ${secrets_env_file} MAPWARPER_WARPER_BUCKET "warper-${BUCKET_SUFFIX}"
###xx add_secret ${secrets_env_file} MAPWARPER_TILES_BUCKET "tiles-${BUCKET_SUFFIX}"
###xx add_secret ${secrets_env_file} MAPWARPER_OCR_BUCKET "ocr-${BUCKET_SUFFIX}"
###xx set -x
###xx gsutil mb -p ${GCP_PROJECT_ID} gs://${MAPWARPER_WARPER_BUCKET}
###xx gsutil mb -p ${GCP_PROJECT_ID} gs://${MAPWARPER_TILES_BUCKET}
###xx gsutil mb -p ${GCP_PROJECT_ID} gs://${MAPWARPER_OCR_BUCKET}
###xx 
###xx #  give service account "warper-sa" access to those buckets
###xx gsutil iam ch serviceAccount:warper-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com:objectAdmin,objectCreator,objectViewer gs://${MAPWARPER_WARPER_BUCKET}
###xx gsutil iam ch serviceAccount:warper-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com:objectAdmin,objectCreator,objectViewer gs://${MAPWARPER_TILES_BUCKET}
###xx gsutil iam ch serviceAccount:warper-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com:objectAdmin,objectCreator,objectViewer gs://${MAPWARPER_OCR_BUCKET}
###xx 
###xx # create tiles-backend-bucket
###xx gcloud compute backend-buckets create tiles-backend-bucket --enable-cdn --gcs-bucket-name=${MAPWARPER_TILES_BUCKET}
###xx 
###xx # set up url maps and public ip for tiles-backend-bucket
###xx gcloud compute url-maps create warper-tiles-url-map --default-backend-bucket=tiles-backend-bucket
###xx gcloud compute url-maps add-path-matcher warper-tiles-url-map --default-backend-bucket tiles-backend-bucket --path-matcher-name warper-tiles-bucket-matcher '--backend-bucket-path-rules=/*=tiles-backend-bucket'
###xx gcloud compute target-http-proxies create http-tiles-lb-proxy --url-map warper-tiles-url-map
###xx gcloud compute addresses create warper-tiles-ip --global
###xx gcloud compute forwarding-rules create tiles-http-forwarding-rule --address=warper-tiles-ip --global --target-http-proxy http-tiles-lb-proxy --ports=80
###xx 
###xx 
###xx ###
###xx ### warper managed NAS file storage
###xx ###
###xx gcloud filestore instances create warper-fs --project=${GCP_PROJECT_ID} --zone=${GCP_ZONE} --tier=STANDARD --file-share=name=mapfileshare,capacity=1TB --network=name=default
###xx set +x
###xx add_secret ${secrets_env_file} MAPWARPER_NFS_SERVER "`gcloud filestore instances describe warper-fs --zone=us-east4-a --format="value(networks[0].ipAddresses[0])"`"
###xx set -x
###xx # create PersistentVolume (nfs mount) called warper-fileserver
###xx ${script_dir}/kapply k8s/warper-filestore-storage.yaml.in
###xx 
###xx ###
###xx ### create services
###xx ###
###xx ${script_dir}/kcreate k8s/cgimap-service.yaml.in
###xx ${script_dir}/kcreate k8s/editor-service.yaml.in
###xx ${script_dir}/kcreate k8s/fe-service.yaml.in
###xx ${script_dir}/kcreate k8s/warper-service.yaml.in
###xx ${script_dir}/kcreate k8s/oauth-proxy-service.yaml.in
###xx if [ "${ENABLE_KARTTA}" != "" ]; then
###xx   ${script_dir}/kcreate k8s/kartta-service.yaml.in
###xx fi
###xx 
###xx 
###xx ###
###xx ### clone code repos
###xx ###
###xx clone_repo "$EDITOR_REPO" editor-website
###xx clone_repo "${MAPWARPER_REPO}" warper
###xx clone_repo "${CGIMAP_REPO}" openstreetmap-cgimap
###xx clone_repo "${KSCOPE_REPO}" kscope
###xx clone_repo "${RESERVOIR_REPO}" reservoir
###xx if [ "${ENABLE_KARTTA}" != "" ]; then
###xx   clone_repo "${KARTTA_REPO}" kartta
###xx   clone_repo "${ANTIQUE_REPO}" antique kartta
###xx fi
###xx 
###xx ###
###xx ### build & tag latest images
###xx ###
###xx 
###xx cloud_build oauth-proxy
###xx cloud_build fe
###xx cloud_build editor
###xx cloud_build cgimap
###xx cloud_build warper
cloud_build cronjob
###xx if [ "${ENABLE_KARTTA}" != "" ]; then
###xx   cloud_build kartta
###xx fi
###xx 
###xx 
###xx ### # oauth-proxy
###xx ### export OAUTH_PROXY_SHORT_SHA=
###xx ### gcloud builds submit "--gcs-log-dir=${CLOUDBUILD_LOGS_BUCKET}/oauth_proxy" "--substitutions=SHORT_SHA=${OAUTH_PROXY_SHORT_SHA}"  --config k8s/cloudbuild-oauth-proxy.yaml .
###xx ### gcloud container images add-tag --quiet "gcr.io/${GCP_PROJECT_ID}/oauth-proxy:${OAUTH_PROXY_SHORT_SHA}" "gcr.io/${GCP_PROJECT_ID}/oauth-proxy:latest"
###xx ### 
###xx ### # fe
###xx ### export FE_SHORT_SHA=`cat Dockerfile-fe container/config/fe/* | md5sum  | sed -e 's/\(.\{7\}\).*/\1/'`
###xx ### gcloud builds submit "--gcs-log-dir=${CLOUDBUILD_LOGS_BUCKET}/fe" "--substitutions=SHORT_SHA=${FE_SHORT_SHA}"  --config k8s/cloudbuild-fe.yaml .
###xx ### gcloud container images add-tag --quiet "gcr.io/${GCP_PROJECT_ID}/fe:${FE_SHORT_SHA}" "gcr.io/${GCP_PROJECT_ID}/fe:latest"
###xx ### 
###xx ### # editor
###xx ### export EDITOR_SHORT_SHA=`(cd editor-website ; git rev-parse --short HEAD)`
###xx ### gcloud builds submit "--gcs-log-dir=${CLOUDBUILD_LOGS_BUCKET}/editor" "--substitutions=SHORT_SHA=${EDITOR_SHORT_SHA}"  --config k8s/cloudbuild-editor.yaml .
###xx ### gcloud container images add-tag --quiet "gcr.io/${GCP_PROJECT_ID}/editor:${EDITOR_SHORT_SHA}" "gcr.io/${GCP_PROJECT_ID}/editor:latest"
###xx ### 
###xx ### # cgimap
###xx ### export CGIMAP_SHORT_SHA=`(cd openstreetmap-cgimap ; git rev-parse --short HEAD)`
###xx ### gcloud builds submit "--gcs-log-dir=${CLOUDBUILD_LOGS_BUCKET}/cgimap" "--substitutions=SHORT_SHA=${CGIMAP_SHORT_SHA}"  --config k8s/cloudbuild-cgimap.yaml .
###xx ### gcloud container images add-tag --quiet "gcr.io/${GCP_PROJECT_ID}/cgimap:${CGIMAP_SHORT_SHA}" "gcr.io/${GCP_PROJECT_ID}/cgimap:latest"
###xx ### 
###xx ### # warper
###xx ### export MAPWARPER_SHORT_SHA=`(cd warper ; git rev-parse --short HEAD)`
###xx ### gcloud builds submit "--gcs-log-dir=${CLOUDBUILD_LOGS_BUCKET}/warper" "--substitutions=SHORT_SHA=${MAPWARPER_SHORT_SHA}"  --config k8s/cloudbuild-warper.yaml .
###xx ### gcloud container images add-tag --quiet "gcr.io/${GCP_PROJECT_ID}/warper:${MAPWARPER_SHORT_SHA}" "gcr.io/${GCP_PROJECT_ID}/warper:latest"
###xx 
###xx if [ "${ENABLE_RESERVOIR}" != "" ]; then
###xx   . ${script_dir}/reservoir_functions.sh
###xx   LOG_INFO "Bootstrapping reservoir."
###xx   if ! reservoir_kbootstrap; then
###xx     LOG_ERROR "Failed to bootstrap reservoir."
###xx   fi
###xx else
###xx   LOG_INFO "Skipping Reservoir bootstrap."
###xx fi
###xx 
###xx 
###xx ###
###xx ### editor database
###xx ###
###xx 
###xx # create the sql instance
###xx #   Note we set temp_file_limit=2147483647, which is the max allowd value per
###xx #   https://cloud.google.com/sql/docs/postgres/flags#gcloud, because a large limit is needed to support generating data
###xx #   exports with osmosis.
###xx gcloud beta sql instances create editor-sql --cpu=1 --memory=3840MiB --database-version=POSTGRES_11 --zone=${GCP_ZONE} --storage-type=SSD --network=default --database-flags temp_file_limit=2147483647 --no-assign-ip
###xx 
###xx set +x
###xx echo "generating passwords and storing secrets..."
###xx # store sql instance ip in secrets
###xx add_secret ${secrets_env_file} EDITOR_DB_HOST `gcloud beta sql instances describe editor-sql --format="value(ipAddresses.ipAddress)"`
###xx # generate passwords and store in secrets
###xx add_secret ${secrets_env_file} EDITOR_DB_USER karttaweb
###xx add_secret ${secrets_env_file} EDITOR_SQL_POSTGRES_PASSWORD $(generate_password)
###xx add_secret ${secrets_env_file} EDITOR_SQL_KARTTAWEB_PASSWORD $(generate_password)
###xx set -x
###xx 
###xx # set the generated passwords
###xx gcloud beta sql users set-password postgres --instance=editor-sql "--password=${EDITOR_SQL_POSTGRES_PASSWORD}"
###xx gcloud beta sql users create karttaweb --instance=editor-sql "--password=${EDITOR_SQL_KARTTAWEB_PASSWORD}"
###xx 
###xx # perform database migration; note this uses the gcr.io editor image built above to run a job
###xx ${script_dir}/resecret
###xx ${script_dir}/kcreate k8s/editor-db-migration-job.yaml.in
###xx set +x
###xx wait_for_k8s_job editor-db-migration
###xx set -x
###xx # Don't delete this job for now, to make it possible to view its logs.
###xx #kubectl delete job editor-db-migration
###xx # storage bucket for editor db extracts
###xx add_secret ${secrets_env_file} EDITOR_DB_DUMP_BUCKET "editor-db-dump-${BUCKET_SUFFIX}"
###xx gsutil mb -p ${GCP_PROJECT_ID} gs://${EDITOR_DB_DUMP_BUCKET}
###xx gsutil iam ch serviceAccount:cronjob-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com:objectAdmin,objectCreator,objectViewer,legacyBucketWriter,legacyBucketReader,legacyBucketOwner gs://${EDITOR_DB_DUMP_BUCKET}
###xx echo '{"rule": [{"action": {"type": "Delete"}, "condition": {"age": 31}}]}' > /tmp/lifecycle.json
###xx gsutil lifecycle set /tmp/lifecycle.json gs://${EDITOR_DB_DUMP_BUCKET}
###xx rm /tmp/lifecycle.json
###xx 
###xx ###
###xx ### warper database
###xx ###
###xx 
###xx #  create sql instance, store ip, generate and store password
###xx gcloud beta sql instances create warper-sql --cpu=1 --memory=3840MiB --database-version=POSTGRES_9_6 --zone=${GCP_ZONE} --storage-type=SSD --network=default --no-assign-ip
###xx set +x
###xx echo "generating passwords and storing secrets..."
###xx add_secret ${secrets_env_file} MAPWARPER_DB_HOST `gcloud beta sql instances describe warper-sql --format="value(ipAddresses.ipAddress)"`
###xx add_secret ${secrets_env_file} MAPWARPER_POSTGRES_PASSWORD $(generate_password)
###xx set -x
###xx 
###xx # set the generated password
###xx gcloud sql users set-password postgres --instance=warper-sql "--password=${MAPWARPER_POSTGRES_PASSWORD}"
###xx 
###xx # create warper_production database
###xx gcloud sql databases create warper_production --instance=warper-sql
###xx 
###xx 
###xx # perform database migration; note this uses the gcr.io warper image built above to run a job
###xx ${script_dir}/resecret
###xx ${script_dir}/kcreate k8s/warper-db-migration-job.yaml.in
###xx set +x
###xx wait_for_k8s_job warper-db-migration
###xx set -x
###xx # Don't delete this job for now, to make it possible to view its logs.
###xx #kubectl delete job warper-db-migration
###xx 
###xx  
###xx 
###xx ###
###xx ### warper redis instance
###xx ###
###xx gcloud beta redis instances create warper-redis --size=2 --region=${GCP_REGION} --zone=${GCP_ZONE} --redis-version=redis_4_0 --redis-config maxmemory-policy=allkeys-lru
###xx set +x
###xx add_secret ${secrets_env_file} MAPWARPER_REDIS_HOST "`gcloud redis instances describe warper-redis --region=${GCP_REGION} --format="value(host)"`"
###xx add_secret ${secrets_env_file} MAPWARPER_REDIS_URL "redis://${MAPWARPER_REDIS_HOST}:6379/0/cache"
###xx set -x
###xx 
###xx 
###xx ###
###xx ### warper file storage initialization
###xx ###
###xx ${script_dir}/resecret
###xx ${script_dir}/kcreate k8s/warper-fs-initialization-job.yaml.in
###xx set +x
###xx wait_for_k8s_job warper-fs-initialization
###xx set -x
###xx # Don't delete this job for now, to make it possible to view its logs.
###xx #kubectl delete job warper-fs-initialization
###xx 
###xx 
###xx ###
###xx ### deploy applications
###xx ###
###xx ${script_dir}/resecret
###xx ${script_dir}/kcreate k8s/cgimap-deployment.yaml.in
###xx ${script_dir}/kcreate k8s/editor-deployment.yaml.in
###xx ${script_dir}/kcreate k8s/fe-deployment.yaml.in
###xx ${script_dir}/kcreate k8s/oauth-proxy-deployment.yaml.in
###xx ${script_dir}/kcreate k8s/warper-deployment.yaml.in
###xx if [ "${ENABLE_KARTTA}" != "" ]; then
###xx   ${script_dir}/kcreate k8s/kartta-deployment.yaml.in
###xx fi
###xx 
###xx ###
###xx ### noter (all noter stuff, including deploymnt, is handled by kbootstrap-noter.sh)
###xx ###
###xx if [ "${ENABLE_NOTER}" != "" ]; then
###xx   . ${script_dir}/kbootstrap-noter.sh
###xx fi
###xx 
###xx ###
###xx ### create ssl cert and https ingress
###xx ###
###xx ${script_dir}/kcreate k8s/managed-certificate.yaml.in
###xx ${script_dir}/kcreate k8s/backend-config.yaml.in
###xx ${script_dir}/kcreate k8s/nodeport-service.yaml.in
###xx ${script_dir}/kcreate k8s/ingress.yaml.in
###xx set +x
###xx wait_for_ingress_ip "kartta-ingress"
###xx add_secret ${secrets_env_file} INGRESS_IP ${INGRESS_IP}
###xx echo "got INGRESS_IP=${INGRESS_IP}"
###xx set -x
###xx 
###xx 
###xx set +x
###xx echo ""
###xx echo "########################################################################################"
###xx echo ""
###xx echo "Everything is launched.  Excellent!"
###xx echo ""
###xx echo "Run"
###xx echo "    kubectl get pods"
###xx echo "to see the list of running pods.  It might take a few minutes for all pods to"
###xx echo "become ready."
###xx echo ""
###xx echo "You should now create a public DNS entry to associate the name ${SERVER_NAME}"
###xx echo "with the ip address ${INGRESS_IP}."
###xx echo ""
###xx echo "After creating the public DNS entry, run the command"
###xx echo "    kubectl describe managedcertificate"
###xx echo "every few minutes until the domain status says 'Active'. It might take 15-30"
###xx echo "minutes or so.  If the domain status says 'FailedNotVisible', it means the"
###xx echo "the DNS name isn't recognized yet.  If that happens, double-check that you"
###xx echo "correctly created the DNS entry, and wait a few more minutes and check again."
###xx echo "GKE will repeatedly try to provision the certificate every few minutes."
###xx echo ""
###xx echo "Once the certificate is provisioned, you can access the site at"
###xx echo "    https://${SERVER_NAME}"
###xx echo ""
###xx echo "It's normal to get 'Error: Server Error' 502 errors for the first few minutes"
###xx echo "after the certificate is provisioned.  If that happens, wait a few minutes and"
###xx echo "reload the page."
###xx echo ""

) 2>&1 | tee kbootstrap.log
