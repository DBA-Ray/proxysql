Proxysql_Ray
=========

Automatically deploy the latest version of proxysql based on local installation files.

Requirements
------------

Because downloading from the yum source is slow,so need to download the latest version of the installation package and place it in the files directory.

Role Variables
--------------

For all variables, take a look at defaults/main.yml.

详细的中文配置说明、稳定性策略、升级恢复步骤及验证方法见
[运维说明](docs/operations.md)。控制端依赖可通过
`ansible-galaxy collection install -r requirements.yml` 安装。

Dependencies
------------

None.

Local validation
----------------

Run `bash tests/test_helpers.sh` to check backup authentication reuse, backup
success and failure, event log retention, and notification error handling. The
checks use temporary files and mocked commands; they do not contact servers or
webhooks. Full deployment validation requires Ansible and a Linux target host.

Example Playbook
----------------

None.

License
-------

GNU General Public License v3.0

Author Information
------------------

I am DBA Ray.
