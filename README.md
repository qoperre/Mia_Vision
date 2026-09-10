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

에이전트에는 별도 파이썬 패키지가 필요합니다. 처음 한 번만 설치합니다.

```powershell
pip install -r requirements-games.txt
```

Chrome은 `C:\Program Files\Google\Chrome\Application\chrome.exe`에 설치되어 있어야 합니다.

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

## 원격 포드 백엔드 (Qwen3-VL-8B)

로컬 `Qwen3-VL-2B`는 8GB VRAM에서 빠르지만 게임 화면 이해와 좌표 인식 품질이 한계입니다.
같은 OpenAI 호환 API를 쓰므로 RunPod H200 포드의 `Qwen3-VL-8B-Instruct`(bf16 약 16GB)로 그대로 갈아끼울 수 있습니다(`plan.md` §11-8).

포드에서 vLLM 기동(비전 포트는 8092):

```bash
vllm serve Qwen/Qwen3-VL-8B-Instruct \
  --served-model-name mia-vl \
  --port 8092 \
  --gpu-memory-utilization 0.13
```

방송 PC에서 SSH 터널을 엽니다. 서버는 포드 내부에만 바인딩되므로 터널이 유일한 통로입니다.

```powershell
ssh -N -L 8092:127.0.0.1:8092 -p <포드포트> root@<포드IP>
```

에이전트를 원격 백엔드로 실행:

```powershell
python .\agents\vision_game_agent.py all --api-url http://127.0.0.1:8092 --model mia-vl
```

- `--api-url` 기본값은 로컬 `http://127.0.0.1:8080`이라 인자를 안 주면 지금까지와 똑같이 동작합니다.
- 시작할 때 `/v1/models`를 한 번 조회합니다. 지정한 모델이 목록에 없으면 서버가 서빙하는 이름으로 자동 교정하고 경고 한 줄을 남기며, 조회 자체가 실패하면 즉시 종료합니다(추론 타임아웃 60초를 기다리지 않습니다).
- 인증이 걸린 엔드포인트라면 `--api-key <키>`를 주면 `Authorization: Bearer` 헤더가 붙습니다.
- 좌표 정규화 기준은 `--coord-scale`(기본 1000)입니다. Qwen3-VL 계열은 0~1000이지만 **다른 계열 모델로 바꾸면 실측이 먼저입니다.** 게임 1 결과의 `qwen_predictions_px`와 `cv_centers_px`가 어긋나면 이 값을 의심하세요.

### 로컬 2B와 A/B 하는 법

기존 벤치마크를 그대로 씁니다. **시드를 고정하고** 두 번 돌린 뒤 결과 JSON을 비교하면 됩니다.
결과 파일 이름은 시드로만 정해지므로 먼저 돌린 쪽을 복사해 두어야 덮어쓰지 않습니다.

```powershell
# A: 로컬 2B
.\scripts\run_game_agent.ps1 -Game all -Seed 20260714
Copy-Item .\tests\game_results\latest.json .\tests\game_results\ab_local_2b.json

# B: 포드 8B (터널이 열린 상태)
python .\agents\vision_game_agent.py all --api-url http://127.0.0.1:8092 --model mia-vl --seed 20260714
Copy-Item .\tests\game_results\latest.json .\tests\game_results\ab_pod_8b.json
```

각 결과에는 어느 모델이 만든 값인지 `model` 필드가 들어갑니다. 볼 지표:

| 게임 | 지표 | 의미 |
|---|---|---|
| 1 | `assignment_total_error` | 예측 좌표와 실제 원 중심의 총 오차(px). 낮을수록 좋음 |
| 1 | `assignment_margin` | 정답 배치와 차순위 배치의 거리 차. 클수록 자신 있는 인식 |
| 1 | `qwen_latency_seconds` | 호출 1회 지연. 원격은 네트워크 왕복이 더해짐 |
| 2 | `accepted_qwen_audits` / `qwen_calls` | CV 관측과 일치해 채택된 비율 |
| 2 | `score`, `passed` | 최종 성적(제어는 CV가 하므로 보조 지표) |

게임 2의 비행 제어는 CV가 담당하고 모델 출력은 자문 역할이라, 8B 효과는 게임 1의 좌표 오차에서 더 뚜렷하게 보입니다.

**아직 실측 안 된 지점**: 구조화 JSON 출력 경로. 이 llama.cpp 빌드는 요청 최상위 `json_schema`를,
vLLM은 OpenAI 표준 `response_format`을 봅니다. 에이전트는 **둘 다 실어 보내** 백엔드가 아는 쪽을 쓰게 합니다.
포드 첫 실행에서 `qwen_raw`가 JSON이 아니거나 400이 나면 이 부분을 먼저 의심하세요.
