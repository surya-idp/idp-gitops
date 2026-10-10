#!/bin/sh
# Prints "AWS:<token>" for the ECR registry. ECR is not a built-in registry type in Image
# Updater, so registries.conf runs this script (credentials: ext:...). The token comes from
# the pod's IAM role (IRSA, role idp-image-updater) and lasts 12h; credsexpire re-runs it.
set -eu
HOME=/tmp aws ecr get-authorization-token --region ap-south-1 \
  --output text --query 'authorizationData[0].authorizationToken' | base64 -d
echo
