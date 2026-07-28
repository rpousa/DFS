#!/bin/bash
# docker run --name <name of container to run> <image>
# ex:  docker run --name mysql mysql:comnetsemu /bin/bash

build_image() {
  local image=$1
  local dockerfile=$2
  local no_cache=$3

  if [ "$no_cache" == "--no-cache" ]; then
    docker build -t "$image" --file "$dockerfile" --no-cache --network=host --build-arg APT_FORCE_IPV4=true .
  else
    docker build -qt "$image" --file "$dockerfile" --network=host --build-arg APT_FORCE_IPV4=true .
  fi
}
# old images not needed spgwu ryu flexric flexric_oai flexric_srs
IMAGES=(ext_dn mysql amf smf nrf ausf udm udr upf nssf pcf gnb ue cu du cuup cucp onos proxy_l2 comnetsemu_flexric) # comnetsemu_flexric
DOCKERFILE_DIR=./dockerfiles

# ---- defaults ----
NO_CACHE=""
MODE="default"

# ---- parse args ----
for arg in "$@"; do
  case $arg in
    --no-cache)
      NO_CACHE="--no-cache"
      ;;
    core)
      MODE="core"
      ;;
    full)
      MODE="full"
      ;;
    edge)
      MODE="edeg"
      ;;
    co)
      MODE="centraloffice"
      ;;
    *)
      echo "Unknown option: $arg"
      ;;
  esac
done

# ---- define image sets ----
if [ "$MODE" == "core" ]; then
  IMAGES=(ext_dn mysql amf smf nrf ausf udm udr upf nssf pcf cucp cu gnb comnetsemu_flexric)
elif [ "$MODE" == "edge" ]; then
  IMAGES=(ext_dn upf  gnb ue cu du cuup )
elif [ "$MODE" == "centraloffice" ]; then
  IMAGES=(ext_dn gnb cu du cuup cucp onos comnetsemu_flexric)
elif [ "$MODE" == "full" ]; then
  IMAGES=(ext_dn mysql amf smf nrf ausf udm udr upf nssf pcf gnb ue cu du cuup cucp onos proxy_l2 comnetsemu_flexric)
else
  # default (could be same as full or something smaller)
  IMAGES=(mysql amf smf upf)
fi


for image in "${IMAGES[@]}"; do
  build_image "$image":comnetsemu "$DOCKERFILE_DIR/Dockerfile.$image" "$NO_CACHE"
  echo "$image"
done

# echo "Building the MYSQL docker image."
# docker build -t mysql:comnetsemu --file ./dockerfiles/Dockerfile.mysql --no-cache .
# docker build -t flexric_test:comnetsemu --file ./dockerfiles/Dockerfile.flexric_test --no-cache .
# docker build -t ryu:comnetsemu --file ./dockerfiles/Dockerfile.ryu .
# docker build -t onos:comnetsemu --file ./dockerfiles/Dockerfile.onos .
# docker build -t proxy_l2:comnetsemu --file ./dockerfiles/Dockerfile.proxy_l2 .

build_image upf_1:comnetsemu "$DOCKERFILE_DIR/Dockerfile_1.upf" "$1"
build_image upf_2:comnetsemu "$DOCKERFILE_DIR/Dockerfile_2.upf" "$1"

docker system prune
docker container prune
docker image prune --force