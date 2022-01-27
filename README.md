# Kubernetes Developer Environment (kde)

kde is a convenience wrapper for developers using k3d.  It creates a k3d cluster and install a set of backing services (Postgres and nats.io) to play with.

It includes an option for using Ambassador instead of Traefik.

It creates a local registry that is accessible from within the cluster, allowing you to push images to the registry from your desktop and reference them directly in the Kubernetes config. 

The registries default name is k3d-kde-registry you should add an entry to your /etc/hosts. 

```sh
cat /etc/hosts
##
# Host Database
#
# localhost is used to configure the loopback interface
# when the system is booting.  Do not change this entry.
##
127.0.0.1	localhost
255.255.255.255	broadcasthost
::1             localhost
# Added by Docker Desktop
# To allow the same kube context to work on the host and the container:
127.0.0.1 kubernetes.docker.internal
# End of section

127.0.0.1	k3d-kde-registry
```

You can then tag/push/run as below.

```sh
# tag an existing local image to be pushed to the registry
docker tag hello-world:latest k3d-kde-registry:5111/hello-world:v0.1

# push that image to the registry
docker push k3d-kde-registry:5111/hello-world:v0.1

# run a pod that uses this image
kubectl run mynginx --image k3d-kde-registry:5111/hello-world:v0.1
```


It includes an option for OSX users to install the dependencies using [homebrew](https://brew.sh/).

## usage

```sh
kde.sh - Kubernetes Developer Environment

    Usage: kde.sh -h
           kde.sh -c -r -b

      -i    Install dependencies (k3d, helm, kubectl)
      -h    Show this help message
      -v    Show Version
      -c    Create a Cluster
      -a    Create a Cluster with Ambassador (instead of Traefik)
      -d    Delete a Cluster
      -s    Cluster Status
      -r    Create Registry
      -b    Install 3rd-party Backing Services (postgres, nats, ...)
```
