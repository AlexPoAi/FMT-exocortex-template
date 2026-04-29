#!/Library/Frameworks/Python.framework/Versions/3.14/bin/python3
"""
telegram-to-captures.py — Telegram → captures.md
=================================================
Слушает сообщения от конкретного CHAT_ID и добавляет их как
capture-кандидаты в DS-strategy/inbox/captures.md.
"""

import asyncio
import logging
import os
import re
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

TOKEN_URL_RE = re.compile(r"(api\.telegram\.org/bot)([0-9]{8,}:[A-Za-z0-9_-]{20,})")


def redact_sensitive(value: str) -> str:
    if not value:
        return value
    return TOKEN_URL_RE.sub(r"\1<TOKEN_REDACTED>", value)


class RedactTelegramTokenFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        record.msg = redact_sensitive(str(record.msg))
        if record.args:
            record.args = tuple(redact_sensitive(str(arg)) for arg in record.args)
        return True


for noisy_logger in ("httpx", "httpcore", "telegram", "telegram.ext"):
    logging.getLogger(noisy_logger).setLevel(logging.WARNING)

for handler in logging.getLogger().handlers:
    handler.addFilter(RedactTelegramTokenFilter())


def load_config(config_file: Path) -> dict:
    config = {}
    if not config_file.exists():
        return config
    with open(config_file) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            m = re.match(r'^(\w+)=["\']?(.*?)["\']?\s*$', line)
            if m:
                config[m.group(1)] = m.group(2)
    return config


def add_capture_to_file(text: str, date_str: str) -> bool:
    if not CAPTURES_FILE.exists():
        logger.error(f"captures.md не найден: {CAPTURES_FILE}")
        return False

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


def build_application(token: str):
    from telegram.ext import Application
    from telegram.request import HTTPXRequest
    import socket

    proxy_url = f"socks5://{SOCKS_HOST}:{SOCKS_PORT}"
    use_proxy = False

    # Быстрая проверка, жив ли туннель
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(2)
            if s.connect_ex((SOCKS_HOST, SOCKS_PORT)) == 0:
                use_proxy = True
                logger.info(f"SOCKS5 прокси доступен ({SOCKS_HOST}:{SOCKS_PORT}), используем")
    except Exception as e:
        logger.warning(f"Ошибка проверки SOCKS5: {e}")

    if not use_proxy:
        logger.warning("SOCKS5 прокси НЕ доступен. Пробуем без прокси.")
        proxy_url = None

    request = HTTPXRequest(
        proxy=proxy_url,
        connection_pool_size=8,
        connect_timeout=20.0,
        read_timeout=20.0,
    )
    
    return Application.builder().token(token).request(request).build()


def main():
    from telegram import Update
    from telegram.ext import CommandHandler
    
    config = load_config(CONFIG_FILE)
    token = config.get("TELEGRAM_BOT_TOKEN") or os.environ.get("TELEGRAM_BOT_TOKEN")
    chat_id_str = config.get("TELEGRAM_CHAT_ID") or os.environ.get("TELEGRAM_CHAT_ID")

    if not token or not chat_id_str:
        logger.error("Токен или CHAT_ID не найдены")
        sys.exit(1)

    allowed_chat_id = int(chat_id_str)
    logger.info(f"Запуск. Слушаем chat_id={allowed_chat_id}")
    logger.info(f"captures.md: {CAPTURES_FILE}")

    async def handle_note(update: Update, context) -> None:
        if not update.message:
            return

        text = " ".join(context.args) if context.args else ""
        if not text.strip():
            await update.message.reply_text("Использование: /note текст заметки")
            return

        date_str = datetime.now().strftime("%Y-%m-%d")
        user = update.message.from_user
        username = user.username or user.first_name or "Unknown"
        logger.info(f"Получена заметка от @{username}: {text[:80]!r}")

        if add_capture_to_file(text, date_str):
            # БЕЗ GIT! Просто отвечаем пользователю
            await update.message.reply_text(
                "✅ Заметка добавлена локально.\n"
                "Экстрактор заберёт её в Pack."
            )
        else:
            await update.message.reply_text("❌ Ошибка записи в файл.")

    backoff = 10
    max_backoff = 300

    while True:
        try:
            app = build_application(token)
            # ВНИМАНИЕ: Telegram не поддерживает кириллицу в командах, используем 'note' и 'zametka'
            app.add_handler(CommandHandler(["note", "zametka"], handle_note))

            logger.info("Polling запущен. Команда: /note")
            app.run_polling(drop_pending_updates=True, close_loop=False)
            break  # Нормальный выход

        except Exception as e:
            logger.error(
                "Бот упал: %s: %s",
                e.__class__.__name__,
                redact_sensitive(str(e)),
            )
            logger.info(f"Ждём {backoff} сек перед перезапуском...")
            time.sleep(backoff)
            backoff = min(backoff * 2, max_backoff)
            logger.info("Перезапуск бота...")


if __name__ == "__main__":
    main()
