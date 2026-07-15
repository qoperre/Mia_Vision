# Mia Vision 로컬 Qwen3-VL

RTX 2080 SUPER 8GB에서 속도를 우선한 로컬 비전 언어 모델 환경입니다.

## 설치된 구성

- llama.cpp `b9996`, Windows CUDA 12.4 빌드
- `Qwen3VL-2B-Instruct-Q4_K_M.gguf`
- `mmproj-Qwen3VL-2B-Instruct-F16.gguf`
- 기본 컨텍스트 4096, 전체 GPU 오프로딩, Flash Attention
- 게임/좌표 인식을 위해 이미지 토큰을 1024로 고정
- 서버는 보안을 위해 `127.0.0.1:8080`에만 바인딩

## 서버 사용

PowerShell에서 이 폴더로 이동한 뒤 실행합니다.

```powershell
.\scripts\start_server.ps1
```

브라우저 UI: <http://127.0.0.1:8080>

OpenAI 호환 API: `http://127.0.0.1:8080/v1/chat/completions`

이미지에 바로 질문하려면:

```powershell
.\scripts\ask_image.ps1 `
  -ImagePath .\tests\images\qwen_demo.jpeg `
  -Prompt '사진을 한국어 한 문장으로 설명해 줘.'
```

서버 종료:

```powershell
.\scripts\stop_server.ps1
```

## 검증 재실행

서버가 실행 중인 상태에서:

```powershell
.\scripts\run_validation.ps1
```

결과는 `tests/results/validation.json`, 서버 로그는 `tests/logs/`에 저장됩니다.

구조화 JSON 출력이 필요하면 이 llama.cpp 빌드에서는 요청 최상위에 `json_schema`를 넣는 방식이 검증되었습니다. 멀티모달 요청의 `response_format`은 이번 검증에서 제약이 적용되지 않았습니다.

## 속도와 품질 조절

- 일반 이미지: 긴 변 768~1024px 권장
- 작은 글씨 OCR: 원본 해상도 또는 문서 영역 크롭 권장
- 더 빠른 이미지 처리가 필요하면 서버 인수에 `--image-max-tokens 512`를 추가할 수 있지만 OCR과 세부 위치 인식 품질이 낮아질 수 있습니다.
- 동시 사용자가 필요하면 `start_server.ps1`의 `-np 1`을 늘릴 수 있지만 8GB 환경에서는 단일 요청 속도와 여유 VRAM을 위해 1로 두었습니다.

## 터치 게임 및 비전 에이전트

게임 선택 화면은 `games/index.html`입니다. 게임은 Chrome에서 파일을 직접 열어도 동작합니다. 로컬 웹 주소로 열려면:

```powershell
.\scripts\start_game_ui.ps1
```

그다음 <http://127.0.0.1:8090>에 접속합니다. 종료는 `.\scripts\stop_game_ui.ps1`입니다.

Qwen/CV 에이전트로 실제 터치를 실행하려면:

```powershell
# 두 게임 통합 검증
.\scripts\run_game_agent.ps1 -Game all

# 브라우저 창을 보면서 게임 1만 실행
.\scripts\run_game_agent.ps1 -Game game1 -Headed

# 게임 2만 실행
.\scripts\run_game_agent.ps1 -Game game2 -Seed 42
```

에이전트 판단은 게임 DOM 좌표를 사용하지 않고 Chrome이 렌더링한 PNG 픽셀만 사용합니다. `game1State`와 `game2State`는 최종 점수·오류·완료 여부를 판정하는 심판 계측에만 사용합니다.

게임 결과는 `tests/game_results/`, 실행 화면은 `tests/game_artifacts/`에 저장됩니다.
