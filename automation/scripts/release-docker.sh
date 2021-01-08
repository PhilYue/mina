#!/bin/bash

set -x

CLEAR='\033[0m'
RED='\033[0;31m'

function usage() {
  if [ -n "$1" ]; then
    echo -e "${RED}👉  $1${CLEAR}\n";
  fi
  echo "Usage: $0 [-s service-to-release] [-v service-version]"
  echo "  -s, --service             The Service being released to Dockerhub"
  echo "  -v, --version             The version to be used in the docker image tag"
  echo ""
  echo "Example: $0 --service faucet --version v0.1.0"
  exit 1
}

while [[ "$#" -gt 0 ]]; do case $1 in
  -s|--service) SERVICE="$2"; shift;;
  -v|--version) VERSION="$2"; shift;;
  --extra-args) EXTRA="$2"; shift;;
  --no-upload) NOUPLOAD=1;shift;;
  *) echo "Unknown parameter passed: $1"; exit 1;;
esac; shift; done

echo $EXTRA

# Verify Required Parameters are Present
if [ -z "$SERVICE" ]; then usage "Service is not set!"; fi;
if [ -z "$VERSION" ]; then usage "Version is not set!"; fi;
if [ -z "$EXTRA" ]; then EXTRA=""; fi;

docker build $EXTRA services/$SERVICE -t codaprotocol/$SERVICE:$VERSION

if [ -z "$NOUPLOAD" ]; then docker push codaprotocol/$SERVICE:$VERSION; fi;
