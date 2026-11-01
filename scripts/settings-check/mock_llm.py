#!/usr/bin/env python3
"""模拟 Ollama(/api/chat) 与 OpenAI(/v1/chat/completions)，用于验证「测试连接」链路。"""
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = "/tmp/mock_llm_requests.log"


def log(line):
    with open(LOG, "a") as f:
        f.write(line + "\n")


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_GET(self):
        auth = self.headers.get("Authorization", "")
        log(f"GET {self.path} auth={'yes' if auth else 'no'}")
        if self.path.startswith("/anthropic/v1/models"):
            # 兼容层通常不实现模型列表，用它验证「404 也要当服务可达」的降级逻辑
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path.startswith("/api/tags"):
            body = {"models": [{"name": "qwen2.5-coder:7b", "size": 1}, {"name": "deepseek-r1:8b", "size": 2}]}
        elif self.path.startswith("/v1/models"):
            if not auth or auth == "Bearer bad-key":
                payload = json.dumps({"error": {"message": "You didn't provide an API key."}}).encode()
                self.send_response(401)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                return
            body = {"data": [{"id": "gpt-4o-mini"}, {"id": "gpt-4o"}]}
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        payload = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n).decode("utf-8", "replace")
        try:
            body = json.loads(raw)
        except Exception:
            body = {}
        model = body.get("model", "")
        auth = self.headers.get("Authorization", "")
        log(f"{self.path} model={model} auth={'yes' if auth else 'no'}")

        if model == "missing":
            payload = json.dumps({"error": f"model '{model}' not found, try pulling it first"}).encode()
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        if self.path.startswith("/anthropic/v1/messages"):
            key = self.headers.get("x-api-key", "")
            version = self.headers.get("anthropic-version", "")
            log(f"anthropic x-api-key={'yes' if key else 'no'} version={version or '-'} "
                f"max_tokens={body.get('max_tokens')} system={'yes' if body.get('system') else 'no'} "
                f"msgs={len(body.get('messages') or [])} temp={body.get('temperature')}")
            if not key or key == "bad-key":
                payload = json.dumps({"type": "error",
                                      "error": {"type": "authentication_error",
                                                "message": "x-api-key header is required"}}).encode()
                self.send_response(401)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                return
            if body.get("model") == "missing":
                payload = json.dumps({"type": "error",
                                      "error": {"type": "not_found_error",
                                                "message": "model not found"}}).encode()
                self.send_response(404)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                return

            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.chunk("event: message_start\n"
                       'data: {"type":"message_start","message":{"id":"msg_1","content":[]}}\n\n')
            self.chunk("event: content_block_start\n"
                       'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n')
            for piece in ["正", "常"]:
                ev = json.dumps({"type": "content_block_delta", "index": 0,
                                 "delta": {"type": "text_delta", "text": piece}}, ensure_ascii=False)
                self.chunk("event: content_block_delta\ndata: " + ev + "\n\n")
                time.sleep(0.05)
            self.chunk('event: message_stop\ndata: {"type":"message_stop"}\n\n')
            self.wfile.write(b"0\r\n\r\n")
            return

        if self.path.startswith("/api/chat"):
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for piece in ["正", "常"]:
                line = json.dumps({"model": model, "message": {"role": "assistant", "content": piece},
                                   "done": False}, ensure_ascii=False)
                self.chunk(line + "\n")
                time.sleep(0.05)
            self.chunk(json.dumps({"model": model, "done": True}, ensure_ascii=False) + "\n")
            self.wfile.write(b"0\r\n\r\n")
            return

        if self.path.startswith("/v1/chat/completions"):
            if not auth or auth == "Bearer bad-key":
                payload = json.dumps({"error": {"message": "You didn't provide an API key."}}).encode()
                self.send_response(401)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for piece in ["正", "常"]:
                ev = json.dumps({"choices": [{"delta": {"content": piece}}]}, ensure_ascii=False)
                self.chunk("data: " + ev + "\n\n")
                time.sleep(0.05)
            self.chunk("data: [DONE]\n\n")
            self.wfile.write(b"0\r\n\r\n")
            return

        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def chunk(self, text: str):
        data = text.encode()
        self.wfile.write(f"{len(data):X}\r\n".encode())
        self.wfile.write(data)
        self.wfile.write(b"\r\n")


if __name__ == "__main__":
    open(LOG, "w").close()
    ThreadingHTTPServer(("127.0.0.1", 11500), H).serve_forever()
