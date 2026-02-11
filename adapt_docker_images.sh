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
IMAGES=(ext_dn mysql amf smf nrf gnb ue ausf udm udr upf cu du nssf cuup cucp pcf onos proxy_l2 comnetsemu_flexric) # flexric_test
DOCKERFILE_DIR=./dockerfiles

for image in "${IMAGES[@]}"; do
  build_image "$image":comnetsemu "$DOCKERFILE_DIR/Dockerfile.$image" "$1"
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