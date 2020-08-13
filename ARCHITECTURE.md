# Kartta Labs Suite Configuration Architecture

This file gives an overview of the docker and kubernetes configurations implemented in
this directory for the Kartta Labs suite of applications.

The goal of this system is to make it as simple as possible to launch these
applications both locally for development work, and in GKE for production, with
minimal required manual intervention, and sharing as much of the configuration
infrastructure as possible between the docker and k8s systems.


## Secrets file

The file `./container/secrets/secrets.env` contains environment variables which
specify all values that are (or might be) different across different deployments of
the application suite.  This includes things like ip addresses of database servers, database
passwords, domain names, etc.  This file isn't present in the repo.  The repo contains
a "default" version of this file called `example-secrets.env` that doesn't contain any
sensitive information.

The script `makesecrets` creates a new `./container/secrets/secrets.env` by
copying `example-secrets.env`, optionally substituting values of specific
variables in the process.

will copy

; the `bootstrap.sh`
script will copy it from CNS if you don't have a copy in place.

For development work with docker, you don't need to make any changes to the default
version of the file as copied from CNS.

For a k8s deployment, a few values need to be set near the top of the file before running
`./k8s/kbootstrap.sh` (see the instructions in README.md).  Also, when `./k8s/kbootstrap.sh` runs,
it edits the secrets file to add information (IP addresses, passwords, names) for resources
it creates.

This secrets file is made available to each container when it is launched via the
Volumne Mounts described below.

Note that the the application in each container typically does not read the
secrets file directly.  Each container has a launch script that run when the
container starts up; the launch script generates the relevant application config
files based on config file templates and the current values in the secrets file,
and then starts the container's application.  More about this below.

Note that the secrets file serves two purposes.  First, it serves as the single
location for specifying all values that might be different between different
deployments of the application suite -- things like server ip addresses,
hostnames, passwords, and any other deployment-specific configuration values.
Some of these values, such as passwords, are sensitive and should be kept out of
code repositories and hidden from everyone other than site administrator.  Other
values in the file are not sensitive and technically could be stored in some
other config file that's not considered "secret", but in the interest of having
one single location for all deployment-specific parameters, we choose to use
this file for both sensitive and non-sensitive values.

The second purpose of the secrets file is to encrypt whatever sensitive data it
contains in the GKE deployment.  (No encryption happens for a local docker deployment.)
This encryption happens by virtue of how we deploy the file to GKE; the file
itself is not encrypted on your workstation, or inside the running containers.



## Mounted Volumes

In both the docker and k8s environments, each container has the following directories mounted
as filesytems inside it:

* `/container/config/NAME` (NAME is the name of the container); contains the launch script
  for the container, and template files for generating application-specific config files.

* `/container/tools`; contains common utilities used
  in multiple containers.

* `/container/secrets`; contains the secrets file.

These volumes are all mounted read-only.

These volumes correspond to the contents of the ./container directory in the repo.  Whenever
you launch the applications with docker or k8s, the contents of this directory are essentially
copied and made available read-only inside the containers.

Note that file permissions (in particular, execute permission) are not always correctly represented in
docker or k8s volume mounts, so all the scripts in the above directories are intended to be
invoked by passing the script name as an argument to `bash`, rather than by having the file
be executable and invoking it directly.


## Launch process

The launch script for each container is `/container/config/NAME/launch`.  This
script generates the relevant application config files based on templates in
`/container/config/NAME` and the values in the secrets file, and then starts the
container's application.  The launch scripts are intentially short and simple; if you
want to know exactly what happens when a container launches, including which config files
get generated from which templates, read its `launch` script.  Note that in some cases
`launch` calls a separate script to generate the config files.


## Config File Generation, ${D} Special Value

Config files are generated from template files in `/container/config/NAME` using
the `/usr/bin/envsubst` program (the substitution is done by the utility script
`/container/tools/subst`).  `envsubst` does a simple substitution of any ${NAME}
or $NAME expression in the input file with the value of the corresponding
variable from the secrets file; there is unfortunately no way to escape a $ in
the input, so we use a special variable name 'D' whose value is '$'.  In any
template file where a $ is required (for example variable references in nginx
config files), put ${D} instead.


# Appendix: Crash Course in Docker and Kubernetes

Here's a quick rundown of the relevant Docker and Kubernetes concepts, in case you're not
already familiar with these terms:

*docker image*: a binary file used to start a container; analogous to a VM image file

*Dockerfile*: contains a set of instructions for building a docker image

*container*: a running instance of a docker image; like a VM but much more lightweight.  In
our case a container typically runs just one application, although that may involve
multiple processes (e.g. multiple nginx worker processes, or nginx + separate rails application process).

*docker*: a system for running containers

Both docker and k8s use docker images.  For local docker runs, these images are built
locally on your workstation (the `bootstrap.sh` script does this).  For k8s deployements,
the images are build in Google Cloud using CloudBuild (the `./k8s/kbootstrap.sh` script
does this, using the various `./k8s/cloudbuild-*.yaml` files).

*pod*: containers in kubernetes are organized into pods.  In general a pod can
contain multiple containers, but most of our pods contain just one container, so
for our purposes you can think of pods and containers as essentially the
same. (The exception is the h3dmr application which uses the "sidecar" pattern
to pair a sql proxy container together with the application container in the
same pod.)

*kubernetes deployment*: a pod (container) specification together with a collection
of volume mounts to be made available inside the container, and rules that can be used
to determine whether the container is running correctly so it can be killed/restarted
if not.


*docker-compose*: a companion program to docker which allows multiple docker containers
that may have dependencies between them (e.g. one container for an application, and another
for its database backend) to be brought up and taken down together

*docker-compose.yml*: configuration file that defines all the docker containers in the suite,
and their dependencies on each other.  Also contains volume mount specifications.  (The info
in this file is essentially the docker equivalent of everything in all the k8s deployment files
(k8s/*-deployment.aml)).
