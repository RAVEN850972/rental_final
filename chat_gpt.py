import aiohttp
import json
from config import (
    SYSTEM_PROMPT, 
    EXTRACTION_PROMPT_TEMPLATE, 
    FIRST_MESSAGE_INSTRUCTION,
    COMPLETION_MARKER,
    OPENAI_ERROR,
    OPENAI_API_KEY,
    OPENAI_MODEL
)

# Удаляем константы конфигурации


class ChatGPTHandler:
    def __init__(self, api_key, model="gpt-4o"):
        self.api_key = api_key
        self.model = model
        self.base_url = "https://api.openai.com/v1/chat/completions"
        
    async def _make_request(self, messages, temperature=0.7):
        """Базовый запрос к OpenAI API"""
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json"
        }
        
        payload = {
            "model": self.model,
            "messages": messages,
            "temperature": temperature
        }
        
        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(self.base_url, headers=headers, json=payload) as response:
                    if response.status == 200:
                        data = await response.json()
                        return data["choices"][0]["message"]["content"]
                    else:
                        error_text = await response.text()
                        print(f"OpenAI API error: {response.status} — {error_text}")
                        return None
        except Exception as e:
            print(f"OpenAI request error: {e}")
            return None
    
    async def generate_response(self, dialog_history, is_first_message=False):
        """Генерация ответа агента по аренде"""
        try:
            # Используем только основной системный промпт
            system_prompt = SYSTEM_PROMPT
            
            # Формируем сообщения для API
            messages = [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": dialog_history}
            ]
            
            # Получаем ответ от GPT
            response = await self._make_request(messages)
            
            if response is None:
                return OPENAI_ERROR
            
            return response.strip()
            
        except Exception as e:
            print(f"Error generating response: {e}")
            return OPENAI_ERROR
    
    async def extract_client_data(self, dialog_history):
        """Извлечение структурированных данных о клиенте из диалога"""
        try:
            # Формируем промпт для извлечения данных
            extraction_prompt = EXTRACTION_PROMPT_TEMPLATE.format(
                dialog_history=dialog_history
            )
            
            messages = [
                {"role": "user", "content": extraction_prompt}
            ]
            
            # Получаем структурированные данные
            response = await self._make_request(messages, temperature=0.1)
            
            if response is None:
                return None
            
            # Пытаемся распарсить JSON
            try:
                client_data = json.loads(response)
                return client_data
            except json.JSONDecodeError as e:
                print(f"JSON parsing error: {e}")
                print(f"Raw response: {response}")
                return None
                
        except Exception as e:
            print(f"Error extracting client data: {e}")
            return None
    
    def is_dialog_complete(self, response):
        """Проверка завершенности диалога"""
        return COMPLETION_MARKER in response

# Глобальный экземпляр ChatGPT хендлера
chatgpt_handler = ChatGPTHandler(OPENAI_API_KEY, OPENAI_MODEL)

async def get_agent_response(dialog_history, is_first_message=False):
    """Получение ответа агента"""
    return await chatgpt_handler.generate_response(dialog_history, is_first_message)

async def extract_final_client_data(dialog_history):
    """Извлечение финальных данных клиента"""
    return await chatgpt_handler.extract_client_data(dialog_history)

def check_dialog_completion(response):
    """Проверка завершенности сбора информации"""
    return chatgpt_handler.is_dialog_complete(response)
