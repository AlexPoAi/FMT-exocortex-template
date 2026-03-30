#!/bin/bash
# Шаблон уведомлений: Синхронизатор (R8)
# Вызывается из notify.sh через source

LOG_DIR="{{HOME_DIR}}/logs/synchronizer"
DATE=$(date +%Y-%m-%d)

build_message() {
    local scenario="$1"

    case "$scenario" in
        "daily-report")
            local report_file="/Users/alexander/Github/DS-strategy/current/SchedulerReport $DATE.md"

            if [ ! -f "$report_file" ]; then
                echo ""
                return
            fi

            local week
            week=$(grep '^week:' "$report_file" | head -1 | awk '{print $2}')

            printf "<b>📊 Ежедневный отчёт</b>\n\n"
            printf "📅 %s (%s)\n\n" "$DATE" "$week"
            printf "Отчёт создан, агенты проверены."
            ;;

        "code-scan")
            local log_file="$LOG_DIR/code-scan-$DATE.log"

            if [ ! -f "$log_file" ]; then
                echo ""
                return
            fi

            local latest_run
            latest_run=$(awk '/=== Code Scan Started ===/{buf=""} {buf=buf"\n"$0} END{print buf}' "$log_file" 2>/dev/null)

            local found
            found=$(echo "$latest_run" | grep -c 'FOUND:' 2>/dev/null || echo "0")
            local skipped
            skipped=$(echo "$latest_run" | grep -c 'SKIP:' 2>/dev/null || echo "0")

            local repo_list
            repo_list=$(echo "$latest_run" | grep 'FOUND:' 2>/dev/null | sed 's/.*FOUND: /  /' || echo "")

            printf "<b>🔄 Code Scan</b>\n\n"
            printf "📅 %s\n\n" "$DATE"
            printf "Репо с коммитами: %s\n" "$found"
            printf "Без изменений: %s\n\n" "$skipped"

            if [ "$found" -gt 0 ]; then
                printf "<b>Репо:</b>\n%s" "$repo_list"
            fi
            ;;

        "day-close")
            local session_context="$HOME/Github/DS-strategy/current/SESSION-CONTEXT.md"
            local report_file="$HOME/Github/DS-strategy/current/SchedulerReport $DATE.md"

            if [ ! -f "$session_context" ]; then
                echo ""
                return
            fi

            printf "<b>🔒 Закрытие дня %s</b>\n\n" "$(date +%d.%m)"

            # Что сделано сегодня
            local today_tasks
            today_tasks=$(awk "/## Что сделано сегодня \($DATE\)/,/^---$/" "$session_context" | grep "^- ✅" | head -5 | sed 's/^- ✅ \[.*\] /• /' | sed 's/^- ✅/• /')

            if [ -n "$today_tasks" ]; then
                printf "<b>✅ Что сделано:</b>\n%s\n\n" "$today_tasks"
            fi

            # Статус системы
            if [ -f "$report_file" ]; then
                local status_line
                status_line=$(grep -E "^## (🟢|🟡|🔴)" "$report_file" | head -1)
                printf "<b>%s</b>\n\n" "$status_line"
            fi

            printf "День закрыт. Все изменения сохранены.\n"
            ;;

        *)
            echo ""
            ;;
    esac
}

build_buttons() {
    echo '[]'
}
