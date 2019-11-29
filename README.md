Proxysql_Ray
=========

Automatically deploy the latest version of proxysql based on local installation files.

Requirements
------------

Because downloading from the yum source is slow,so need to download the latest version of the installation package and place it in the files directory.

Role Variables
--------------


is_update: True
package_dir: /opt/
proxysql_package: proxysql-2.0.8-1-centos7.x86_64.rpm
source_file: /opt/{{ proxysql_package }}
db_file: /var/lib/proxysql/proxysql.db
admin_web_enabled: 'true'
admin_mysql_ifaces: '0.0.0.0:6032'
mysql_interfaces: '0.0.0.0:3399'
mysql_shun_recovery_time_sec: 7
mysql_threads: 16
mysql_query_digests_lowercase: 'true'
mysql_query_cache_size_MB: 1024
mysql_threshold_resultset_size : 209715200
mysql_monitor_username: 'repl'
mysql_monitor_connect_interval: 2000
mysql_monitor_ping_interval: 2000
mysql_monitor_read_only_interval: 2000
mysql_default_charset: 'utf8mb4'
mysql_max_connections: 30000
mysql_server_version: '8.0.18'
mysql_max_allowed_packet: 1072693248
mysql_default_sql_mode: 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION'
mysql_port: 3377
max_connections: 10000
proxysql_group_replication_hostgroups: True
writer_hostgroup: 10
backup_writer_hostgroup: 20
reader_hostgroup: 30
offline_hostgroup: 40
group_replication_active: 1
writer_is_also_reader: 0
max_transactions_behind: 3
business_user: dxz
cache_ttl: 50
navicat_query_rule: True
rule_id: 1
active: 1
match_digest: '^set'
multiplex: 1

Dependencies
------------

None.

Example Playbook
----------------


- hosts: proxysql
  gather_facts: False
  remote_user: root
  roles:
    - proxysql_ray


License
-------

GNU General Public License v3.0

Author Information
------------------

I am DBA Ray.
