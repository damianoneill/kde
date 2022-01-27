#!/bin/bash

# Tested with

# k3d version v5.2.1
# k3s version v1.21.7-k3s1 (default)

: "${SCRIPT_VERSION:=v1.0.0}"

: "${CLUSTER_NAME:=kde}"
: "${KUBE_CONTEXT:="k3d-$CLUSTER_NAME"}"
: "${NO_OF_MASTERS:=1}"
: "${NO_OF_WORKERS:=1}"

: "${COMMON_NAMESPACE:=common}"

: "${NATS_CHART_VERSION:=0.11.0}"

: "${POSTGRES_CHART_VERSION:=10.4.8}" # https://artifacthub.io/packages/helm/bitnami/postgresql
: "${POSTGRES_USERNAME:=postgres}"
: "${POSTGRES_PASSWORD:=postgres}"
: "${POSTGRES_SECRET:=kde.credentials}"

: "${RANCHER_IMAGE:=v1.21.7-k3s1}"

KUBECTL="kubectl --context=$KUBE_CONTEXT"

function installDeps() {
    brew install k3d helm@3 kubectl
}

function installCertManager() {
    helm repo add jetstack https://charts.jetstack.io &&
        helm repo update &&
        $KUBECTL create namespace cert-manager &&
        helm install \
            cert-manager jetstack/cert-manager \
            --namespace cert-manager \
            --create-namespace \
            --version v1.3.1 \
            --set installCRDs=true # To automatically install and manage the CRDs as part of your Helm release, you must add the --set installCRDs=true flag to your Helm installation command.
    # Wait for all pods to be READY and confirm the deployment rolled-out:
    kubectl -n cert-manager rollout status deploy/cert-manager
}

function createRegistry() {
    if ! k3d registry list $CLUSTER_NAME-registry &>/dev/null; then
        k3d registry create -i registry:2 $CLUSTER_NAME-registry --port 0.0.0.0:5111
        echo -n '>>> waiting for registry to be ready '
        until [ "$(docker inspect -f {{.State.Running}} k3d-$CLUSTER_NAME-registry)" == "true" ]; do
            sleep 0.1
            echo -n '.'
        done
        echo '.'
    fi
}

function create() {
    createRegistry
    # https://hub.docker.com/r/rancher/k3s/tags?page=1&ordering=last_updated
    k3d cluster create $CLUSTER_NAME \
        --api-port 6550 \
        --servers $NO_OF_MASTERS \
        --agents $NO_OF_WORKERS \
        --port 8080:80@loadbalancer \
        --port 8443:443@loadbalancer \
        --registry-use k3d-$CLUSTER_NAME-registry:5111 \
        --image rancher/k3s:$RANCHER_IMAGE \
        --wait
    #installCertManager
}

function createWithAmbassador() {
    createRegistry

    # creat cluster without traefik
    k3d cluster create $CLUSTER_NAME \
        --api-port 6550 \
        --servers $NO_OF_MASTERS \
        --agents $NO_OF_WORKERS \
        --port 8080:80@loadbalancer \
        --port 8443:443@loadbalancer \
        --k3s-arg "--no-deploy=traefik@server:0" \
        --registry-use k3d-$CLUSTER_NAME-registry:5111 \
        --image rancher/k3s:$RANCHER_IMAGE \
        --wait

    # Install ambassador
    kubectl create namespace ambassador || echo "namespace ambassador exists"

    helm repo add datawire https://www.getambassador.io
    helm install ambassador datawire/ambassador \
        --set image.repository=gcr.io/datawire/ambassador \
        --set enableAES=false \
        --namespace ambassador &&
        kubectl -n ambassador wait --for condition=available --timeout=90s deploy -lproduct=aes 2>/dev/null
}

function delete() {
    k3d cluster delete $CLUSTER_NAME
    running="$(docker inspect -f '{{.State.Running}}' "k3d-$CLUSTER_NAME-registry" 2>/dev/null || true)"
    if [ "${running}" == 'true' ]; then
        read -r -p "Do you want to delete the registry k3d-$CLUSTER_NAME-registry (y/N)? " choice
        choice=${choice:-N}
        case "$choice" in
        y | Y) echo ">>> Deleting registry k3d-$CLUSTER_NAME-registry" && k3d registry delete $CLUSTER_NAME-registry &>/dev/null || fail "Problem deleting registry k3d-$CLUSTER_NAME-registry" ;;
        n | N) ;;
        *) fail "invalid" ;;
        esac
    fi
}

function showVersion() {
    echo "Script Version: $SCRIPT_VERSION"
}

function clusterStatus() {
    $KUBECTL get nodes,all -o wide
}

function installNats() {
    helm repo add nats https://nats-io.github.io/k8s/helm/charts/
    helm install nats \
        --namespace=$COMMON_NAMESPACE \
        --version $NATS_CHART_VERSION nats/nats
    kubectl rollout status statefulset nats -n $COMMON_NAMESPACE
}

function installPostgres() {
    helm repo add bitnami https://charts.bitnami.com/bitnami
    helm install postgresql \
        --namespace=$COMMON_NAMESPACE \
        --version $POSTGRES_CHART_VERSION \
        --set postgresqlUsername=$POSTGRES_USERNAME \
        --set postgresqlPassword=$POSTGRES_PASSWORD bitnami/postgresql
    kubectl rollout status statefulset postgresql-postgresql -n $COMMON_NAMESPACE
}

function createNamespace() {
    kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f -
}

function confirmHelmReleaseInstalled() {
    helm get all "$1" -n "$2" &>/dev/null
    return $?
}

function createSecret() {
    kubectl create secret generic $POSTGRES_SECRET -n $COMMON_NAMESPACE \
        --from-literal=username=postgres \
        --from-literal=password=postgres \
        --from-literal=password-superuser=postgres \
        --save-config --dry-run=client -o yaml |
        kubectl apply -f -
}

function installBackingServices() {
    createNamespace $COMMON_NAMESPACE
    createSecret
    if ! confirmHelmReleaseInstalled postgresql $COMMON_NAMESPACE; then
        installPostgres
    fi
    if ! confirmHelmReleaseInstalled nats $COMMON_NAMESPACE; then
        installNats
    fi
}

function helpfunction() {
    echo "kde.sh - Kubernetes Developer Environment

    Usage: kde.sh -h
           kde.sh -c -r -b"
    echo ""
    echo "      -i    Install dependencies (k3d, helm, kubectl)"
    echo "      -h    Show this help message"
    echo "      -v    Show Version"
    echo "      -c    Create a Cluster"
    echo "      -a    Create a Cluster with Ambassador (instead of Traefik)"
    echo "      -d    Delete a Cluster"
    echo "      -s    Cluster Status"
    echo "      -r    Create Registry"
    echo "      -b    Install 3rd-party Backing Services (postgres, nats, ...)"
    echo ""
}

if [ $# -eq 0 ]; then
    helpfunction
    exit 1
fi

while getopts "hvicadsrb-:" OPT; do
    if [ "$OPT" = "-" ]; then   # long option: reformulate OPT and OPTARG
        OPT="${OPTARG%%=*}"     # extract long option name
        OPTARG="${OPTARG#$OPT}" # extract long option argument (may be empty)
        OPTARG="${OPTARG#=}"    # if long option argument, remove assigning `=`
    fi
    case $OPT in
    h)
        helpfunction
        ;;
    v)
        showVersion
        ;;
    i)
        installDeps
        ;;
    c)
        create
        ;;
    a)
        createWithAmbassador
        ;;
    d)
        delete
        ;;
    s)
        clusterStatus
        ;;
    r)
        createRegistry
        ;;
    b)
        installBackingServices
        ;;
    *)
        echo "$(basename "${0}"):usage: [-c] | [-a] | [-d] | [-s] | [-r] | [-b] [-e]"
        exit 1 # Command to come out of the program with status 1
        ;;
    esac
done
