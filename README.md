# Kartta Labs Suite

This project contains everything you need to spin up a complete suite of Kartta
Labs web applications for development purposes on your local system in docker.  It also
contains configuration files and scripts needed to launch the applications in
GKE (Google Kubernetes Engine).

This project does not contain the code for the individual applications -- it
just contains the overall scripts and configuration files for launching and
managing the applications together.  The code for each application is stored in
its own repositiory in http://github.com/kartta-labs.  The scripts in this
project will take care of cloning the applications repos for you.


## Initial Setup

Do these things just once to get set up.

1. Install Docker


2. Clone this repo and cd into it

   ```
   git clone https://github.com/kartta-labs/Project
   cd Project
   ```

3. Generate a secrets file by running

   ```
   ./makesecrets
   ```
   This will create the file `./container/secrets/secrets.env` by copying `example-secrets.env`.
   For running locally with docker for development, you don't need to edit the generated file,
   although you may customize the configuration by editing it if you want.

   You can provide a set of intial values to `makesecrets` by passing it a YAML file if you want:
   ```
   ./makesecrets values.yml
   ```
   This will cause `makesecrets` to substitute values found in `values.yml` for the the corresponding
   variable when generating `./container/secrets/secrets.env`.  Note: you can't use `values.yml` to
   add additional variables -- the substitution only happens for variables already present in
   `example-secrets.env`.

   If you want to use code from a repository other than the offical http://github.com/kartta-labs
   repository for one or more of the applications, change the value of the appropriate *_REPO
   variable(s) in ./container/secrets/secrets.env before continuing.

4. Run the bootstrap script
   ```
   ./bootstrap.sh
   ```
   This will take 45-60 minutes or so but only has to be done once.  It might ask you to
   enter your password at various points (because it uses sudo, since many docker commands
   need to run as root), so check on it occasionally.


## Running

Once `bootstrap.sh` finishes, to run the suite of applications, do

```
./start
```
Leave this command running in one terminal; use a separate terminal for everything else below.  To shut everything down
when you are done, or so you can restart everything, hit Ctrl-C.

Once all the containers have started (usually 1 or 2 minutes), visit http://localhost/e/ in your browser
for editor, or http://localhost/w/ for mapwarper.

### Things to note

1. See the file ARCHITECTURE.md in this directory for a general overview of
   how these applications are configure.

1. As currently configured this will only work on port 80 on localhost, which
   unfortunately means you can't port-forward to your local machine if you're
   accessing the host remotely, since only root can forward privileged ports.
   That means that in order to view this in a browser you'll have to
   remotedesktop to the host machine and run the browser there.  It's possible
   to reconfigure everything to use a public port other than 80, though, and/or
   a hostname other than 'localhost', but that will involve some careful
   tweaking of the various nginx docker configs.

1. The apps currently run on port 8888 using http (not https).  If you want
   to view using a local browser, use ssh to tunnel port 8888 from your remote
   host to your local machine: `ssh -L 8888:localhost:8888 remote.machine.net`.

1. Run `docker ps` to see a list of all the running containers; the output will look similar to this:
   ```
   CONTAINER ID   IMAGE                  COMMAND                  PORTS                                            NAMES
   cd904223a9d1   project_fe             "nginx -g 'daemon of…"   0.0.0.0:80->80/tcp                               project_fe_1
   3539235734cd   project_editor         "/editor-container-s…"   0.0.0.0:32936->80/tcp                            project_editor_1
   34d109561bca   project_mapwarper      "/mapwarper-containe…"   0.0.0.0:32938->80/tcp, 0.0.0.0:32937->3000/tcp   project_mapwarper_1
   c2916d2bb811   project_cgimap         "/cgimap-container-s…"   0.0.0.0:32935->8000/tcp                          project_cgimap_1
   1d039d94f71d   project_oauth-proxy    "/root/go/bin/oauth2…"   0.0.0.0:4180->4180/tcp                           project_oauth-proxy_1
   afdeaf8b1429   mdillon/postgis        "docker-entrypoint.s…"   5432/tcp                                         project_mapwarper-db_1
   750b55e3ae1f   redis                  "docker-entrypoint.s…"   6379/tcp                                         project_redis_1
   707c200a13e8   postgres:11            "docker-entrypoint.s…"   5432/tcp                                         project_editor-db_1
   ```

1. Each container corresponds to a "service" entry in the `docker-compose.yml` file.
   Each one is like a single server, or VM.  The ones whose IMAGE name start with 'project_' correspond
   to services Kartta runs in production:

     * fe: frontend nginx server, receives all incoming requests and routes them
       internally to the relevant other service
     * oauth-proxy: handles all authentication
     * editor: editor-website rails app
     * mapwarper: mapwarper rails app

   The other containers are local instances of postgres/postgis/redis servers which are needed by
   the project_ services.  In production we use GCP managed versions of these services.

   You can use the `./dsh` script to start a bash shell in any of the
   containers; it takes a single arg which is the name of the service (without
   the 'project_' prefix or '_1' suffix).  For example `./dsh editor`.  This is like
   "ssh-ing" to the VM; once in the shell, you can poke around with the
   filesystem and running processes for the container.  In particular, you can
   use this to view the nginx config, application log files, or running processes.

1. All the config files and application code for the editor and mapwarper apps,
   as well as all nginx conf files, are "mounted" inside the containers from
   their corresponding location in the 'Project' directory on your workstation (the
   docker "host").  You can edit these files with an editor on the host, and the
   changes are immediately visible from inside the running containers.  The mappings
   that determine which files/dirs get mounted in each container, and where, are
   given by the "volumes" directives in the `docker-compose.yml` file.

1. Inside any of the nginx containers (editor, mapwarper, fe), run
   `nginx -s reload`
   to restart nginx after changing either the nginx conf or any of the
   application files.

1. `docker-compose` creates a local IP network in which each container is known
   by its service name from the `docker-compose.yml` file.  For example, the
   editor container can be referred to by the name `editor` when constructing
   hostnames and/or urls for use in any of the containers.  These names are not
   available on the host -- only inside the containers.

1. The `docker-compose.yml` file in the top level `Project` directory references various
   environment variables which must be set in order for it to work.  These variables
   are set in the secrets file `./container/secrets/ecrets.env`, and the `./start`
   script takes care of loading these values into the environment automatically.
   You should always use `./start` to launch the containers -- it runs `docker-compose up`
   for you, after loading the environment variables from the secrets file.
   If you need to otherwise run `docker-compose` (e.g. to re-build an image for an
   application you're developing), run the `./dcwrapper` script rather than running
   `docker-compose` directly.

## Misc helpful commands

* Shut down any remaining running containers:
  ```
  sudo docker-compose down
  ```

* Rebuild the docker images before starting the containers:
  ```
  docker-compose up --build
  ```
  This uses docker's build cache so it usually runs much faster than the 30 min
  or so needed to run the bootstrap script initially.  Docker is pretty good
  (but not perfect) about knowing what parts of each build need to be re-done
  based on which files have changed.

* Completely remove all docker artifacts, including built images and cache data:
  ```
  sudo docker system prune -a
  ```
  Do this if you want to force docker to rebuild EVERYTHING the next time you
  run `docker-compose up` (this is like a much stronger version of
  `docker-compose up --build`).

* The database containers store their data in files in the `tmp` dir (the one at the top level of the `Project` dir).
  You can clear the data from a database by removing the corresponding file from `tmp`.  Note that if you do that,
  the database will need to be re-initialized by re-running the relevant commands from `bootstrap.sh`.
  If you are at all unsure about what's needed to do this, it's probably safer to start over by doing
  `sudo docker system prune -a` to clear everything out of docker, clone a new copy of this `Project` repo,
  and re-run `bootstrap.sh`.


## Kubernetes Deployments

The 'k8s' directory contains configuration files and scripts for deploying the
suite of applications in GKE (Google Kubernetes Engine).  This is intended for
running production servers, and/or for testing the production deployment
process.  If you just want to run the suite so you can work on one or more of
the applications, use the docker process described above.


1. Create a new GCP project, or decide on an existing one to use.

2. Clone a fresh copy of this 'Project' repo.  This should be a new copy -- not one that you
   have previously used with docker for local development.

3. Generate a secrets file by running

   ```
   ./makesecrets
   ```

4. Edit `./container/secrets/secrets.env` and set all the required values at the top of the file;
   see the comments in the file for details.

5. Run `./k8s/kbootstrap.sh`.  It may take up to an hour to run.  When it finishes, it will
   print out a message with the IP address of the running server (this is the IP of the load
   balancer).

6. Create a DNS entry which which associates the generated IP adddress with the SERVER_NAME
   you chose above.

7. The vector tile server deployment is handled by a separate script.  If you also want to
   create a vector tile server deployment, run `./k8s/kvector-bootstrap.sh`.  Do this _after_
   running `./k8s/kbootstrap.sh`; `./k8s/kvector-bootstrap.sh` will not work correctly if
   `./k8s/kbootstrap.sh` has not been run first.

8. Note that both `./k8s/kbootstrap.sh` and `./k8s/kvector-bootstrap.sh` edit the secrets file
   (container/secrets/secrets.env) to add information such as IP addresses and names of
   resources they create, or values for passwords they generate.  You should guard that secrets
   file carefully -- it will be needed when making any changes to the deployment.
