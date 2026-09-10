"""QwenVisionClient 가 지정한 모델명과 API 키를 실제 요청에 싣는지 확인한다.

포드 vLLM 은 요청의 model 이 틀리면 404 를 내고, 인증이 걸린 엔드포인트는 헤더가
없으면 401 을 낸다. 둘 다 조용히 깨지면 원인 찾기가 오래 걸리므로 여기서 막는다.
GPU·브라우저·네트워크 없이 CPU 로만 돈다. 실행: python tests/test_vision_client.py
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest import mock

# cv2/PIL/selenium 은 이 테스트가 쓰지 않는다. import 만 통과시켜 의존성 없는 환경에서도 돌게 한다.
for _name in (
    "cv2",
    "requests",
    "PIL",
    "PIL.Image",
    "selenium",
    "selenium.webdriver",
    "selenium.webdriver.chrome",
    "selenium.webdriver.chrome.options",
):
    sys.modules.setdefault(_name, mock.MagicMock())

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agents import vision_game_agent  # noqa: E402


class FakeResponse:
    def __init__(self, payload: dict) -> None:
        self._payload = payload

    def raise_for_status(self) -> None:
        pass

    def json(self) -> dict:
        return self._payload


class FakeSession:
    """requests.Session 대역. 마지막 요청 본문을 그대로 보관한다."""

    def __init__(self) -> None:
        self.headers: dict[str, str] = {}
        self.last_json: dict | None = None
        self.last_url: str | None = None
        self.models: list[str] = ["mia-vl"]

    def post(self, url: str, json: dict, timeout: int) -> FakeResponse:  # noqa: A002
        self.last_url = url
        self.last_json = json
        content = '{"bird_y": 500, "gap_y": 400}'
        return FakeResponse({"choices": [{"message": {"content": content}}]})

    def get(self, url: str, timeout: int) -> FakeResponse:
        self.last_url = url
        return FakeResponse({"data": [{"id": name} for name in self.models]})


def make_client(**kwargs) -> vision_game_agent.QwenVisionClient:
    with mock.patch.object(vision_game_agent.requests, "Session", FakeSession):
        return vision_game_agent.QwenVisionClient("http://127.0.0.1:8092/", **kwargs)


class QwenVisionClientTests(unittest.TestCase):
    def test_payload_uses_configured_model(self) -> None:
        """요청 본문의 model 은 --model 로 지정한 이름이어야 한다."""
        client = make_client(model="mia-vl")
        client.analyze(b"png-bytes", "prompt", {"type": "object"})
        self.assertEqual(client.session.last_json["model"], "mia-vl")
        self.assertEqual(client.session.last_url, "http://127.0.0.1:8092/v1/chat/completions")
        # llama.cpp 용 최상위 json_schema 와 vLLM 용 response_format 이 둘 다 실려야 한다.
        self.assertEqual(client.session.last_json["json_schema"], {"type": "object"})
        self.assertEqual(
            client.session.last_json["response_format"]["json_schema"]["schema"], {"type": "object"}
        )

    def test_default_model_stays_local_2b(self) -> None:
        """인자 없이 쓰면 기존 로컬 동작 그대로여야 한다."""
        client = make_client()
        client.analyze(b"png-bytes", "prompt", {})
        self.assertEqual(client.session.last_json["model"], "qwen3-vl-2b")

    def test_bearer_header_follows_api_key(self) -> None:
        """키가 있으면 Authorization 이 붙고, 없거나 빈 문자열이면 안 붙는다."""
        self.assertEqual(
            make_client(api_key="secret").session.headers.get("Authorization"), "Bearer secret"
        )
        self.assertNotIn("Authorization", make_client().session.headers)
        self.assertNotIn("Authorization", make_client(api_key="").session.headers)

    def test_unknown_model_is_corrected_to_served_one(self) -> None:
        """서버 목록에 없는 모델명은 서버 것으로 바꾸고 경고 한 줄을 남긴다."""
        client = make_client(model="없는모델")
        with mock.patch("builtins.print") as printed:
            client.resolve_model()
        self.assertEqual(client.model, "mia-vl")
        self.assertIn("자동 교정", printed.call_args[0][0])

    def test_unreachable_server_exits_immediately(self) -> None:
        """조회 실패는 60초 타임아웃을 기다리지 않고 SystemExit 로 끝낸다."""
        client = make_client()
        client.session.get = mock.Mock(side_effect=OSError("connection refused"))
        with self.assertRaises(SystemExit):
            client.resolve_model()

    def test_coord_scale_reaches_schema(self) -> None:
        """--coord-scale 이 JSON 스키마 상한까지 전달되는지 본다."""
        self.assertEqual(
            vision_game_agent.game2_schema(500)["properties"]["gap_y"]["maximum"], 500
        )
        self.assertEqual(
            vision_game_agent.game1_schema()["properties"]["1"]["items"]["maximum"], 1000
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
