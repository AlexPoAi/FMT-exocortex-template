#!/Library/Frameworks/Python.framework/Versions/3.14/bin/python3
"""
telegram-to-captures.py — Telegram → captures.md
=================================================
Слушает сообщения от конкретного CHAT_ID и добавляет их как
capture-кандидаты в DS-strategy/inbox/captures.md.

Формат добавляемого capture:
    ### {первые 60 символов текста} [source: Telegram YYYY-MM-DD]
    **Домен:** _требует классификации_
    **Тип:** _требует классификации_
    **Контент:**
    {полный текст сообщения}

Запуск: python3 telegram-to-captures.py
Автозапуск: через launchd (com.extractor.telegram-captures.plist)

Конфиг: ~/.config/aist/env (TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID)

Устойчивость к сбоям сети:
- Пробует SOCKS5 прокси (127.0.0.1:1080), при недоступности — напрямую
- При потере сети ждёт с backoff, не крашится
"""

import asyncio
import logging
import os
import re
import socket
import sys
import time
from datetime import datetime
from pathlib import Path

# --- Конфиг ---
CONFIG_FILE = Path.home() / ".config" / "aist" / "env"
CAPTURES_FILE = Path.home() / "Github" / "DS-strategy" / "inbox" / "captures.md"
DS_STRATEGY_DIR = Path.home() / "Github" / "DS-strategy"
LOG_DIR = Path.home() / "logs" / "extractor"
MARKER = "<!-- Captures добавляются ниже этой строки -->"
SOCKS_HOST = "127.0.0.1"
SOCKS_PORT = 1080

# --- Логирование ---
LOG_DIR.mkdir(parents=True, exist_ok=True)
log_file = LOG_DIR / f"{datetime.now().strftime('%Y-%m-%d')}.log"

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] [telegram-to-captures] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    handlers=[
        logging.FileHandler(log_file),
        logging.StreamHandler(sys.stdout),
    ],
)
logger = logging.getLogger(__name__)


def load_config(config_file: Path) -> dict:
    """Читает KEY="VALUE" из ~/.config/aist/env"""
    config = {}
    if not config_file.exists():
        return config
    with open(config_file) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            m = re.match(r'^(\w+)=["\'](.*?)["\']?\s*$', line)
            if m:
                config[m.group(1)] = m.group(2)
    return config


def is_socks_available() -> bool:
    """Проверяет доступность SOCKS5 прокси."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(2)
        sock.connect((SOCKS_HOST, SOCKS_PORT))
        sock.close()
        return True
    except (socket.error, OSError):
        return False


def add_capture_to_file(text: str, date_str: str) -> bool:
    """Добавляет capture в captures.md. Возвращает True если успешно."""
    if not CAPTURES_FILE.exists():
        logger.error(f"captures.md не найден: {CAPTURES_FILE}")
        return False

    # Заголовок — первые 60 символов, без переносов
    title_raw = text.split("\n")[0].strip()
    if len(title_raw) > 60:
        title = title_raw[:57] + "..."
    else:
        title = title_raw

    capture = f"""
### {title} [source: Telegram {date_str}]
**Домен:** _требует классификации_
**Тип:** _требует классификации_
**Контент:**
{text.strip()}

"""

    content = CAPTURES_FILE.read_text(encoding="utf-8")
    if MARKER not in content:
        logger.error(f"Маркер не найден в captures.md")
        return False

    new_content = content.replace(MARKER, MARKER + capture)
    CAPTURES_FILE.write_text(new_content, encoding="utf-8")
    logger.info(f"Добавлен capture: {title!r}")
    return True


def git_commit_and_push() -> bool:
    """Коммитит и пушит captures.md в DS-strategy.

    Порядок операций: add → commit → pull --rebase → push.
    pull делается ПОСЛЕ коммита, чтобы unstaged changes не мешали rebase.
    """
    import subprocess

    date_str = datetime.now().strftime("%Y-%m-%d")
    try:
        # 1. Добавляем только captures.md (не трогаем другие файлы)
        subprocess.run(
            ["git", "add", "inbox/captures.md"],
            cwd=DS_STRATEGY_DIR,
            check=True,
            capture_output=True,
        )

        # 2. Проверяем — есть ли что коммитить
        result = subprocess.run(
            ["git", "diff", "--cached", "--quiet"],
            cwd=DS_STRATEGY_DIR,
            capture_output=True,
        )
        if result.returncode == 0:
            logger.info("Нет изменений для коммита")
            return True

        # 3. Коммитим
        subprocess.run(
            ["git", "commit", "-m", f"telegram: заметка от @{_last_username or 'user'} [{date_str}]"],
            cwd=DS_STRATEGY_DIR,
            check=True,
            capture_output=True,
        )

        # 4. pull --rebase — после коммита unstaged changes не мешают
        pull_result = subprocess.run(
            ["git", "pull", "--rebase", "origin", "main"],
            cwd=DS_STRATEGY_DIR,
            capture_output=True,
            text=True,
        )
        if pull_result.returncode != 0:
            logger.warning(f"pull --rebase предупреждение (продолжаем): {pull_result.stderr.strip()}")

        # 5. Пушим
        subprocess.run(
            ["git", "push", "origin", "main"],
            cwd=DS_STRATEGY_DIR,
            check=True,
            capture_output=True,
        )
        logger.info("Запушено в GitHub")
        return True
    except subprocess.CalledProcessError as e:
        logger.error(f"Ошибка git: {e}")
        return False


# Глобальная переменная для имени пользователя в коммите
_last_username = None


def build_application(token: str):
    """Создаёт Application: пробует SOCKS5, при недоступности — без прокси."""
    from telegram.ext import Application
    from telegram.request import HTTPXRequest

    if is_socks_available():
        logger.info(f"SOCKS5 прокси доступен ({SOCKS_HOST}:{SOCKS_PORT}), используем")
        request = HTTPXRequest(
            proxy=f"socks5://{SOCKS_HOST}:{SOCKS_PORT}",
            connection_pool_size=8,
            connect_timeout=15.0,
            read_timeout=15.0,
        )
        return Application.builder().token(token).request(request).build()
    else:
        logger.warning("SOCKS5 прокси недоступен, пробуем без прокси (напрямую)")
        return Application.builder().token(token).build()


def main():
    from telegram import Update
    from telegram.ext import CommandHandler

    # Загружаем конфиг
    config = load_config(CONFIG_FILE)
    token = config.get("TELEGRAM_BOT_TOKEN") or os.environ.get("TELEGRAM_BOT_TOKEN")
    chat_id_str = config.get("TELEGRAM_CHAT_ID") or os.environ.get("TELEGRAM_CHAT_ID")

    if not token:
        logger.error("TELEGRAM_BOT_TOKEN не найден. Проверь ~/.config/aist/env")
        sys.exit(1)

    if not chat_id_str:
        logger.error("TELEGRAM_CHAT_ID не найден. Проверь ~/.config/aist/env")
        sys.exit(1)

    allowed_chat_id = int(chat_id_str)
    logger.info(f"Запуск. Слушаем chat_id={allowed_chat_id}")
    logger.info(f"captures.md: {CAPTURES_FILE}")

    async def handle_note(update: Update, context) -> None:
        """Обрабатывает команду /note от любого пользователя."""
        global _last_username
        if not update.message:
            return

        # Текст после команды
        text = " ".join(context.args) if context.args else ""
        if not text.strip():
            await update.message.reply_text("Напишите текст заметки после /note")
            return

        date_str = datetime.now().strftime("%Y-%m-%d")
        user = update.message.from_user
        _last_username = user.username or user.first_name or "Unknown"
        logger.info(f"Получена заметка от @{_last_username}: {text[:80]!r}")

        if add_capture_to_file(text, date_str):
            # Коммитим в фоне через executor (не блокируем event loop)
            loop = asyncio.get_running_loop()
            loop.run_in_executor(None, git_commit_and_push)

            await update.message.reply_text(
                "✅ Заметка сохранена\n"
                "Экстрактор обработает при следующем запуске."
            )
        else:
            await update.message.reply_text("❌ Ошибка сохранения. Попробуйте позже.")

    # --- Retry loop: при ошибке сети ждём и пробуем заново ---
    max_backoff = 300  # 5 минут макс
    backoff = 10

    while True:
        try:
            app = build_application(token)
            app.add_handler(CommandHandler(["note", "zametka"], handle_note))

            logger.info("Polling запущен. Команда: /note")
            # Добавляем retry_after=5, чтобы при обрыве сети (VPN/прокси) бот не падал с ошибкой, а ждал
            # Используем стандартный polling без кривых аргументов
            app.run_polling(drop_pending_updates=True, close_loop=False)
            break  # Если run_polling вернулся нормально — выходим

        except Exception as e:
            logger.error(f"Бот упал: {e.__class__.__name__}: {e}")
            logger.info(f"Ждём {backoff} сек перед перезапуском...")
            time.sleep(backoff)
            backoff = min(backoff * 2, max_backoff)
            logger.info("Перезапуск бота...")


if __name__ == "__main__":
    main()
