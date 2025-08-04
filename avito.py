import asyncio
import aiohttp
from datetime import datetime, timedelta

# ================== CONFIG ==================
AVITO_USER_ID = 123456789  # <-- подставь свой ID
AVITO_CLIENT_ID = "your_client_id"
AVITO_CLIENT_SECRET = "your_client_secret"
OPENAI_API_KEY = "your_openai_api_key"
OPENAI_MODEL = "gpt-4"
CHECK_INTERVAL = 60  # в секундах
TIME_WINDOW_HOURS = 3  # новые сообщения за последние N часов
# ============================================


class AvitoClient:
    def __init__(self, user_id, client_id, client_secret):
        self.user_id = user_id
        self.client_id = client_id
        self.client_secret = client_secret
        self.access_token = None
        self.session = None
        self.base_url = "https://api.avito.ru"

    async def __aenter__(self):
        await self._get_token()
        self.session = aiohttp.ClientSession(headers={
            "Authorization": f"Bearer {self.access_token}",
            "Content-Type": "application/json"
        })
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        if self.session:
            await self.session.close()

    async def _get_token(self):
        data = {
            "grant_type": "client_credentials",
            "client_id": self.client_id,
            "client_secret": self.client_secret
        }
        async with aiohttp.ClientSession() as temp:
            async with temp.post(f"{self.base_url}/token", data=data) as res:
                res.raise_for_status()
                result = await res.json()
                self.access_token = result["access_token"]

    async def get_chats(self, limit=100):
        url = f"{self.base_url}/messenger/v2/accounts/{self.user_id}/chats"
        async with self.session.get(url, params={"limit": limit}) as res:
            return (await res.json()).get("chats", [])

    async def get_messages(self, chat_id, limit=20):
        url = f"{self.base_url}/messenger/v3/accounts/{self.user_id}/chats/{chat_id}/messages/"
        async with self.session.get(url, params={"limit": limit}) as res:
            data = await res.json()
            return data if isinstance(data, list) else data.get("messages", [])

    async def send_message(self, chat_id, text):
        url = f"{self.base_url}/messenger/v1/accounts/{self.user_id}/chats/{chat_id}/messages"
        payload = {"message": {"text": text}, "type": "text"}
        async with self.session.post(url, json=payload) as res:
            return res.status == 200


async def generate_response_with_openai(messages, item):
    prompt = f"""Ты — продавец на Авито. Ответь покупателю вежливо и по делу.

Объявление: {item.get('title')} — {item.get('price_string')}, {item.get('location', {}).get('title')}
Ссылка: {item.get('url')}

История переписки:
""" + "\n".join([
        f"{'Покупатель' if m['direction'] == 'in' else 'Продавец'}: {m['content'].get('text', '')}"
        for m in messages if m.get('type') == 'text'
    ]) + "\n\nОтвет:"

    headers = {
        "Authorization": f"Bearer {OPENAI_API_KEY}",
        "Content-Type": "application/json"
    }

    json_data = {
        "model": OPENAI_MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0.7
    }

    async with aiohttp.ClientSession() as session:
        async with session.post("https://api.openai.com/v1/chat/completions",
                                headers=headers, json=json_data) as res:
            if res.status == 200:
                data = await res.json()
                return data["choices"][0]["message"]["content"]
            else:
                error_text = await res.text()
                print(f"❌ OpenAI error: {res.status} — {error_text}")
                return None


async def run_avito_bot():
    cutoff_ts = datetime.utcnow() - timedelta(hours=TIME_WINDOW_HOURS)

    async with AvitoClient(AVITO_USER_ID, AVITO_CLIENT_ID, AVITO_CLIENT_SECRET) as client:
        while True:
            chats = await client.get_chats()

            for chat in chats:
                chat_id = chat.get("id")
                item = chat.get("context", {}).get("value", {})
                if not chat_id or not item:
                    continue

                messages = await client.get_messages(chat_id, limit=20)
                if not messages:
                    continue

                # Последнее входящее сообщение
                last_in = next((m for m in reversed(messages)
                                if m["direction"] == "in" and m["type"] == "text"), None)
                if not last_in:
                    continue

                created_at = datetime.utcfromtimestamp(last_in["created"])
                if created_at < cutoff_ts:
                    continue

                has_reply = any(m["direction"] == "out" and m["created"] > last_in["created"] for m in messages)
                if has_reply:
                    continue

                print(f"💬 Новое сообщение от покупателя в чате {chat_id}")
                reply = await generate_response_with_openai(messages, item)
                if reply:
                    success = await client.send_message(chat_id, reply)
                    if success:
                        print(f"✅ Ответ отправлен: {reply}")
                    else:
                        print("❌ Ошибка отправки")

            await asyncio.sleep(CHECK_INTERVAL)


if __name__ == "__main__":
    asyncio.run(run_avito_bot())
