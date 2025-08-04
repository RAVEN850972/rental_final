import asyncio
import aiohttp
from datetime import datetime, timedelta
from collections import defaultdict
import json

# Импорты модулей проекта
from avito import AvitoClient
from chat_gpt import get_agent_response, extract_final_client_data, check_dialog_completion
from telegram import send_completed_application
from config import (
    COMPLETION_MARKER,
    AVITO_USER_ID,
    AVITO_CLIENT_ID,
    AVITO_CLIENT_SECRET,
    CHECK_INTERVAL,
    TIME_WINDOW_HOURS,
    MAX_MESSAGES_HISTORY
)

# Удаляем константы конфигурации


class AvitoRentalBot:
    def __init__(self):
        # Хранилище состояния чатов (chat_id -> dialog_history)
        self.chat_states = defaultdict(list)
        # Отслеживание обработанных сообщений (chat_id -> last_message_timestamp)
        self.processed_messages = defaultdict(int)
        # Завершенные диалоги (чтобы не обрабатывать повторно)
        self.completed_chats = set()
        
    def format_dialog_history(self, messages):
        """Форматирование истории диалога для отправки в GPT"""
        dialog = []
        
        for message in messages[-MAX_MESSAGES_HISTORY:]:  # Берем последние 30 сообщений
            if message.get("type") != "text":
                continue
                
            direction = message.get("direction")
            text = message.get("content", {}).get("text", "").strip()
            
            if not text:
                continue
            
            # Определяем роль отправителя
            if direction == "in":
                dialog.append(f"Клиент: {text}")
            elif direction == "out":
                dialog.append(f"Светлана: {text}")
        
        return "\n".join(dialog)
    
    def is_first_client_message(self, messages, chat_id):
        """Проверка, является ли это первое сообщение от клиента в чате"""
        # Если чат уже был в обработке, то не первое
        if chat_id in self.chat_states and self.chat_states[chat_id]:
            return False
            
        # Проверяем, есть ли исходящие сообщения от агента
        outgoing_messages = [m for m in messages if m.get("direction") == "out"]
        return len(outgoing_messages) == 0
    
    async def process_chat(self, client, chat_id, chat_data):
        """Обработка отдельного чата"""
        try:
            # Проверяем, не завершен ли уже диалог
            if chat_id in self.completed_chats:
                return
            
            # Получаем сообщения чата
            messages = await client.get_messages(chat_id, limit=MAX_MESSAGES_HISTORY)
            if not messages:
                return
            
            # Ищем последнее входящее текстовое сообщение
            last_incoming = None
            for message in reversed(messages):
                if (message.get("direction") == "in" and 
                    message.get("type") == "text" and 
                    message.get("content", {}).get("text", "").strip()):
                    last_incoming = message
                    break
            
            if not last_incoming:
                return
            
            # Проверяем временные рамки (только новые сообщения)
            cutoff_time = datetime.utcnow() - timedelta(hours=TIME_WINDOW_HOURS)
            message_time = datetime.utcfromtimestamp(last_incoming["created"])
            
            if message_time < cutoff_time:
                return
            
            # Проверяем, не обработано ли уже это сообщение
            last_processed_time = self.processed_messages.get(chat_id, 0)
            if last_incoming["created"] <= last_processed_time:
                return
            
            # Проверяем, нет ли уже ответа на это сообщение
            has_newer_outgoing = any(
                m.get("direction") == "out" and m.get("created", 0) > last_incoming["created"]
                for m in messages
            )
            
            if has_newer_outgoing:
                return
            
            print(f"💬 Обработка нового сообщения в чате {chat_id}")
            
            # Форматируем историю диалога
            dialog_history = self.format_dialog_history(messages)
            
            # Определяем, первое ли это сообщение клиента
            is_first_message = self.is_first_client_message(messages, chat_id)
            
            # Генерируем ответ через ChatGPT
            response = await get_agent_response(dialog_history, is_first_message)
            
            if not response:
                print(f"Не удалось сгенерировать ответ для чата {chat_id}")
                return
            
            # Удаляем маркер завершения из ответа перед отправкой
            clean_response = response.replace(COMPLETION_MARKER, "").strip()
            
            # Отправляем ответ
            success = await client.send_message(chat_id, clean_response)
            
            if success:
                print(f"Ответ отправлен в чат {chat_id}: {clean_response[:100]}...")
                
                # Обновляем время последнего обработанного сообщения
                self.processed_messages[chat_id] = last_incoming["created"]
                
                # Сохраняем состояние диалога
                self.chat_states[chat_id].append(dialog_history)
                
                # Проверяем завершенность диалога
                if check_dialog_completion(response):
                    await self.handle_completed_dialog(chat_id, dialog_history + f"\nСветлана: {clean_response}")
                    
            else:
                print(f"Ошибка отправки ответа в чат {chat_id}")
                
        except Exception as e:
            print(f"Ошибка обработки чата {chat_id}: {e}")
    
    async def handle_completed_dialog(self, chat_id, final_dialog):
        """Обработка завершенного диалога"""
        try:
            print(f"Диалог завершен в чате {chat_id}, извлекаем данные клиента...")
            
            # Извлекаем структурированные данные клиента
            client_data = await extract_final_client_data(final_dialog)
            
            if client_data:
                print(f"Данные клиента извлечены: {json.dumps(client_data, ensure_ascii=False, indent=2)}")
                
                # Отправляем заявку в Telegram
                success = await send_completed_application(client_data)
                
                if success:
                    print(f"Заявка отправлена в Telegram для чата {chat_id}")
                else:
                    print(f"Ошибка отправки заявки в Telegram для чата {chat_id}")
            else:
                print(f"Не удалось извлечь данные клиента из чата {chat_id}")
            
            # Помечаем чат как завершенный
            self.completed_chats.add(chat_id)
            
        except Exception as e:
            print(f"Ошибка обработки завершенного диалога {chat_id}: {e}")
    
    async def run(self):
        """Основной цикл работы бота"""
        print("Запуск Avito Rental Bot...")
        print(f"Интервал проверки: {CHECK_INTERVAL} секунд")
        print(f"Временное окно: {TIME_WINDOW_HOURS} часов")
        
        while True:
            try:
                # Создаем клиент Avito API
                async with AvitoClient(AVITO_USER_ID, AVITO_CLIENT_ID, AVITO_CLIENT_SECRET) as client:
                    # Получаем список чатов
                    chats = await client.get_chats(limit=100)
                    print(f"Получено {len(chats)} чатов для проверки")
                    
                    # Создаем задачи для параллельной обработки чатов
                    tasks = []
                    for chat in chats:
                        chat_id = chat.get("id")
                        if chat_id:
                            task = asyncio.create_task(
                                self.process_chat(client, chat_id, chat)
                            )
                            tasks.append(task)
                    
                    # Ждем завершения всех задач
                    if tasks:
                        await asyncio.gather(*tasks, return_exceptions=True)
                    
                    print(f"Обработка завершена. Ожидание {CHECK_INTERVAL} секунд...")
                    
            except Exception as e:
                print(f"Критическая ошибка в основном цикле: {e}")
                print("Ожидание перед повторной попыткой...")
            
            # Ждем до следующей проверки
            await asyncio.sleep(CHECK_INTERVAL)

async def main():
    """Точка входа в приложение"""
    bot = AvitoRentalBot()
    await bot.run()

if __name__ == "__main__":
    # Запуск основного приложения
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nОстановка бота по запросу пользователя")
    except Exception as e:
        print(f"Критическая ошибка: {e}")