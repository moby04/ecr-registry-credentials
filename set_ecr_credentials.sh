#!/bin/env bash
# This script is a complex version of ECR credential helper.
# The purpose is to enable Kubelets to pull images from ECR registries in multiple AWS accounts
# In addition script is able to patch any combination of service accounts in various namespaces in the cluster.

# Dependencies:
# aws cli v2.x
# kubectl
#
# Required environment variables (see attached .env.dist):
## Service Account list
##  - any number of variables named SERVICE_ACCOUNT_* (i.e. SERVICE_ACCOUNT_1, SERVICE_ACCOUNT_foo, etc)
##  - every variable needs to have one of following formats:
##      - SERVICE_ACCOUNT_NAME - script will attempt to patch service account in all namespaces in the cluster
##      - NAMESPACE.SERVICE_ACCOUNT_NAME - script will attempt to patch SERVICE_ACCOUNT_NAME in NAMESPACE in the cluster
##
## AWS Account list
##  - any number of variables named AWS_ACCOUNT_NAME_* (i.e. AWS_ACCOUNT_NAME_PORTAL, AWS_ACCOUNT_NAME_1, etc).
##  - each variable should contain some informative name of the account. It will be used for following purposes:
##      - value will be appended to secret names in Kubernetes cluster (i.e. aws-registry-portal)
##      - value in uppercase format will be used as suffix to find AWS credentials for the given account in Env variables
##  - for each AWS_ACCOUNT_NAME_* script requires 4 further variables:
##      - AWS_ACCOUNT_<SUFFIX>           - AWS account id
##      - AWS_REGION_<SUFFIX>>           - default region for the account
##      - AWS_ACCESS_KEY_ID_<SUFFIX>     - access key id for AWS API
##      - AWS_SECRET_ACCESS_KEY_<SUFFIX> - secret access key for AWS API

set -u
if [[ -f "./.env" ]]; then
    export $(egrep -v '^#' ./.env | xargs)
fi

declare -a PROFILES=()
declare -a SERVICE_ACCOUNTS=()

echo -e "\n\n====================================== Parsing environment ====================================\n"
#Load list of service accounts that should be patched.
for SERVICE_ACCOUNT in $(printenv | grep -e '^SERVICE_ACCOUNT_' | cut -f1 -d"="); do
    SERVICE_ACCOUNTS+=(${!SERVICE_ACCOUNT})
    TEST_VAR="${!SERVICE_ACCOUNT//[^\.]/}"
    if [ ${#TEST_VAR} -gt 1 ]; then
        echo "${SERVICE_ACCOUNT} variable has too many nesting levels: ${!SERVICE_ACCOUNT}"
        exit 1
    fi
done

if [ ${#SERVICE_ACCOUNTS[@]} -eq 0 ]; then
    # exit if there are no service accounts to be patched - no secrets will be created/refreshed!
    echo "No service accounts to patch"
    exit 0
fi

echo "Service accounts to be patched:"
for SERVICE_ACCOUNT in "${SERVICE_ACCOUNTS[@]}"; do
    echo -e "\t- ${SERVICE_ACCOUNT}"
done
echo

# Iterate over provided AWS Accounts to fetch ECR token for each of them
for ACCOUNT_VARIABLE in $(printenv | grep -e '^AWS_ACCOUNT_NAME_' | cut -f1 -d"="); do
    ACCOUNT_NAME=${!ACCOUNT_VARIABLE}

    PROFILES+=(${ACCOUNT_NAME})

    echo -e "Detected variable\t\t${ACCOUNT_VARIABLE}.\n\tAccount name is\t\t${ACCOUNT_NAME}\n\tenv var suffix is\t${ACCOUNT_NAME^^}"

    #verify that all required variables for given accounts are provided
    AWS_ACCOUNT_VAR="AWS_ACCOUNT_${ACCOUNT_NAME^^}"
    if [ -z ${!AWS_ACCOUNT_VAR+x} ]; then
      echo "AWS_ACCOUNT for ${ACCOUNT_NAME} is not set";
      exit 1;
    fi

    AWS_REGION_VAR="AWS_REGION_${ACCOUNT_NAME^^}"
    if [ -z ${!AWS_REGION_VAR+x} ]; then
      echo "AWS_REGION for ${ACCOUNT_NAME} is not set";
      exit 1;
    fi

    AWS_ACCESS_KEY_ID_VAR="AWS_ACCESS_KEY_ID_${ACCOUNT_NAME^^}"
    if [ -z ${!AWS_ACCESS_KEY_ID_VAR+x} ]; then
      echo "AWS_ACCESS_KEY_ID for ${ACCOUNT_NAME} is not set";
      exit 1;
    fi

    AWS_SECRET_ACCESS_KEY_VAR="AWS_SECRET_ACCESS_KEY_${ACCOUNT_NAME^^}"
    if [ -z ${!AWS_SECRET_ACCESS_KEY_VAR+x} ]; then
      echo "AWS_SECRET_ACCESS_KEY for ${ACCOUNT_NAME} is not set";
      exit 1;
    fi

    # create local variables with docker credentials for given account
    eval "DOCKER_REGISTRY_SERVER_${ACCOUNT_NAME^^}"="https://${!AWS_ACCOUNT_VAR}.dkr.ecr.${!AWS_REGION_VAR}.amazonaws.com"
    eval "DOCKER_USER_${ACCOUNT_NAME^^}"="AWS"
    eval "DOCKER_PASSWORD_${ACCOUNT_NAME^^}"="$(
        AWS_ACCESS_KEY_ID=${!AWS_ACCESS_KEY_ID_VAR} \
        AWS_SECRET_ACCESS_KEY=${!AWS_SECRET_ACCESS_KEY_VAR} \
        aws ecr get-login-password --region ${!AWS_REGION_VAR}
    )"
    echo "Fetched Docker credentials for ${ACCOUNT_NAME}"
done

echo -e "\n\n================================== Updating Kubernetes objects ================================\n"

# at this point we have list of profiles in PROFILES list
# along with set of 3 variables for each profile: DOCKER_REGISTRY_SERVER_<PROFILE>, DOCKER_USER_<PROFILE> and DOCKER_PASSWORD_<PROFILE>

#iterate over all Kubernetes namespaces
for KUBE_NAMESPACE in $(kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    declare -a SECRET_NAMES=()
    for PROFILE in "${PROFILES[@]}"; do
        DOCKER_REGISTRY_SERVER_VAR="DOCKER_REGISTRY_SERVER_${PROFILE^^}"
        DOCKER_USER_VAR="DOCKER_USER_${PROFILE^^}"
        DOCKER_PASSWORD_VAR="DOCKER_PASSWORD_${PROFILE^^}"
        SECRET_NAME="aws-registry-${PROFILE}"
        SECRET_NAMES+=(${SECRET_NAME})

        # delete old secret and create new one with refresh login token
        echo -e " -> Resetting secret with credentials for ${PROFILE} in ${KUBE_NAMESPACE}"
        kubectl delete secret -n $KUBE_NAMESPACE ${SECRET_NAME} || true;
        kubectl create secret docker-registry ${SECRET_NAME} \
              -n $KUBE_NAMESPACE \
              --docker-server=${!DOCKER_REGISTRY_SERVER_VAR} \
              --docker-username=${!DOCKER_USER_VAR} \
              --docker-password=${!DOCKER_PASSWORD_VAR} \
              --docker-email=no@email.local;
    done

    # generate json patch with list of all secrets containing docker credentials
    PATCH='{"imagePullSecrets":['
    for SECRET_NAME in "${SECRET_NAMES[@]}"; do
        PATCH="$PATCH $(printf '{"name": "%s"},' ${SECRET_NAME})"
    done
    PATCH="$(echo $PATCH | sed 's/,$//')"
    PATCH="$PATCH ]}"
#    echo $PATCH | jq

    # iterate over provided service account list
    for SERVICE_ACCOUNT in "${SERVICE_ACCOUNTS[@]}"; do
        # if SERVICE_ACCOUNT contains . assume that it should be patched in only one namespace
        if [[ "${SERVICE_ACCOUNT}" == *"."* ]]; then
            NAMESPACE=${SERVICE_ACCOUNT%%.*}
            if [[ "${NAMESPACE}" != "${KUBE_NAMESPACE}" ]]; then
                echo -e "\t X skipping ${SERVICE_ACCOUNT} in ${KUBE_NAMESPACE} namespace"
                continue
            fi
            SERVICE_ACCOUNT_NAME=${SERVICE_ACCOUNT#*.}
        else
            SERVICE_ACCOUNT_NAME=$SERVICE_ACCOUNT
        fi

        echo -e " -> Patching ${SERVICE_ACCOUNT_NAME} in ${KUBE_NAMESPACE} namespace"
        kubectl patch serviceaccount -n $KUBE_NAMESPACE $SERVICE_ACCOUNT_NAME -p "${PATCH}";
    done

    echo
done

