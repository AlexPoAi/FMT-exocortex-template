# Визуальные схемы IWE для новичков

> Схемы в формате Mermaid. Рендерятся в GitHub, VS Code (с расширением Mermaid), и большинстве Markdown-редакторов.

---

## Схема 1. Карта компонентов IWE

> Ты в центре. Принципы — общий фундамент для тебя и ИИ. Знания создаёшь ты — и они обогащают обоих.

```mermaid
graph TB
    subgraph principles["<b>ПРИНЦИПЫ</b>"]
        direction LR
        ZP["<b>Нулевые (ZP)</b><br/>Базовые правила<br/>мышления"]
        FPF["<b>Первые (FPF)</b><br/>Фреймворк<br/>корректности"]
        ZP --> FPF
    end

    subgraph pair["<b>ПАРА: ТЫ + ИИ</b>"]
        direction LR
        USER["<b>Ты</b><br/>Принимаешь решения<br/>Мыслишь, направляешь<br/>Создаёшь знания"]
        AI["<b>Claude Code</b><br/>Усиливает, структурирует<br/>Берёт рутину<br/>Использует твои знания"]
        USER <-->|"сотрудничество"| AI
    end

    subgraph knowledge["<b>ЗНАНИЯ</b>"]
        direction LR
        EXO["<b>Экзокортекс</b><br/>Вторая память:<br/>планы, контекст, выводы"]
        PACK["<b>Pack</b><br/>Вторые принципы:<br/>твои доменные знания"]
    end

    subgraph practice["<b>ПРАКТИКА</b>"]
        direction LR
        TOOLS["<b>VS Code + GitHub</b><br/>Редактор + хранилище"]
        BOT["<b>Бот @aist_me_bot</b><br/>Помощник<br/>в Telegram"]
        ORZ["<b>Ритуалы ОРЗ</b><br/>Открытие → Работа<br/>→ Закрытие"]
    end

    principles -->|"формируют мышление"| USER
    principles -->|"встроены в правила"| AI
    USER -->|"создаёт"| PACK
    AI -->|"структурирует"| EXO
    PACK -->|"обогащает"| AI
    EXO -->|"контекст для"| ORZ
    PACK -->|"знания для"| BOT
    knowledge --> practice

    style principles fill:#fce4ec,stroke:#e53935,stroke-width:2px
    style pair fill:#f3e5f5,stroke:#8e24aa,stroke-width:2px
    style knowledge fill:#fff3e0,stroke:#fb8c00,stroke-width:2px
    style practice fill:#e8f5e9,stroke:#43a047,stroke-width:2px
```

---

## Схема 2. Путь пользователя: от нуля до рабочего IWE

> Пять шагов. Каждый — конкретный результат.

```mermaid
graph LR
    S1["<b>Шаг 1</b><br/>Пойми зачем<br/><i>~15 мин</i><br/>────────<br/>Читаешь этот<br/>документ"]
    S2["<b>Шаг 2</b><br/>Установи<br/><i>~20 мин</i><br/>────────<br/>VS Code + Claude Code<br/>+ GitHub аккаунт"]
    S3["<b>Шаг 3</b><br/>Первая сессия<br/><i>~30 мин</i><br/>────────<br/>Стратегический документ<br/>+ план на неделю"]
    S4["<b>Шаг 4</b><br/>Практика<br/><i>1-2 недели</i><br/>────────<br/>Ритуалы ОРЗ<br/>каждый день"]
    S5["<b>Шаг 5</b><br/>Мышление<br/><i>свой темп</i><br/>────────<br/>Системное мышление<br/>и принципы"]

    S1 -->|"ИИ поможет"| S2
    S2 -->|"Claude ведёт"| S3
    S3 -->|"привыкаешь"| S4
    S4 -->|"готов к глубине"| S5

    style S1 fill:#e3f2fd,stroke:#1e88e5,stroke-width:2px
    style S2 fill:#e8f5e9,stroke:#43a047,stroke-width:2px
    style S3 fill:#fff3e0,stroke:#fb8c00,stroke-width:2px
    style S4 fill:#f3e5f5,stroke:#8e24aa,stroke-width:2px
    style S5 fill:#fce4ec,stroke:#e53935,stroke-width:2px
```

---

## Схема 3. Ритуал ОРЗ (ежедневный цикл)

> Один паттерн для дня и для каждой рабочей сессии.

```mermaid
graph TD
    O["<b>ОТКРЫТИЕ</b><br/>«Открой день»<br/>────────<br/>План на сегодня<br/>Приоритеты<br/>Контекст вчера"]
    R["<b>РАБОТА</b><br/>Делаешь задачи<br/>────────<br/>На каждом рубеже:<br/>фиксируешь выводы<br/>и знания"]
    Z["<b>ЗАКРЫТИЕ</b><br/>«Закрой день»<br/>────────<br/>Итоги дня<br/>Обновление планов<br/>Что дальше"]

    O -->|"утро"| R
    R -->|"вечер"| Z
    Z -->|"завтра"| O

    style O fill:#e3f2fd,stroke:#1e88e5,stroke-width:2px
    style R fill:#e8f5e9,stroke:#43a047,stroke-width:2px
    style Z fill:#fff3e0,stroke:#fb8c00,stroke-width:2px
```

---

## Схема 4. Уровни освоения (тиры)

> Начинай с T1. Добавляй компоненты по мере готовности.

```mermaid
graph BT
    T1["<b>T1 — Старт</b><br/>Claude Code + экзокортекс<br/>────────<br/>ИИ-ассистент, который<br/>тебя помнит"]
    T2["<b>T2 — Практика</b><br/>+ ритуалы ОРЗ + план дня<br/>────────<br/>Структурированная работа<br/>без потери контекста"]
    T3["<b>T3 — Рост</b><br/>+ Pack + бот @aist_me_bot<br/>────────<br/>База знаний +<br/>мобильный доступ"]
    T4["<b>T4 — Мастерство</b><br/>+ роли + автоматизация<br/>────────<br/>ИИ-агенты работают<br/>самостоятельно"]

    T1 --> T2
    T2 --> T3
    T3 --> T4

    style T1 fill:#e3f2fd,stroke:#1e88e5,stroke-width:2px
    style T2 fill:#e8f5e9,stroke:#43a047,stroke-width:2px
    style T3 fill:#fff3e0,stroke:#fb8c00,stroke-width:2px
    style T4 fill:#fce4ec,stroke:#e53935,stroke-width:2px
```

---

## Схема 5. Иерархия принципов — кто создаёт, кто использует

> Принципы текут сверху вниз. Знания — снизу вверх (от твоего опыта обратно в Pack).

```mermaid
graph TD
    ZP["<b>Нулевые принципы (ZP)</b><br/>Базовые правила мышления<br/><i>Даны платформой</i>"]
    FPF["<b>Первые принципы (FPF)</b><br/>Фреймворк корректности<br/><i>Даны платформой</i>"]
    PACK["<b>Вторые принципы (Pack)</b><br/>Доменные знания<br/><i>Создаёшь ты</i>"]
    DS["<b>Третьи принципы (DS)</b><br/>Реализация<br/><i>Создаёшь ты + ИИ</i>"]

    ZP -->|"формируют"| FPF
    FPF -->|"направляют"| PACK
    PACK -->|"определяют"| DS

    USER["<b>Ты</b><br/>Изучаешь → системное мышление"]
    AI["<b>ИИ</b><br/>Принципы встроены в правила"]

    ZP -.->|"изучаешь"| USER
    FPF -.->|"изучаешь"| USER
    ZP -.->|"встроены"| AI
    FPF -.->|"встроены"| AI
    USER -->|"создаёт"| PACK
    PACK -->|"обогащает"| AI
    AI -->|"помогает структурировать"| PACK

    style ZP fill:#fce4ec,stroke:#e53935,stroke-width:2px
    style FPF fill:#fce4ec,stroke:#e53935,stroke-width:2px
    style PACK fill:#fff3e0,stroke:#fb8c00,stroke-width:2px
    style DS fill:#e8f5e9,stroke:#43a047,stroke-width:2px
    style USER fill:#f3e5f5,stroke:#8e24aa,stroke-width:2px
    style AI fill:#e3f2fd,stroke:#1e88e5,stroke-width:2px
```

---

## Схема 6. Экзоскелет vs Протез

> Ключевое различение IWE: ИИ **усиливает** мышление, а не **заменяет** его.

```mermaid
graph LR
    subgraph bad["<b>ПРОТЕЗ</b>"]
        direction TB
        B1["ИИ думает за тебя"]
        B2["Ты перестаёшь<br/>развиваться"]
        B3["Зависимость<br/>от инструмента"]
        B1 --> B2 --> B3
    end

    subgraph good["<b>ЭКЗОСКЕЛЕТ (IWE)</b>"]
        direction TB
        G1["ИИ берёт рутину"]
        G2["Ты думаешь<br/>лучше и быстрее"]
        G3["Навыки растут<br/>вместе с инструментом"]
        G1 --> G2 --> G3
    end

    style bad fill:#fce4ec,stroke:#e53935,stroke-width:2px
    style good fill:#e8f5e9,stroke:#43a047,stroke-width:2px
```

---

## Схема 7. Проблема → Решение

> Связь между типичными проблемами и компонентами IWE.

```mermaid
graph LR
    P1["Знания<br/>теряются"]
    P2["Планы<br/>не работают"]
    P3["ИИ не помогает<br/>по-настоящему"]

    S1["<b>Экзокортекс</b><br/>+ Pack<br/>+ GitHub"]
    S2["<b>Ритуалы ОРЗ</b><br/>+ Claude Code"]
    S3["<b>Claude Code</b><br/>+ экзокортекс<br/>(персональный)"]

    P1 -->|"решает"| S1
    P2 -->|"решает"| S2
    P3 -->|"решает"| S3

    style P1 fill:#fce4ec,stroke:#e53935,stroke-width:2px
    style P2 fill:#fce4ec,stroke:#e53935,stroke-width:2px
    style P3 fill:#fce4ec,stroke:#e53935,stroke-width:2px
    style S1 fill:#e8f5e9,stroke:#43a047,stroke-width:2px
    style S2 fill:#e8f5e9,stroke:#43a047,stroke-width:2px
    style S3 fill:#e8f5e9,stroke:#43a047,stroke-width:2px
```

---

*Создан: 2026-03-17 | WP-120 | [FMT-exocortex-template](https://github.com/TserenTserenov/FMT-exocortex-template)*
