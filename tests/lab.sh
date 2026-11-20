#!/bin/bash
# How the repo was tested: Docker on one host, systemd containers as the "VMs".
# Backends use the post's addresses on a 192.168.1.0/24 Docker network (LAB_NET=10.99.1 picks
# another /24 if that one is taken; the lab inventory points the server lists at it):
#   pg1 (primary) at .10, pg2/pg3 (streaming standbys of pg1) at .11-.12 (postgres:17-alpine),
#   redis1 (master) and redis2/3 (replicas) at .20-.22.
# Usage: tests/lab.sh up | run | failover | down
#   failover: stops the primary, promotes pg2 and shows that pg_write follows it.
set -u
P=${LAB_PREFIX:-lab}-tcp; NET=$P
N=${LAB_NET:-192.168.1}
PG=postgres:17-alpine
LB_IP=$N.5

psql_lb() { # psql_lb <port> <sql>: run SQL through HAProxy
  docker run --rm --network $NET -e PGPASSWORD=lab $PG psql -h $LB_IP -p "$1" -U postgres -Atc "$2"
}

pg1_ready() {
  for _ in $(seq 60); do docker exec $P-pg1 pg_isready -h 127.0.0.1 -q 2>/dev/null && return 0; sleep 1; done
  echo "pg1 not ready" >&2; exit 1
}

case "${1:-}" in
up)
  docker network create --subnet $N.0/24 $NET >/dev/null || exit 1
  # Primary: a replication user, and the "haproxy" check user (trust, no privileges).
  docker run -d --name $P-pg1 --network $NET --ip $N.10 -e POSTGRES_PASSWORD=lab $PG -c wal_keep_size=256MB >/dev/null
  pg1_ready; sleep 3; pg1_ready # the entrypoint restarts the server once after initdb
  docker exec -u postgres $P-pg1 psql -qc "CREATE ROLE repl LOGIN REPLICATION PASSWORD 'lab'" \
    -c "CREATE ROLE haproxy LOGIN"
  docker exec -u postgres $P-pg1 sh -c "sed -i '1i host postgres haproxy $LB_IP/32 trust\nhost replication repl $N.0/24 scram-sha-256' \"\$PGDATA/pg_hba.conf\" && pg_ctl reload -D \"\$PGDATA\" >/dev/null"
  # Standbys: pg_basebackup -R writes standby.signal and primary_conninfo.
  for i in 2 3; do
    docker run -d --name $P-pg$i --network $NET --ip $N.1$((i-1)) -u postgres -e PGPASSWORD=lab \
      --entrypoint sh $PG -c "pg_basebackup -h $N.10 -U repl -D \"\$PGDATA\" -R -X stream && chmod 700 \"\$PGDATA\" && exec postgres" >/dev/null
  done
  docker run -d --name $P-redis1 --network $NET --ip $N.20 redis:7-alpine >/dev/null
  for i in 1 2; do
    docker run -d --name $P-redis$((i+1)) --network $NET --ip $N.2$i redis:7-alpine redis-server --replicaof $N.20 6379 >/dev/null
  done
  docker run -d --name $P-lb --hostname haproxy1 --network $NET --ip $LB_IP --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock jrei/systemd-ubuntu:24.04 >/dev/null
  sleep 3
  # what the Ubuntu cloud image already has
  docker exec $P-lb bash -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 sudo ca-certificates gnupg iproute2 >/dev/null'
  cat > lab-inventory.yml <<EOF
all:
  children:
    haproxy:
      hosts:
        $P-lb:
          ansible_connection: community.docker.docker
      vars:
        haproxy_tcp_lb_pg_primary_servers:
          - {name: pg-primary, address: $N.10, port: 5432}
          - {name: pg-standby1, address: $N.11, port: 5432, backup: true}
        haproxy_tcp_lb_pg_replica_servers:
          - {name: pg-standby1, address: $N.11, port: 5432}
          - {name: pg-standby2, address: $N.12, port: 5432}
          - {name: pg-primary, address: $N.10, port: 5432, backup: true, comment: Fallback}
        haproxy_tcp_lb_redis_servers:
          - {name: redis1, address: $N.20, port: 6379}
          - {name: redis2, address: $N.21, port: 6379}
          - {name: redis3, address: $N.22, port: 6379}
EOF
  ;;
run)
  cd ansible || exit 1
  for run in 1 2; do ansible-playbook -i ../lab-inventory.yml site.yml | sed -n '/PLAY RECAP/,$p'; done
  ansible-playbook -i ../lab-inventory.yml ../tests/verify.yml | sed -n '/PLAY RECAP/,$p'
  # Writes through pg_write (5432) must reach the primary; pg_read (5433) a standby.
  psql_lb 5432 "CREATE TABLE IF NOT EXISTS t (n int); INSERT INTO t VALUES (1); SELECT 'write ok on ' || inet_server_addr()"
  psql_lb 5433 "SELECT 'read on ' || inet_server_addr() || ', in recovery: ' || pg_is_in_recovery()"
  ;;
failover)
  docker stop $P-pg1 >/dev/null
  sleep 20 # fall 3 x (inter 3s + timeout check 3s), plus margin
  echo "primary stopped, pg2 not promoted yet:"
  docker exec $P-lb bash -c 'echo "show stat" | socat stdio /run/haproxy/admin.sock | cut -d, -f1,2,18 | grep ^pg_primary'
  psql_lb 5432 "INSERT INTO t VALUES (2); SELECT 'write ok on ' || inet_server_addr()"
  docker exec -u postgres $P-pg2 pg_ctl promote -D /var/lib/postgresql/data >/dev/null
  sleep 9 # rise 2 x inter 3s, plus margin
  echo "pg2 promoted:"
  docker exec $P-lb bash -c 'echo "show stat" | socat stdio /run/haproxy/admin.sock | cut -d, -f1,2,18 | grep ^pg_primary'
  psql_lb 5432 "INSERT INTO t VALUES (3); SELECT 'write ok on ' || inet_server_addr()"
  ;;
down)
  docker rm -fv $P-lb $P-pg1 $P-pg2 $P-pg3 $P-redis1 $P-redis2 $P-redis3 >/dev/null
  docker network rm $NET >/dev/null; rm -f lab-inventory.yml
  ;;
*) echo "usage: $0 up|run|failover|down"; exit 1 ;;
esac
