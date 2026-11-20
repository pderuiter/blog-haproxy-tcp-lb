# blog-haproxy-tcp-lb

Companion code for the blog post
[HAProxy TCP Load Balancing: A Complete Guide to Layer 4 Load Balancing](https://blog.bsdserver.nl/haproxy-tcp-load-balancing-a-complete-guide-to-layer-4-load-balancing/).

It builds the post's **Complete Production Example**: one HAProxy node in TCP mode in front of
a PostgreSQL cluster and Redis.

| Port | Frontend | Backend |
|------|----------|---------|
| 5432 | `pg_write` (rejects new connections above 5000) | `pg_primary`: the primary, a standby as `backup`; a `tcp-check` that only passes on `in_hot_standby` = `off` |
| 5433 | `pg_read` | `pg_replicas`: the standbys with `leastconn`, the primary as fallback |
| 6379 | `redis` | `redis_servers`: `balance first` and a `tcp-check` that only passes on `role:master` |
| 8404 | `stats` | stats page at `/stats`, Prometheus metrics at `/metrics` |

HAProxy comes from the official repositories, as in the post:

- **Ubuntu 24.04**: `ppa:vbernat/haproxy-3.3`. 3.3 is the newest branch built for 24.04. It is
  short-lived and not LTS.
- **Debian 13**: haproxy.debian.net `trixie-backports-3.4` (3.4 LTS).
- **RHEL 9 and compatibles**: AppStream (2.8). The role adds a systemd drop-in with
  `RuntimeDirectory=haproxy`, because the RHEL unit does not create `/run/haproxy` for the
  admin socket.

## Requirements

- Terraform >= 1.6 and a Proxmox VE API token, if you want Terraform to create the VM.
- ansible-core >= 2.15 on your workstation.
- PostgreSQL and Redis servers that HAProxy can reach.
  - The defaults are the post's addresses: `192.168.1.10-12` and `192.168.1.20-22`.
  - PostgreSQL 14 or newer: the primary check reads the `in_hot_standby` parameter that the
    server reports after login. A standby reports `on` and gets no writes; after a failover the
    promoted standby passes and takes over. Stop the old primary before you promote.
  - The checks connect as user `haproxy` to database `postgres`. The primary check must log in,
    so create the role without privileges and trust it from the HAProxy address only:

    ```sql
    CREATE ROLE haproxy LOGIN;
    ```

    ```text
    # pg_hba.conf, above the other host lines (10.0.0.10 = HAProxy)
    host  postgres  haproxy  10.0.0.10/32  trust
    ```

## Quick start

```bash
# 1. VM (optional: any Ubuntu 24.04, Debian 13 or RHEL 9 host works)
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in your values
terraform init && terraform apply
terraform output -raw ansible_inventory > ../ansible/inventory.yml

# 2. HAProxy
cd ../ansible
ansible-galaxy collection install -r requirements.yml
$EDITOR group_vars/all/vars.yml                 # your PostgreSQL and Redis servers
ansible-playbook site.yml

# 3. The post's checks
ansible-playbook ../tests/verify.yml
psql -h 10.0.0.10 -p 5432 -U postgres -c 'select inet_server_addr()'   # the primary
psql -h 10.0.0.10 -p 5433 -U postgres -c 'select inet_server_addr()'   # a standby
redis-cli -h 10.0.0.10 info replication | grep role                    # role:master
```

Without Terraform, copy `ansible/inventory.example.yml` to `ansible/inventory.yml` and set
your host.

## Variables

All variables are in `ansible/roles/haproxy_tcp_lb/defaults/main.yml`. The most important ones:

| Variable | Default | Meaning |
|----------|---------|---------|
| `haproxy_install_version` | `3.3` (Ubuntu), `3.4` (Debian) | HAProxy branch from the official repository |
| `haproxy_tcp_lb_pg_primary_servers` | post's primary + standby1 (backup) | `pg_primary` servers: `name`, `address`, `port`, optional `backup` |
| `haproxy_tcp_lb_pg_replica_servers` | standby1, standby2, primary (backup) | `pg_replicas` servers |
| `haproxy_tcp_lb_redis_servers` | redis1..3 | Redis servers; only the master passes the check |
| `haproxy_tcp_lb_pgsql_check_user` | `haproxy` | check user (`pgsql-check` and the primary check) |
| `haproxy_tcp_lb_pg_check_database` | `postgres` | database the primary check logs in to |
| `haproxy_tcp_lb_nbthread` / `haproxy_tcp_lb_cpu_map` | `4` / `auto:1/1-4 0-3` | threads and CPU pinning |

There are no secrets. `group_vars/all/vault.yml.example` only exists so all companion repos have
the same layout.

## How it was tested

- `tests/lab.sh` starts the setup on one Docker host:
  - systemd containers act as the VMs;
  - `postgres:17-alpine` (a primary and two streaming standbys) and `redis:7-alpine` run on the
    post's addresses.
- It then runs `site.yml` twice (the second run reports `changed=0`), `tests/verify.yml`, and
  writes through port 5432 and reads through 5433.
- `tests/lab.sh failover` stops the primary and promotes a standby: writes are refused until the
  promotion, then reach the new primary.
- Tested with Ubuntu 24.04 (HAProxy 3.3.17), Debian 13 (3.4.7) and AlmaLinux 9 (2.8.14).
- CI (`.gitlab-ci.yml`) runs yamllint, ansible-lint (production profile), `terraform fmt`,
  `validate` and tflint.

## License

MIT
