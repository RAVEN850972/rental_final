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

# Этапы диалога
STAGE_GREETING = "greeting"
STAGE_RESIDENTS = "residents"
STAGE_CHILDREN = "children"
STAGE_PETS = "pets"
STAGE_RENTAL_PERIOD = "rental_period"
STAGE_DEADLINE = "deadline"
STAGE_CONTACTS = "contacts"
STAGE_COMPLETE = "complete"

class AvitoRentalBot:
    def __init__(self):
        # Хранилище состояния чатов (chat_id -> dialog_history)
        self.chat_states = defaultdict(list)
        # Отслеживание обработанных сообщений (chat_id -> last_message_timestamp)
        self.processed_messages = defaultdict(int)
        # Завершенные диалоги (чтобы не обрабатывать повторно)
        self.completed_chats = set()
        # Этапы диалогов (chat_id -> stage)
        self.chat_stages = defaultdict(lambda: STAGE_GREETING)
        
    def determine_dialog_stage(self, messages):
        """Определение текущего этапа диалога на основе истории сообщений"""
        agent_messages = []
        client_messages = []
        
        for message in messages:
            if message.get("type") != "text":
                continue
            text = message.get("content", {}).get("text", "").strip().lower()
            if not text:
                continue
                
            if message.get("direction") == "out":
                agent_messages.append(text)
            else:
                client_messages.append(text)
        
        # Если нет сообщений от агента - это начало
        if not agent_messages:
            return STAGE_GREETING
        
        # Проверяем, есть ли уже приветствие
        has_greeting = any("здравствуйте" in msg and "светлана" in msg for msg in agent_messages)
        if not has_greeting:
            return STAGE_GREETING
            
        # Анализируем собранную информацию из сообщений клиента
        client_text = " ".join(client_messages).lower()
        last_agent_msg = agent_messages[-1] if agent_messages else ""
        
        # Проверяем наличие информации о жильцах
        has_residents_info = any(word in client_text for word in ["человек", "буду", "планирую", "один", "два", "три", "семь", "пара", "семья"])
        
        # Проверяем наличие информации о сроке
        has_period_info = any(word in client_text for word in ["месяц", "год", "надолго", "постоянно"]) or any(char.isdigit() for char in client_text if "месяц" in client_text)
        
        # Проверяем наличие даты
        has_date_info = any(word in client_text for word in ["август", "сентябр", "октябр", "ноябр", "декабр", "январ", "феврал", "март", "апрел", "май", "июн", "июл"]) or ("число" in client_text and any(char.isdigit() for char in client_text))
        
        # Проверяем наличие телефона
        has_phone = any(len([c for c in msg if c.isdigit()]) >= 10 for msg in client_messages)
        
        # Определяем этап на основе собранной информации
        if not has_residents_info or "кто проживать планирует" in last_agent_msg:
            return STAGE_RESIDENTS
        elif ("дет" in last_agent_msg or "ребен" in last_agent_msg) and not has_period_info:
            return STAGE_CHILDREN
        elif ("животн" in last_agent_msg or "питом" in last_agent_msg) and not has_period_info:
            return STAGE_PETS
        elif not has_period_info or ("срок" in last_agent_msg or "месяц" in last_agent_msg):
            return STAGE_RENTAL_PERIOD
        elif not has_date_info or ("дата" in last_agent_msg or "заез" in last_agent_msg):
            return STAGE_DEADLINE
        elif not has_phone or ("телефон" in last_agent_msg or "номер" in last_agent_msg):
            return STAGE_CONTACTS
        else:
            return STAGE_COMPLETE  

    def format_dialog_history(self, messages):
        """Форматирование истории диалога для отправки в GPT"""
        dialog = []
        
        # Берем последние 30 сообщений и сортируем по времени (от старых к новым)
        recent_messages = messages[-MAX_MESSAGES_HISTORY:]
        sorted_messages = sorted(recent_messages, key=lambda x: x.get("created", 0))
        
        for message in sorted_messages:
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
                # Убираем дублирование "Светлана:" если оно уже есть в тексте
                clean_text = text
                if clean_text.startswith("Светлана: "):
                    clean_text = clean_text[10:].strip()  # Убираем "Светлана: "
                dialog.append(f"Светлана: {clean_text}")
        
        return "\n".join(dialog)
        
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
            
            # Ищем последнее входящее текстовое сообщение по времени создания
            last_incoming = None
            for message in messages:
                if (message.get("direction") == "in" and 
                    message.get("type") == "text" and 
                    message.get("content", {}).get("text", "").strip()):
                    if last_incoming is None or message.get("created", 0) > last_incoming.get("created", 0):
                        last_incoming = message
            
            if not last_incoming:
                return
            
            # Проверяем временные рамки - обрабатываем только новые сообщения
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
            
            print(f"Получено сообщение: {last_incoming['content']['text'][:100]}...")
            
            # Определяем текущий этап диалога
            current_stage = self.determine_dialog_stage(messages)
            self.chat_stages[chat_id] = current_stage
            
            # Определяем, первое ли это сообщение
            has_any_outgoing = any(m.get("direction") == "out" and m.get("type") == "text" for m in messages)
            is_first_message = not has_any_outgoing
            
            # Форматируем историю диалога для отправки в GPT
            dialog_history = self.format_dialog_history(messages)
            
            # ОТЛАДКА: выводим что отправляется в нейросеть
            print(f"=== ОТЛАДКА ЧАТА {chat_id} ===")
            print(f"current_stage: {current_stage}")
            print(f"is_first_message: {is_first_message}")
            print(f"dialog_history отправляемый в GPT:")
            print(dialog_history[-500:])  # Показываем только последние 500 символов
            print("=== КОНЕЦ ОТЛАДКИ ===")
            
            # Генерируем ответ через ChatGPT
            response = await get_agent_response(dialog_history, is_first_message)
            
            if not response:
                print(f"Не удалось сгенерировать ответ для чата {chat_id}")
                return
            
            # Удаляем маркер завершения из ответа перед отправкой клиенту
            clean_response = response.replace(COMPLETION_MARKER, "").strip()
            
            # Отправляем ответ клиенту
            success = await client.send_message(chat_id, clean_response)
            
            if success:
                print(f"Отправлен ответ: {clean_response[:100]}...")
                
                # Обновляем время последнего обработанного сообщения
                self.processed_messages[chat_id] = last_incoming["created"]
                
                # Сохраняем состояние диалога
                self.chat_states[chat_id].append(dialog_history)
                
                # Проверяем завершенность диалога по маркеру
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
