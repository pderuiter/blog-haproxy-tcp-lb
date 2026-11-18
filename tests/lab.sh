#!/bin/bash
# How the repo was tested: Docker on one host, systemd containers as the "VMs".
# Backends use the post's addresses on a 192.168.1.0/24 Docker network:
#   pg1..pg3 (postgres:17-alpine) at .10-.12, redis1 (master) and redis2/3 (replicas) at .20-.22.
# Usage: tests/lab.sh up | run | down
set -u
P=${LAB_PREFIX:-lab}-tcp; NET=$P
case "${1:-}" in
up)
  docker network create --subnet 192.168.1.0/24 $NET >/dev/null
  for i in 0 1 2; do
    docker run -d --name $P-pg$((i+1)) --network $NET --ip 192.168.1.1$i -e POSTGRES_PASSWORD=lab postgres:17-alpine >/dev/null
  done
  docker run -d --name $P-redis1 --network $NET --ip 192.168.1.20 redis:7-alpine >/dev/null
  for i in 1 2; do
    docker run -d --name $P-redis$((i+1)) --network $NET --ip 192.168.1.2$i redis:7-alpine redis-server --replicaof 192.168.1.20 6379 >/dev/null
  done
  docker run -d --name $P-lb --hostname haproxy1 --network $NET --ip 192.168.1.5 --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock jrei/systemd-ubuntu:24.04 >/dev/null
  sleep 3
  # what the Ubuntu cloud image already has
  docker exec $P-lb bash -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 sudo ca-certificates gnupg iproute2 >/dev/null'
  printf 'all:\n  children:\n    haproxy:\n      hosts:\n        %s:\n          ansible_connection: community.docker.docker\n' $P-lb > lab-inventory.yml
  ;;
run)
  cd ansible || exit 1
  for run in 1 2; do ansible-playbook -i ../lab-inventory.yml site.yml | sed -n '/PLAY RECAP/,$p'; done
  ansible-playbook -i ../lab-inventory.yml ../tests/verify.yml | sed -n '/PLAY RECAP/,$p'
  ;;
down)
  docker rm -f $P-lb $P-pg1 $P-pg2 $P-pg3 $P-redis1 $P-redis2 $P-redis3 >/dev/null
  docker network rm $NET >/dev/null; rm -f lab-inventory.yml
  ;;
*) echo "usage: $0 up|run|down"; exit 1 ;;
esac
