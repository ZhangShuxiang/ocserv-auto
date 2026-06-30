#!/usr/bin/env python3
"""
Responses API to Chat Completions API 转换服务器
将 OpenAI Responses API 格式转换为 Chat Completions API 格式，并转发到 DeepSeek API
"""

import json
import os
import uuid
import time
from typing import Optional, List, Dict, Any, Union
from datetime import datetime

from flask import Flask, request, jsonify, Response, stream_with_context
import requests

app = Flask(__name__)

# 配置
DEEPSEEK_API_KEY = os.environ.get("DEEPSEEK_API_KEY", "your-deepseek-api-key-here")
DEEPSEEK_BASE_URL = "https://api.deepseek.com/v1"
SERVER_PORT = int(os.environ.get("SERVER_PORT", 8000))


class ResponsesConverter:
    """Responses API 到 Chat Completions API 的转换器"""
    
    @staticmethod
    def convert_responses_to_chat(
        responses_request: Dict[str, Any]
    ) -> Dict[str, Any]:
        """
        将 Responses API 格式转换为 Chat Completions API 格式
        
        Responses API 示例:
        {
            "model": "gpt-4",
            "input": "Hello, world!",
            "instructions": "You are a helpful assistant.",
            "temperature": 0.7,
            "max_output_tokens": 1000,
            "tools": [...],
            "stream": false
        }
        
        Chat Completions API 示例:
        {
            "model": "deepseek-chat",
            "messages": [
                {"role": "system", "content": "You are a helpful assistant."},
                {"role": "user", "content": "Hello, world!"}
            ],
            "temperature": 0.7,
            "max_tokens": 1000,
            "tools": [...],
            "stream": false
        }
        """
        chat_request = {
            "model": ResponsesConverter._map_model(responses_request.get("model", "gpt-4")),
            "messages": [],
            "stream": responses_request.get("stream", False)
        }
        
        # 处理 instructions (转换为 system message)
        if "instructions" in responses_request:
            chat_request["messages"].append({
                "role": "system",
                "content": responses_request["instructions"]
            })
        
        # 处理 input (可以是字符串或消息数组)
        input_data = responses_request.get("input", "")
        if isinstance(input_data, str):
            chat_request["messages"].append({
                "role": "user",
                "content": input_data
            })
        elif isinstance(input_data, list):
            # 如果 input 是消息列表，转换角色映射
            for msg in input_data:
                converted_msg = {
                    "role": ResponsesConverter._map_role(msg.get("role", "user")),
                    "content": msg.get("content", "")
                }
                # 保留其他字段
                for key in msg:
                    if key not in ["role", "content"]:
                        converted_msg[key] = msg[key]
                chat_request["messages"].append(converted_msg)
        
        # 映射参数
        param_mapping = {
            "temperature": "temperature",
            "max_output_tokens": "max_tokens",
            "top_p": "top_p",
            "frequency_penalty": "frequency_penalty",
            "presence_penalty": "presence_penalty",
            "stop": "stop",
            "tools": "tools",
            "tool_choice": "tool_choice"
        }
        
        for resp_param, chat_param in param_mapping.items():
            if resp_param in responses_request:
                chat_request[chat_param] = responses_request[resp_param]
        
        return chat_request
    
    @staticmethod
    def _map_model(model: str) -> str:
        """映射模型名称"""
        model_mapping = {
            "gpt-4": "deepseek-chat",
            "gpt-4-turbo": "deepseek-chat",
            "gpt-4o": "deepseek-chat",
            "gpt-4o-mini": "deepseek-chat",
            "gpt-3.5-turbo": "deepseek-chat",
        }
        return model_mapping.get(model, "deepseek-chat")
    
    @staticmethod
    def _map_role(role: str) -> str:
        """映射角色名称"""
        role_mapping = {
            "system": "system",
            "user": "user",
            "assistant": "assistant",
            "developer": "system",  # Responses API 特有角色
        }
        return role_mapping.get(role, "user")
    
    @staticmethod
    def convert_chat_to_responses(
        chat_response: Dict[str, Any],
        original_request: Dict[str, Any]
    ) -> Dict[str, Any]:
        """
        将 Chat Completions API 响应转换为 Responses API 格式
        
        Chat Completions API 响应:
        {
            "id": "chatcmpl-xxx",
            "object": "chat.completion",
            "created": 1234567890,
            "model": "deepseek-chat",
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": "Hello! How can I help you?"
                    },
                    "finish_reason": "stop"
                }
            ],
            "usage": {
                "prompt_tokens": 10,
                "completion_tokens": 20,
                "total_tokens": 30
            }
        }
        
        Responses API 响应:
        {
            "id": "resp_xxx",
            "object": "response",
            "created_at": 1234567890,
            "status": "completed",
            "model": "gpt-4",
            "output": [
                {
                    "type": "message",
                    "id": "msg_xxx",
                    "status": "completed",
                    "role": "assistant",
                    "content": [
                        {
                            "type": "output_text",
                            "text": "Hello! How can I help you?",
                            "annotations": []
                        }
                    ]
                }
            ],
            "usage": {
                "input_tokens": 10,
                "output_tokens": 20,
                "total_tokens": 30
            }
        }
        """
        response_id = f"resp_{uuid.uuid4().hex[:24]}"
        message_id = f"msg_{uuid.uuid4().hex[:24]}"
        created_at = int(time.time())
        
        choices = chat_response.get("choices", [])
        if not choices:
            return ResponsesConverter._create_error_response(
                "No choices in response", 
                original_request
            )
        
        choice = choices[0]
        message = choice.get("message", {})
        content = message.get("content", "")
        finish_reason = choice.get("finish_reason", "stop")
        
        # 处理工具调用
        output = []
        if "tool_calls" in message:
            for tool_call in message["tool_calls"]:
                output.append({
                    "type": "function_call",
                    "id": tool_call.get("id", f"call_{uuid.uuid4().hex[:24]}"),
                    "call_id": tool_call.get("id", f"call_{uuid.uuid4().hex[:24]}"),
                    "name": tool_call.get("function", {}).get("name", ""),
                    "arguments": tool_call.get("function", {}).get("arguments", "")
                })
        
        # 添加文本响应
        if content:
            output.append({
                "type": "message",
                "id": message_id,
                "status": "completed",
                "role": "assistant",
                "content": [
                    {
                        "type": "output_text",
                        "text": content,
                        "annotations": []
                    }
                ]
            })
        
        responses_response = {
            "id": response_id,
            "object": "response",
            "created_at": chat_response.get("created", created_at),
            "status": "completed" if finish_reason == "stop" else "incomplete",
            "model": original_request.get("model", "gpt-4"),
            "output": output,
            "usage": {
                "input_tokens": chat_response.get("usage", {}).get("prompt_tokens", 0),
                "output_tokens": chat_response.get("usage", {}).get("completion_tokens", 0),
                "total_tokens": chat_response.get("usage", {}).get("total_tokens", 0)
            }
        }
        
        # 保留原始的 finish_reason
        if finish_reason != "stop":
            responses_response["status"] = "incomplete"
            responses_response["incomplete_details"] = {
                "reason": finish_reason
            }
        
        return responses_response
    
    @staticmethod
    def _create_error_response(
        error_message: str,
        original_request: Dict[str, Any]
    ) -> Dict[str, Any]:
        """创建错误响应"""
        return {
            "id": f"resp_{uuid.uuid4().hex[:24]}",
            "object": "response",
            "created_at": int(time.time()),
            "status": "failed",
            "model": original_request.get("model", "gpt-4"),
            "output": [],
            "error": {
                "message": error_message,
                "type": "server_error"
            }
        }
    
    @staticmethod
    def convert_stream_chunk(
        chunk: Dict[str, Any],
        original_request: Dict[str, Any]
    ) -> Dict[str, Any]:
        """转换流式响应的单个 chunk"""
        choices = chunk.get("choices", [])
        if not choices:
            return {
                "type": "response.output_text.delta",
                "delta": "",
                "item_id": f"msg_{uuid.uuid4().hex[:24]}"
            }
        
        choice = choices[0]
        delta = choice.get("delta", {})
        
        # 处理文本增量
        if "content" in delta and delta["content"]:
            return {
                "type": "response.output_text.delta",
                "delta": delta["content"],
                "item_id": f"msg_{uuid.uuid4().hex[:24]}"
            }
        
        # 处理工具调用
        if "tool_calls" in delta:
            for tool_call in delta["tool_calls"]:
                return {
                    "type": "response.function_call_arguments.delta",
                    "delta": tool_call.get("function", {}).get("arguments", ""),
                    "item_id": tool_call.get("id", f"call_{uuid.uuid4().hex[:24]}")
                }
        
        # 处理完成信号
        if choice.get("finish_reason"):
            return {
                "type": "response.completed",
                "response": {
                    "id": f"resp_{uuid.uuid4().hex[:24]}",
                    "status": "completed"
                }
            }
        
        return {}


def call_deepseek_api(
    chat_request: Dict[str, Any],
    stream: bool = False
) -> requests.Response:
    """调用 DeepSeek API"""
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {DEEPSEEK_API_KEY}"
    }
    
    response = requests.post(
        f"{DEEPSEEK_BASE_URL}/chat/completions",
        json=chat_request,
        headers=headers,
        stream=stream,
        timeout=60
    )
    
    if response.status_code != 200:
        raise Exception(f"DeepSeek API error: {response.status_code} - {response.text}")
    
    return response


# API 路由
@app.route("/v1/responses", methods=["POST"])
def create_response():
    """
    Responses API 端点
    处理 POST /v1/responses 请求
    """
    try:
        request_data = request.get_json()
        if not request_data:
            return jsonify({"error": "Invalid request body"}), 400
        
        is_stream = request_data.get("stream", False)
        
        # 转换为 Chat Completions 格式
        chat_request = ResponsesConverter.convert_responses_to_chat(request_data)
        
        if is_stream:
            return handle_stream_response(chat_request, request_data)
        else:
            return handle_normal_response(chat_request, request_data)
            
    except Exception as e:
        return jsonify({
            "error": {
                "message": str(e),
                "type": "server_error"
            }
        }), 500


def handle_normal_response(
    chat_request: Dict[str, Any],
    original_request: Dict[str, Any]
):
    """处理普通响应"""
    try:
        # 调用 DeepSeek API
        response = call_deepseek_api(chat_request, stream=False)
        chat_response = response.json()
        
        # 转换为 Responses API 格式
        responses_response = ResponsesConverter.convert_chat_to_responses(
            chat_response, 
            original_request
        )
        
        return jsonify(responses_response)
        
    except Exception as e:
        return jsonify({
            "error": {
                "message": str(e),
                "type": "api_error"
            }
        }), 500


def handle_stream_response(
    chat_request: Dict[str, Any],
    original_request: Dict[str, Any]
):
    """处理流式响应"""
    def generate():
        try:
            response = call_deepseek_api(chat_request, stream=True)
            response_id = f"resp_{uuid.uuid4().hex[:24]}"
            
            # 发送开始事件
            yield f"data: {json.dumps({'type': 'response.created', 'response': {'id': response_id, 'status': 'in_progress'}})}\n\n"
            
            # 处理流式数据
            for line in response.iter_lines():
                if line:
                    line = line.decode('utf-8')
                    if line.startswith("data: "):
                        data_str = line[6:]
                        if data_str == "[DONE]":
                            break
                        
                        try:
                            chunk = json.loads(data_str)
                            converted_chunk = ResponsesConverter.convert_stream_chunk(
                                chunk, 
                                original_request
                            )
                            if converted_chunk:
                                yield f"data: {json.dumps(converted_chunk)}\n\n"
                        except json.JSONDecodeError:
                            continue
            
            yield "data: [DONE]\n\n"
            
        except Exception as e:
            error_chunk = {
                "type": "error",
                "error": {
                    "message": str(e),
                    "type": "stream_error"
                }
            }
            yield f"data: {json.dumps(error_chunk)}\n\n"
    
    return Response(
        stream_with_context(generate()),
        content_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no"
        }
    )


# 获取响应详情
@app.route("/v1/responses/<response_id>", methods=["GET"])
def retrieve_response(response_id: str):
    """获取响应详情（简化版）"""
    return jsonify({
        "id": response_id,
        "object": "response",
        "status": "completed",
        "message": "Response retrieval is not supported in this proxy"
    })


# 健康检查
@app.route("/health", methods=["GET"])
def health_check():
    """健康检查端点"""
    return jsonify({
        "status": "healthy",
        "service": "responses-api-proxy",
        "backend": "deepseek-api",
        "timestamp": datetime.now().isoformat()
    })


# 列出模型
@app.route("/v1/models", methods=["GET"])
def list_models():
    """列出可用模型"""
    return jsonify({
        "object": "list",
        "data": [
            {
                "id": "gpt-4",
                "object": "model",
                "created": 1687882411,
                "owned_by": "deepseek-proxy"
            },
            {
                "id": "gpt-4-turbo",
                "object": "model",
                "created": 1687882411,
                "owned_by": "deepseek-proxy"
            },
            {
                "id": "gpt-3.5-turbo",
                "object": "model",
                "created": 1687882411,
                "owned_by": "deepseek-proxy"
            }
        ]
    })


# 错误处理
@app.errorhandler(404)
def not_found(error):
    return jsonify({
        "error": {
            "message": "Endpoint not found",
            "type": "not_found_error"
        }
    }), 404


@app.errorhandler(500)
def internal_error(error):
    return jsonify({
        "error": {
            "message": "Internal server error",
            "type": "internal_error"
        }
    }), 500


if __name__ == "__main__":
    print(f"Starting Responses API Proxy Server on port {SERVER_PORT}")
    print(f"Backend: DeepSeek API ({DEEPSEEK_BASE_URL})")
    print(f"API Key: {'*' * 20}{DEEPSEEK_API_KEY[-4:] if len(DEEPSEEK_API_KEY) > 4 else ''}")
    print("-" * 50)
    print("Available endpoints:")
    print(f"  POST http://localhost:{SERVER_PORT}/v1/responses")
    print(f"  GET  http://localhost:{SERVER_PORT}/v1/responses/<response_id>")
    print(f"  GET  http://localhost:{SERVER_PORT}/v1/models")
    print(f"  GET  http://localhost:{SERVER_PORT}/health")
    print("-" * 50)
    
    app.run(
        host="0.0.0.0",
        port=SERVER_PORT,
        debug=False,
        threaded=True
    )
