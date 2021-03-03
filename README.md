# ECR Credentials Helper

This image is supposed to refresh Docker credentials to authenticate Service Account in Kubernetes cluster to enable
pulling images from AWS ECR.

Unlike most images available in public this one provides flexibility to generate credentials for multiple ECR instances
in various AWS accounts. In addition it is also capable to update multiple Service Accounts in number of K8s namespaces
for more advanced setups.

For details see the comments in `set_ecr_credentials.sh` script.
