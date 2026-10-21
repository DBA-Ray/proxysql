#!/usr/bin/env bash
# Offline regression checks; run with: bash tests/test_helpers.sh
set -euo pipefail

cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT

# Substitute fixture values only. These checks do not require Ansible or secrets.
sed -e 's/{{ alert_retry[^}]*}}/0/g' -e 's/{{ alert_timeout[^}]*}}/1/g' \
    -e 's/{{[^}]*}}/fixture/g' templates/notify.sh.j2 >"$test_dir/notify.sh"
sed -e "s|{{ backupdir[^}]*}}|$test_dir/backups|g" \
    -e "s|{{ eventslog_dir[^}]*}}|$test_dir/events|g" \
    -e "s|{{ backup_log_file[^}]*}}|$test_dir/backup.log|g" \
    -e 's/{{ digest_flush_wait[^}]*}}/0/g' \
    -e 's/{{ eventslog_keep_days[^}]*}}/7/g' \
    -e 's/{{ admin_query_timeout[^}]*}}/2/g' \
    -e 's/{{ backup_dump_timeout[^}]*}}/5/g' \
    -e 's/{{ eventslog_compress_threads[^}]*}}/1/g' \
    -e 's/{{[^}]*}}/fixture/g' \
    -e '\|^\[ -f /etc/profile \]|d' \
    -e '/^main "\$@"$/d' templates/backup.sh.j2 >"$test_dir/backup.sh"

for script in "$test_dir/notify.sh" "$test_dir/backup.sh"; do
    bash -n "$script"
done

(
    readonly MSG_TYPE=weixin
    source "$test_dir/notify.sh"
    ALERT_RETRY=0
    curl() { printf '%s' '{"errcode":0}'; }
    curl_post_json https://example.invalid '{}'
    [[ $(json_escape $'quote"\\\n\t') == 'quote\"\\\n\t' ]]
    [[ $(mobiles_to_json ' 123, 456 ') == '"123","456"' ]]
    # 首次网络失败后仍应重试；set -e 不能让公共库提前退出。
    ALERT_RETRY=1
    sleep() { :; }
    curl() {
        if [ ! -f "$test_dir/curl-retried" ]; then
            touch "$test_dir/curl-retried"; return 7
        fi
        printf '%s' '{"errcode":0}'
    }
    curl_post_json example.invalid '{}'
    curl() { printf '%s' '{"errcode":40013}'; }
    if curl_post_json https://example.invalid '{}'; then
        echo 'FAIL: API error accepted' >&2; exit 1
    fi
    curl() { printf '%s' '<html>upstream unavailable</html>'; }
    if curl_post_json https://example.invalid '{}'; then
        echo 'FAIL: invalid response accepted' >&2; exit 1
    fi
    curl() { return 22; }
    if curl_post_json https://example.invalid '{}'; then
        echo 'FAIL: HTTP error accepted' >&2; exit 1
    fi
    curl() {
        [[ " $* " == *' -fsS '* ]] || return 1
        printf '%s' '{"errcode":0}'
    }
    curl_post_json https://example.invalid '{}'
)

(
    source "$test_dir/backup.sh"
    # 测试中的 mysql 是 shell mock；生产环境由 coreutils timeout 执行真实命令。
    timeout() { shift 2; "$@"; }
    mysql() {
        if [[ " $* " == *' SELECT 1 '* ]]; then
            printf 'probe\n' >>"$test_dir/probes"
        elif [[ " $* " == *'SELECT variable_value'* ]]; then
            printf '0\n'
        else
            printf '%s\n' "$*" >>"$test_dir/backup-sql"
        fi
    }
    mysqldump() { printf '%s\n' '-- SQL fixture'; }
    mysql_admin -e 'SELECT 2'
    mysql_admin -e 'SELECT 3'
    mysqldump_admin -B main >/dev/null
    [[ $(wc -l <"$test_dir/probes") -eq 1 ]]
    backup
    grep -q 'digest_to_disk=0' "$test_dir/backup-sql"
    if grep -q 'SAVE ADMIN VARIABLES TO DISK' "$test_dir/backup-sql"; then
        echo 'FAIL: backup overwrites persisted admin settings' >&2; exit 1
    fi
    compgen -G "$test_dir/backups/fixture_*.sql" >/dev/null
    mv() { return 1; }
    if backup; then
        echo 'FAIL: failed rename reported as successful backup' >&2; exit 1
    fi
    compgen -G "$test_dir/backups/*.tmp" >/dev/null
    mkdir -p "$EVENTSLOG_DIR"
    touch "$EVENTSLOG_DIR/events_log.1" "$EVENTSLOG_DIR/events_log.2.zst" \
          "$EVENTSLOG_DIR/unrelated.txt"
    touch -t 202001010000 "$EVENTSLOG_DIR/"*
    purge_events_logs
    [[ -f "$EVENTSLOG_DIR/events_log.1" ]]
    [[ -f "$EVENTSLOG_DIR/unrelated.txt" ]]
    [[ ! -e "$EVENTSLOG_DIR/events_log.2.zst" ]]
)

# 失败的 dump 和空 dump 都不能发布为正式备份，也不能删除已有成功备份。
for failure in error empty; do
    (
        source "$test_dir/backup.sh"
        ADMIN_USE_LOGIN_PATH=no
        timeout() { shift 2; "$@"; }
        mysql() { printf '1\n'; }
        mysqldump() {
            [[ "$failure" == empty ]] && return 0
            printf 'partial dump\n'; return 1
        }
        if backup; then echo "FAIL: $failure dump accepted" >&2; exit 1; fi
        compgen -G "$test_dir/backups/fixture_*.sql" >/dev/null
    )
done

# 压缩模拟只验证调用顺序和文件保护：真正的 zstd 校验由生产命令执行。
(
    source "$test_dir/backup.sh"
    rm -f -- "$EVENTSLOG_DIR/"*
    printf 'old\n' >"$EVENTSLOG_DIR/events_log.1"
    printf 'active\n' >"$EVENTSLOG_DIR/events_log.2"
    touch -t 202001010000 "$EVENTSLOG_DIR/events_log.1"
    zstd() {
        [[ " $* " == *' -t '* ]] && return 0
        cp -- "$4" "$6"
    }
    compress_logs
    [[ -f "$EVENTSLOG_DIR/events_log.1.zst" && ! -f "$EVENTSLOG_DIR/events_log.1" ]]
    [[ -f "$EVENTSLOG_DIR/events_log.2" ]]
    purge_events_logs
    [[ ! -f "$EVENTSLOG_DIR/events_log.1.zst" ]]
    printf 'old\n' >"$EVENTSLOG_DIR/events_log.1"
    printf 'valid previous archive\n' >"$EVENTSLOG_DIR/events_log.1.zst"
    zstd() { return 1; }
    compress_logs
    [[ -f "$EVENTSLOG_DIR/events_log.1" ]]
    grep -q 'valid previous archive' "$EVENTSLOG_DIR/events_log.1.zst"
    zstd() {
        [[ " $* " == *' -t '* ]] && return 0
        cp -- "$4" "$6"
        printf 'still writing\n' >>"$4"
    }
    compress_logs
    [[ -f "$EVENTSLOG_DIR/events_log.1" ]]
    grep -q 'valid previous archive' "$EVENTSLOG_DIR/events_log.1.zst"
)

# GR 模拟返回生产 SQL 的六列观测值，记录是否执行了 UPDATE。
sed -e 's/{{ writer_hostgroup[^}]*}}/10/g' \
    -e 's/{{ reader_hostgroup[^}]*}}/30/g' \
    -e 's/{{ backup_writer_hostgroup[^}]*}}/20/g' \
    -e 's/{{ offline_hostgroup[^}]*}}/40/g' \
    -e "s|{{ auto_adjust_log_file[^}]*}}|$test_dir/gr.log|g" \
    -e "s|{{ auto_adjust_lock_file[^}]*}}|$test_dir/gr.lock|g" \
    -e 's/{{ admin_query_timeout[^}]*}}/2/g' \
    -e 's/{{[^}]*}}/fixture/g' \
    -e '/^main "\$@"$/d' templates/auto_adjust_mysql_query_rules.sh.j2 >"$test_dir/gr.sh"
bash -n "$test_dir/gr.sh"

gr_case() (
    local gr_fixture_row="$1" expected="$2" outcome="$3"
    source "$test_dir/gr.sh"
    rm -f "$test_dir/gr-update"
    mysql_admin() {
        if [[ "$*" == *'UPDATE mysql_group_replication_hostgroups'* ]]; then
            printf '%s' "$*" >"$test_dir/gr-update"
            [[ "$outcome" != update_failed ]] || return 1
            printf '%s\n' "$expected"
        else
            [[ "$outcome" != query_failed ]] || return 1
            printf '%s\n' "$gr_fixture_row"
        fi
    }
    if auto_adjust_mysql_query_rules; then
        [[ "$outcome" == success ]]
    else
        [[ "$outcome" != success ]]
    fi
    if [[ "$expected" == none ]]; then
        [[ ! -e "$test_dir/gr-update" ]]
    else
        grep -q "writer_is_also_reader=$expected" "$test_dir/gr-update"
        grep -q 'WHERE writer_hostgroup=10 AND reader_hostgroup=30' "$test_dir/gr-update"
        if grep -Eq 'UPDATE scheduler|SET active=0' "$test_dir/gr-update"; then
            echo 'FAIL: monitor disabled' >&2; exit 1
        fi
    fi
)

gr_case '0 1 4 2 1 1' 1 success            # 半数不可用，允许写节点读
gr_case '1 1 3 0 2 1' 0 success            # 副本恢复，读回到副本
gr_case '0 1 1 0 0 1' 1 success            # 只有主节点，避免空 reader 组
gr_case '0 1 3 0 2 1' none success         # 健康，无需写配置
gr_case '1 0 3 1 1 1' none success         # 人工关闭监控，保持不变
gr_case '2 1 3 0 2 1' none success         # 人工策略 2，保持不变
gr_case '0 1 3 3 0 0' none invalid         # 全离线，保留监控
gr_case '0 1 3 1 2 0' none invalid         # 无写节点，不修改配置
gr_case '' none invalid                    # 空结果不能作为 0
gr_case $'0 1 3 1 1 1\n0 1 3 1 1 1' none invalid
gr_case 'unexpected output' none invalid
gr_case '0 1 3 4 0 1' none invalid         # 离线数超过节点数
gr_case '' none query_failed
gr_case '0 1 4 2 1 1' 1 update_failed

# 锁冲突表示另一个任务正在执行；锁机制自身故障必须返回环境错误。
for status in 1 70; do
    (
        source "$test_dir/gr.sh"
        mysql() { :; }
        flock() { return "$status"; }
        auto_adjust_mysql_query_rules() { echo 'FAIL: lock ignored' >&2; exit 1; }
        if main; then rc=0; else rc=$?; fi
        if [[ "$status" == 1 ]]; then [[ "$rc" == 0 ]]; else [[ "$rc" == 2 ]]; fi
    )
done

echo 'PASS: backups, digest restoration, log protection, notifications, GR routing and locking'
