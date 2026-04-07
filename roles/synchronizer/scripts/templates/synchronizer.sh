#!/bin/bash
# Шаблон уведомлений: Синхронизатор (R8)
# Вызывается из notify.sh через source

LOG_DIR="{{HOME_DIR}}/logs/synchronizer"
DATE=$(date +%Y-%m-%d)
STRATEGY_DIR="{{WORKSPACE_DIR}}/DS-strategy"
if [[ "$STRATEGY_DIR" == *"{{WORKSPACE_DIR}}"* ]]; then
    STRATEGY_DIR="$HOME/Github/DS-strategy"
fi

AGENT_WORKSPACE_DIR="{{WORKSPACE_DIR}}/DS-agent-workspace"
if [[ "$AGENT_WORKSPACE_DIR" == *"{{WORKSPACE_DIR}}"* ]]; then
    AGENT_WORKSPACE_DIR="$HOME/Github/DS-agent-workspace"
fi

build_message() {
    local scenario="$1"
    local report_file_agent="$AGENT_WORKSPACE_DIR/scheduler/reports/SchedulerReport $DATE.md"
    local report_file_strategy="$STRATEGY_DIR/current/SchedulerReport $DATE.md"
    local active_report_file=""

    if [ -f "$report_file_agent" ]; then
        active_report_file="$report_file_agent"
    elif [ -f "$report_file_strategy" ]; then
        active_report_file="$report_file_strategy"
    fi

    case "$scenario" in
        "daily-report")
            if [ -z "$active_report_file" ]; then
                echo ""
                return
            fi

            local week
            week=$(grep '^week:' "$active_report_file" | head -1 | awk '{print $2}')

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

        "daily-telegram-report")
            local status_file="$STRATEGY_DIR/current/AGENTS-STATUS.md"
            local session_open="$STRATEGY_DIR/current/SESSION-OPEN (Экран открытия сессии).md"
            local runtime_mode="$STRATEGY_DIR/current/RUNTIME-MODE.md"
            local wp_file
            wp_file=$(ls -t "$STRATEGY_DIR"/current/WeekPlan\ *.md 2>/dev/null | head -1)
            local hired=0

            if [ -d "$AGENT_WORKSPACE_DIR/agency/agents" ]; then
                hired=$(ls "$AGENT_WORKSPACE_DIR/agency/agents/" 2>/dev/null | wc -l | tr -d ' ')
            fi

            printf "<b>📊 Ежедневный отчёт экзокортекса</b>\n\n"

            if [ -f "$session_open" ]; then
                local verdict
                verdict=$(grep -m1 "Итоговый verdict:" "$session_open" | sed 's/^- //' | sed 's/\*\*//g')
                if [ -n "$verdict" ]; then
                    printf "<b>Состояние мозга:</b>\n• %s\n\n" "$verdict"
                fi
            fi

            if [ -f "$status_file" ]; then
                local status_lines
                status_lines=$(awk '
                    /^- / && /Мозг экзокортекса:|Планировщик:|Проверка среды:|Runtime arbiter:|Стратег:|Экстрактор:/ {
                        print "• " substr($0, 3)
                    }
                ' "$status_file" | head -8)
                if [ -n "$status_lines" ]; then
                    printf "<b>Статус агентов:</b>\n%s\n\n" "$status_lines"
                fi
            fi

            if [ -f "$runtime_mode" ]; then
                local provider_line local_line cloud_line
                provider_line=$(grep -m1 "Primary provider:" "$runtime_mode" | sed 's/^- /• /' | sed 's/`//g')
                local_line=$(grep -m1 "Local control plane:" "$runtime_mode" | sed 's/^- /• /' | sed 's/`//g')
                cloud_line=$(grep -m1 "Cloud RAG status:" "$runtime_mode" | sed 's/^- /• /' | sed 's/`//g')
                if [ -n "$provider_line" ] || [ -n "$local_line" ] || [ -n "$cloud_line" ]; then
                    printf "<b>Runtime mode:</b>\n"
                    [ -n "$provider_line" ] && printf "%s\n" "$provider_line"
                    [ -n "$local_line" ] && printf "%s\n" "$local_line"
                    [ -n "$cloud_line" ] && printf "%s\n" "$cloud_line"
                    printf "\n"
                fi
            fi

            if [ -f "$session_open" ]; then
                local attention_lines
                attention_lines=$(awk '
                    /^## Что требует внимания/ {flag=1; next}
                    /^## / && flag {exit}
                    flag && /^- / {print "• " substr($0, 3)}
                ' "$session_open" | head -5)
                if [ -n "$attention_lines" ]; then
                    printf "<b>Что требует внимания:</b>\n%s\n\n" "$attention_lines"
                fi
            fi

            if [ -n "$wp_file" ] && [ -f "$wp_file" ]; then
                local wp_count
                wp_count=$(grep "in_progress\|pending" "$wp_file" | wc -l | tr -d ' ')
                printf "<b>Рабочие продукты:</b>\n• В работе: %s\n\n" "$wp_count"
            fi

            printf "<b>Нанятые агенты:</b>\n• Из агентства: %s\n\n" "$hired"
            printf "⏰ Время: %s" "$(date '+%H:%M')"
            ;;

        "unprocessed-notes-check")
            local report_file="$STRATEGY_DIR/current/UNPROCESSED-NOTES-REPORT.md"

            if [ ! -f "$report_file" ]; then
                echo ""
                return
            fi

            local red_count yellow_count green_count
            red_count=$(grep '🔴 Требует внимания' "$report_file" | awk -F'|' '{print $3}' | xargs 2>/dev/null || echo "0")
            yellow_count=$(grep '🟡 В работе' "$report_file" | awk -F'|' '{print $3}' | xargs 2>/dev/null || echo "0")
            green_count=$(grep '🟢 Обработано' "$report_file" | awk -F'|' '{print $3}' | xargs 2>/dev/null || echo "0")

            printf "<b>🔴 Необработанные заметки</b>\n\n"
            printf "Найдено %s заметок старше 3 дней в Obsidian.\n\n" "$red_count"
            printf "<b>Статистика:</b>\n"
            printf "• 🟢 Обработано: %s\n" "${green_count:-0}"
            printf "• 🟡 В работе: %s\n" "${yellow_count:-0}"
            printf "• 🔴 Требует внимания: %s\n\n" "${red_count:-0}"
            printf "Действие: проверить и распределить вручную."
            ;;

        "health-check")
            if [ -n "${NOTIFY_TEXT:-}" ]; then
                printf "%s" "${NOTIFY_TEXT}"
            elif [ -n "${NOTIFY_TEXT_FILE:-}" ] && [ -f "${NOTIFY_TEXT_FILE}" ]; then
                cat "${NOTIFY_TEXT_FILE}"
            else
                echo ""
            fi
            ;;

        "token-report")
            if [ -n "${NOTIFY_TEXT:-}" ]; then
                printf "%s" "${NOTIFY_TEXT}"
            elif [ -n "${NOTIFY_TEXT_FILE:-}" ] && [ -f "${NOTIFY_TEXT_FILE}" ]; then
                cat "${NOTIFY_TEXT_FILE}"
            else
                echo ""
            fi
            ;;

        "day-close")
            local session_context="$HOME/Github/DS-strategy/current/SESSION-CONTEXT.md"
            local session_open="$HOME/Github/DS-strategy/current/SESSION-OPEN (Экран открытия сессии).md"
            local agents_status="$HOME/Github/DS-strategy/current/AGENTS-STATUS.md"
            local scheduler_report=""
            local latest_dayplan
            latest_dayplan=$(ls -t "$STRATEGY_DIR"/current/DayPlan\ *.md 2>/dev/null | head -1)
            scheduler_report=$(ls -t "$HOME/Github/DS-agent-workspace"/scheduler/reports/SchedulerReport\ *.md 2>/dev/null | head -1)

            if [ ! -f "$session_context" ]; then
                echo ""
                return
            fi

            printf "<b>🔒 Закрытие дня %s</b>\n\n" "$(date +%d.%m)"

            if [ -f "$session_open" ]; then
                local verdict_line
                verdict_line=$(grep -m1 "Итоговый verdict:" "$session_open" | sed 's/^- //')
                local attention_lines
                attention_lines=$(awk '
                    /^## Что требует внимания/ {flag=1; next}
                    /^## / && flag {exit}
                    flag && /^- / {print}
                ' "$session_open" | head -3 | sed 's/^- /• /')

                printf "<b>🧠 Состояние экзокортекса:</b>\n"
                if [ -n "$verdict_line" ]; then
                    printf "• %s\n" "$verdict_line"
                fi
                if [ -n "$attention_lines" ]; then
                    printf "%s\n" "$attention_lines"
                fi
                printf "\n"
            fi

            if [ -f "$scheduler_report" ] || [ -f "$agents_status" ]; then
                local worked_lines=""
                if [ -f "$scheduler_report" ]; then
                    worked_lines=$(awk -F'|' '
                        /^\| [0-9]+ \|/ {
                            task=$3; status=$4;
                            gsub(/^ +| +$/, "", task);
                            gsub(/\*\*/, "", status);
                            gsub(/^ +| +$/, "", status);
                            if (task != "" && status != "") {
                                print "• " task ": " status
                            }
                        }
                    ' "$scheduler_report" | head -4)
                fi
                if [ -z "$worked_lines" ] && [ -f "$agents_status" ]; then
                    worked_lines=$(awk '
                        /^## Задачи/ {flag=1; next}
                        /^## / && flag {exit}
                        flag && /^- / {print}
                    ' "$agents_status" | head -4 | sed 's/^- /• /')
                fi
                if [ -n "$worked_lines" ]; then
                    printf "<b>🤖 Какие агенты отработали:</b>\n%s\n\n" "$worked_lines"
                fi
            fi

            local today_tasks
            today_tasks=$(awk "/## Что сделано сегодня \($DATE\)/,/^---$/" "$session_context" | grep "^- ✅" | head -5 | sed 's/^- ✅ \[.*\] /• /' | sed 's/^- ✅/• /')

            if [ -n "$today_tasks" ]; then
                printf "<b>✅ Что сделано:</b>\n%s\n\n" "$today_tasks"
            fi

            if [ -n "$latest_dayplan" ] && [ -f "$latest_dayplan" ]; then
                local in_progress
                in_progress=$(awk '
                    /^## РП в работе/ {flag=1; next}
                    /^## / && flag {exit}
                    flag && /^- / {print}
                ' "$latest_dayplan" | head -3 | sed 's/^- /• /')

                if [ -z "$in_progress" ]; then
                    in_progress=$(awk -F'|' '
                        /^\| [0-9]+ \|/ {
                            wp=$3; status=$7;
                            gsub(/^ +| +$/, "", wp);
                            gsub(/^ +| +$/, "", status);
                            if (status != "done" && wp != "") {
                                print "• " wp
                            }
                        }
                    ' "$latest_dayplan" | head -3)
                fi

                if [ -n "$in_progress" ]; then
                    printf "<b>🔄 Что в работе:</b>\n%s\n\n" "$in_progress"
                fi

                local tomorrow_tasks
                tomorrow_tasks=$(awk -F'|' '
                    /^## План на сегодня/ {in_plan=1; next}
                    /^## / && in_plan {exit}
                    in_plan && /^\| [0-9]+ \|/ {
                        wp=$3; prio=$5; status=$7;
                        gsub(/^ +| +$/, "", wp);
                        gsub(/^ +| +$/, "", prio);
                        gsub(/^ +| +$/, "", status);
                        if (status != "done" && wp != "") {
                            print "• " wp " (" prio ")"
                        }
                    }
                ' "$latest_dayplan" | head -3)

                if [ -n "$tomorrow_tasks" ]; then
                    printf "<b>🎯 Приоритеты на завтра:</b>\n%s\n" "$tomorrow_tasks"
                fi
            fi
            ;;

        *)
            echo ""
            ;;
    esac
}

build_buttons() {
    echo '[]'
}
