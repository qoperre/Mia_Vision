from __future__ import annotations

import argparse
import base64
import io
import itertools
import json
import math
import statistics
import threading
import time
from concurrent.futures import Future, ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import cv2
import numpy as np
import requests
from PIL import Image
from selenium import webdriver
from selenium.webdriver.chrome.options import Options


ROOT = Path(__file__).resolve().parents[1]
CHROME = Path(r"C:\Program Files\Google\Chrome\Application\chrome.exe")
DEFAULT_API = "http://127.0.0.1:8080"
RESULT_DIR = ROOT / "tests" / "game_results"
ARTIFACT_DIR = ROOT / "tests" / "game_artifacts"


def ensure_dirs() -> None:
    RESULT_DIR.mkdir(parents=True, exist_ok=True)
    ARTIFACT_DIR.mkdir(parents=True, exist_ok=True)


def png_to_bgr(png: bytes) -> np.ndarray:
    data = np.frombuffer(png, dtype=np.uint8)
    image = cv2.imdecode(data, cv2.IMREAD_COLOR)
    if image is None:
        raise RuntimeError("Could not decode browser screenshot")
    return image


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")


class QwenVisionClient:
    def __init__(self, base_url: str = DEFAULT_API, timeout: int = 60) -> None:
        self.url = base_url.rstrip("/") + "/v1/chat/completions"
        self.timeout = timeout
        self.session = requests.Session()
        self.lock = threading.Lock()

    def analyze(
        self,
        image_png: bytes,
        prompt: str,
        schema: dict[str, Any],
        max_tokens: int = 100,
    ) -> tuple[dict[str, Any], float, str]:
        encoded = base64.b64encode(image_png).decode("ascii")
        payload = {
            "model": "qwen3-vl-2b",
            "messages": [
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "image_url",
                            "image_url": {"url": f"data:image/png;base64,{encoded}"},
                        },
                        {"type": "text", "text": prompt},
                    ],
                }
            ],
            "temperature": 0,
            "seed": 42,
            "max_tokens": max_tokens,
            "stream": False,
            # This is the grammar path verified with llama.cpp b9996.
            "json_schema": schema,
        }
        started = time.perf_counter()
        with self.lock:
            response = self.session.post(self.url, json=payload, timeout=self.timeout)
        latency = time.perf_counter() - started
        response.raise_for_status()
        raw = response.json()["choices"][0]["message"]["content"]
        return json.loads(raw), latency, raw


def make_driver(headed: bool, width: int, height: int) -> webdriver.Chrome:
    if not CHROME.exists():
        raise FileNotFoundError(f"Chrome is missing: {CHROME}")
    options = Options()
    options.binary_location = str(CHROME)
    if not headed:
        options.add_argument("--headless=new")
    options.add_argument(f"--window-size={width},{height}")
    options.add_argument("--force-device-scale-factor=1")
    options.add_argument("--hide-scrollbars")
    options.add_argument("--disable-background-timer-throttling")
    options.add_argument("--disable-renderer-backgrounding")
    options.add_argument("--disable-backgrounding-occluded-windows")
    options.add_argument("--no-first-run")
    options.add_argument("--no-default-browser-check")
    options.set_capability("goog:loggingPrefs", {"browser": "ALL"})
    driver = webdriver.Chrome(options=options)
    driver.execute_cdp_cmd(
        "Emulation.setTouchEmulationEnabled", {"enabled": True, "maxTouchPoints": 1}
    )
    return driver


def dispatch_touch(driver: webdriver.Chrome, x: float, y: float) -> None:
    point = {"x": float(x), "y": float(y), "radiusX": 2, "radiusY": 2, "force": 1}
    driver.execute_cdp_cmd(
        "Input.dispatchTouchEvent", {"type": "touchStart", "touchPoints": [point]}
    )
    driver.execute_cdp_cmd(
        "Input.dispatchTouchEvent", {"type": "touchEnd", "touchPoints": []}
    )


def element_rect(driver: webdriver.Chrome, selector: str) -> dict[str, float]:
    return driver.execute_script(
        "const r=document.querySelector(arguments[0]).getBoundingClientRect();"
        "return {x:r.x,y:r.y,width:r.width,height:r.height};",
        selector,
    )


def save_png(path: Path, data: bytes) -> None:
    path.write_bytes(data)


def upscale_png(png: bytes, factor: int = 2) -> bytes:
    image = Image.open(io.BytesIO(png)).convert("RGB")
    resized = image.resize((image.width * factor, image.height * factor), Image.Resampling.BICUBIC)
    output = io.BytesIO()
    resized.save(output, format="PNG", optimize=True)
    return output.getvalue()


def detect_white_circles(png: bytes) -> list[tuple[float, float]]:
    image = png_to_bgr(png)
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    mask = cv2.inRange(gray, 238, 255)
    mask = cv2.morphologyEx(
        mask, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (9, 9))
    )
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    centers: list[tuple[float, float]] = []
    for contour in contours:
        area = cv2.contourArea(contour)
        if not 1500 <= area <= 16000:
            continue
        x, y, width, height = cv2.boundingRect(contour)
        if not 0.72 <= width / max(height, 1) <= 1.38:
            continue
        perimeter = cv2.arcLength(contour, True)
        circularity = 4 * math.pi * area / max(perimeter * perimeter, 1)
        if circularity < 0.58:
            continue
        centers.append((x + width / 2, y + height / 2))
    centers.sort(key=lambda point: (point[1], point[0]))
    return centers


def optimal_mapping(
    predictions: dict[int, tuple[float, float]],
    centers: list[tuple[float, float]],
) -> tuple[dict[int, tuple[float, float]], float, float]:
    numbers = sorted(predictions)
    if len(numbers) != len(centers):
        raise RuntimeError(
            f"Prediction/component count mismatch: {len(numbers)} vs {len(centers)}"
        )
    candidates: list[tuple[float, tuple[tuple[float, float], ...]]] = []
    for permutation in itertools.permutations(centers):
        cost = sum(
            (predictions[number][0] - center[0]) ** 2
            + (predictions[number][1] - center[1]) ** 2
            for number, center in zip(numbers, permutation)
        )
        candidates.append((cost, permutation))
    candidates.sort(key=lambda item: item[0])
    best_cost, best = candidates[0]
    second_cost = candidates[1][0] if len(candidates) > 1 else best_cost
    return dict(zip(numbers, best)), math.sqrt(best_cost), math.sqrt(second_cost) - math.sqrt(best_cost)


def nearest_unmatched(
    centers: list[tuple[float, float]],
    known: dict[int, tuple[float, float]],
    tolerance: float = 9,
) -> tuple[float, float] | None:
    unmatched = list(centers)
    for point in known.values():
        if not unmatched:
            return None
        distances = [math.dist(point, candidate) for candidate in unmatched]
        index = int(np.argmin(distances))
        if distances[index] > tolerance:
            return None
        unmatched.pop(index)
    if len(unmatched) != 1:
        return None
    return unmatched[0]


def game1_schema() -> dict[str, Any]:
    coordinate = {
        "type": "array",
        "items": {"type": "integer", "minimum": 0, "maximum": 1000},
        "minItems": 2,
        "maxItems": 2,
    }
    return {
        "type": "object",
        "properties": {str(number): coordinate for number in range(1, 5)},
        "required": [str(number) for number in range(1, 5)],
        "additionalProperties": False,
    }


def play_game1(
    client: QwenVisionClient,
    seed: int,
    headed: bool,
    save_artifacts: bool = True,
) -> dict[str, Any]:
    driver = make_driver(headed=headed, width=1200, height=850)
    qwen_calls = 0
    try:
        url = (ROOT / "games" / "game1.html").as_uri()
        driver.get(url)
        driver.execute_script("window.resetGame1({seed: arguments[0]});", seed)
        arena = driver.find_element("id", "arena")
        time.sleep(0.03)
        initial_png = arena.screenshot_as_png
        centers = detect_white_circles(initial_png)
        if len(centers) != 4:
            raise RuntimeError(f"Expected four white circles, detected {len(centers)}")

        qwen_png = upscale_png(initial_png, factor=2)
        prompt = (
            "Read the four white circular number buttons. Return the center of each digit "
            "1, 2, 3, and 4 as [x,y] normalized from 0 to 1000 relative to this image. "
            "Origin is top-left. Inspect the rendered pixels; do not guess a layout."
        )
        qwen, vision_latency, raw = client.analyze(
            qwen_png, prompt, game1_schema(), max_tokens=100
        )
        qwen_calls += 1
        height, width = png_to_bgr(initial_png).shape[:2]
        predictions = {
            number: (qwen[str(number)][0] * width / 1000, qwen[str(number)][1] * height / 1000)
            for number in range(1, 5)
        }
        known, assignment_error, assignment_margin = optimal_mapping(predictions, centers)
        arena_box = element_rect(driver, "#arena")

        trace: list[dict[str, Any]] = []
        tracker_started = time.perf_counter()
        for expected in range(1, 51):
            if expected not in known:
                raise RuntimeError(f"Tracker lost number {expected}; known={sorted(known)}")
            local_x, local_y = known.pop(expected)
            dispatch_touch(driver, arena_box["x"] + local_x, arena_box["y"] + local_y)

            spawned = expected + 4
            if spawned <= 50:
                frame = arena.screenshot_as_png
                visible = detect_white_circles(frame)
                expected_count = min(4, 51 - expected)
                if len(visible) != expected_count:
                    # A single short retry handles a paint arriving between CDP touch and screenshot.
                    time.sleep(0.006)
                    frame = arena.screenshot_as_png
                    visible = detect_white_circles(frame)
                new_center = nearest_unmatched(visible, known)
                if new_center is None:
                    raise RuntimeError(
                        f"Could not identify spawned {spawned}: visible={visible}, known={known}"
                    )
                known[spawned] = new_center
            trace.append(
                {
                    "number": expected,
                    "touch": [round(local_x, 2), round(local_y, 2)],
                    "tracked": sorted(known),
                }
            )

        tracker_seconds = time.perf_counter() - tracker_started
        state = driver.execute_script("return window.game1State;")
        browser_logs = driver.get_log("browser")
        final_png = driver.get_screenshot_as_png()
        passed = bool(
            state["completed"]
            and state["errors"] == 0
            and state["elapsedMs"] < 10000
            and state["correctClicks"] == 50
        )
        result = {
            "game": 1,
            "passed": passed,
            "seed": seed,
            "elapsed_ms": round(float(state["elapsedMs"]), 3),
            "errors": int(state["errors"]),
            "wrong_number_clicks": int(state["wrongNumberClicks"]),
            "wrong_position_clicks": int(state["wrongPositionClicks"]),
            "correct_clicks": int(state["correctClicks"]),
            "qwen_calls": qwen_calls,
            "qwen_latency_seconds": round(vision_latency, 4),
            "qwen_raw": raw,
            "qwen_predictions_px": {str(k): [round(v[0], 2), round(v[1], 2)] for k, v in predictions.items()},
            "cv_centers_px": [[round(x, 2), round(y, 2)] for x, y in centers],
            "assignment_total_error": round(assignment_error, 3),
            "assignment_margin": round(assignment_margin, 3),
            "tracker_seconds": round(tracker_seconds, 4),
            "browser_console_errors": [entry for entry in browser_logs if entry["level"] == "SEVERE"],
            "trace": trace,
        }
        if save_artifacts:
            save_png(ARTIFACT_DIR / f"game1_initial_seed_{seed}.png", initial_png)
            save_png(ARTIFACT_DIR / f"game1_final_seed_{seed}.png", final_png)
            write_json(RESULT_DIR / f"game1_seed_{seed}.json", result)
        return result
    finally:
        driver.quit()


@dataclass
class FlappyObservation:
    bird_x: float
    bird_y: float
    gap_x: float | None
    gap_y: float | None
    width: int
    height: int


def detect_flappy(png: bytes, previous_gap: tuple[float, float] | None = None) -> FlappyObservation:
    image = png_to_bgr(png)
    height, width = image.shape[:2]
    hsv = cv2.cvtColor(image, cv2.COLOR_BGR2HSV)
    yellow = cv2.inRange(hsv, np.array([18, 135, 175]), np.array([38, 255, 255]))

    # Bird: anchor on its unique orange beak/wing, then collect nearby yellow body
    # pixels. This prevents the yellow NEXT label from impersonating the bird when a
    # pipe crosses the bird's horizontal lane.
    orange = cv2.inRange(hsv, np.array([3, 120, 140]), np.array([22, 255, 255]))
    orange[:, : int(width * 0.10)] = 0
    orange[:, int(width * 0.43) :] = 0
    orange[: int(height * 0.10), :] = 0
    orange[int(height * 0.89) :, :] = 0
    orange_y, orange_x = np.nonzero(orange)
    bird_x: float
    bird_y: float
    if orange_x.size >= 8:
        anchor_x = float(orange_x.mean())
        anchor_y = float(orange_y.mean())
        yy, xx = np.ogrid[:height, :width]
        local_body = (yellow > 0) & ((xx - anchor_x) ** 2 + (yy - anchor_y) ** 2 <= 45**2)
        body_y, body_x = np.nonzero(local_body)
        if body_x.size >= 25:
            bird_x = float(body_x.mean())
            bird_y = float(body_y.mean())
        else:
            bird_x = anchor_x + width * 0.010
            bird_y = anchor_y - height * 0.010
    else:
        bird_x = math.nan
        bird_y = math.nan

    # Yellow-component fallback handles extreme antialiasing or color-management
    # differences, while the orange path above is used in normal play.
    bird_roi = yellow.copy()
    bird_roi[:, : int(width * 0.10)] = 0
    bird_roi[:, int(width * 0.43) :] = 0
    bird_roi[: int(height * 0.10), :] = 0
    bird_roi[int(height * 0.89) :, :] = 0
    # The black outline/wing splits the yellow body into two islands after browser
    # scaling. Closing them first gives one stable centroid.
    bird_roi = cv2.morphologyEx(
        bird_roi, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (9, 9))
    )
    contours, _ = cv2.findContours(bird_roi, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    bird_candidates: list[tuple[float, float, float]] = []
    for contour in contours:
        area = cv2.contourArea(contour)
        if 70 <= area <= 4500:
            moments = cv2.moments(contour)
            if moments["m00"]:
                x = moments["m10"] / moments["m00"]
                y = moments["m01"] / moments["m00"]
                bird_candidates.append((area, x, y))
    if math.isnan(bird_x) and not bird_candidates:
        raise RuntimeError("Bird was not detected in rendered frame")
    if math.isnan(bird_x):
        _, bird_x, bird_y = min(
            bird_candidates,
            key=lambda item: abs(item[1] / width - 0.237) - min(item[0], 1200) / 5000,
        )

    # Derive the gap from the cyan pipe geometry. The yellow NEXT label can become
    # longer than its dashed line when a pipe is close to the bird, so selecting the
    # strongest yellow row is not stable enough for collision-critical control.
    cyan = cv2.inRange(hsv, np.array([82, 125, 145]), np.array([103, 255, 255]))
    cyan[int(height * 0.91) :, :] = 0
    column_counts = np.count_nonzero(cyan, axis=0)
    active_columns = column_counts >= max(8, int(height * 0.025))

    groups: list[tuple[int, int]] = []
    start: int | None = None
    for index, active in enumerate(active_columns):
        if active and start is None:
            start = index
        elif not active and start is not None:
            if index - start >= int(width * 0.045):
                groups.append((start, index - 1))
            start = None
    if start is not None and width - start >= int(width * 0.045):
        groups.append((start, width - 1))

    gap_x: float | None = None
    gap_y: float | None = None
    pipe_candidates: list[tuple[float, float, float]] = []
    for left, right in groups:
        if right < bird_x - width * 0.025:
            continue
        inset = max(1, int((right - left + 1) * 0.18))
        pipe_region = cyan[:, left + inset : right - inset + 1]
        if pipe_region.shape[1] < 4:
            continue
        row_counts = np.count_nonzero(pipe_region, axis=1)
        present = row_counts >= max(3, int(pipe_region.shape[1] * 0.10))
        true_rows = np.flatnonzero(present)
        if true_rows.size < 2:
            continue
        first, last = int(true_rows[0]), int(true_rows[-1])
        runs: list[tuple[int, int]] = []
        run_start: int | None = None
        for row in range(first, last + 1):
            if not present[row] and run_start is None:
                run_start = row
            elif present[row] and run_start is not None:
                runs.append((run_start, row - 1))
                run_start = None
        if run_start is not None:
            runs.append((run_start, last))
        if not runs:
            continue
        gap_top, gap_bottom = max(runs, key=lambda run: run[1] - run[0])
        if gap_bottom - gap_top < height * 0.16:
            continue
        center_x = (left + right) / 2
        center_y = (gap_top + gap_bottom) / 2
        pipe_candidates.append((left, center_x, center_y))

    if pipe_candidates:
        _, gap_x, gap_y = min(pipe_candidates, key=lambda candidate: candidate[0])

    if gap_y is None and previous_gap is not None:
        gap_x, gap_y = previous_gap
    return FlappyObservation(bird_x, bird_y, gap_x, gap_y, width, height)


def game2_schema() -> dict[str, Any]:
    return {
        "type": "object",
        "properties": {
            "bird_y": {"type": "integer", "minimum": 0, "maximum": 1000},
            "gap_y": {"type": "integer", "minimum": 0, "maximum": 1000},
        },
        "required": ["bird_y", "gap_y"],
        "additionalProperties": False,
    }


def analyze_flappy_frame(
    client: QwenVisionClient, png: bytes
) -> tuple[dict[str, Any], float, str]:
    prompt = (
        "Find the yellow bird center y and the CYAN PIPE OPENING center y. The opening is "
        "the empty horizontal corridor between the top and bottom cyan pipe, marked by a "
        "dashed yellow line. Ignore text. Return y normalized 0 top to 1000 bottom."
    )
    return client.analyze(png, prompt, game2_schema(), max_tokens=48)


def play_game2(
    client: QwenVisionClient,
    seed: int,
    headed: bool,
    target: int = 21,
    max_seconds: float = 75,
    save_artifacts: bool = True,
) -> dict[str, Any]:
    driver = make_driver(headed=headed, width=1000, height=700)
    executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="qwen-flappy")
    pending: Future[tuple[dict[str, Any], float, str]] | None = None
    qwen_audits: list[dict[str, Any]] = []
    qwen_calls = 0
    try:
        url = (ROOT / "games" / "game2.html").as_uri() + f"?seed={seed}"
        driver.get(url)
        canvas = driver.find_element("id", "game")
        canvas_box = element_rect(driver, "#game")
        dispatch_touch(
            driver,
            canvas_box["x"] + canvas_box["width"] * 0.5,
            canvas_box["y"] + canvas_box["height"] * 0.5,
        )

        started = time.perf_counter()
        last_frame_at = started
        last_bird_y: float | None = None
        filtered_vy = 0.0
        last_flap = started
        previous_gap: tuple[float, float] | None = None
        previous_observed_gap: tuple[float, float] | None = None
        last_submitted_gap: tuple[float, float] | None = None
        model_gap_y: float | None = None
        model_gap_received_at = 0.0
        model_gap_generation = 0
        frame_count = 0
        touches = 1
        detection_failures = 0
        trace: list[dict[str, Any]] = []
        reached = False
        gameover = False
        first_play_png: bytes | None = None

        while time.perf_counter() - started < max_seconds:
            loop_started = time.perf_counter()
            png = canvas.screenshot_as_png
            if first_play_png is None:
                first_play_png = png
            frame_count += 1
            now = time.perf_counter()

            # Read-only referee check before any new touch. Without this, a touch issued
            # on the game-over frame would legitimately restart the game and hide the
            # collision from the benchmark. State values never feed the flight policy.
            referee_state = driver.execute_script("return window.game2State.get();")
            if referee_state["status"] == "gameover":
                gameover = True
                break
            if int(referee_state["score"]) >= target:
                reached = True
                break

            try:
                observation = detect_flappy(png, previous_gap)
                detection_failures = 0
            except RuntimeError:
                detection_failures += 1
                if detection_failures > 8:
                    gameover = True
                    break
                time.sleep(0.025)
                continue

            if observation.gap_x is not None and observation.gap_y is not None:
                new_gap = (observation.gap_x, observation.gap_y)
                # A pipe instance moves left. A large rightward jump marks the next pipe.
                is_new_pipe = (
                    last_submitted_gap is None
                    or (
                        previous_observed_gap is not None
                        and new_gap[0] > previous_observed_gap[0] + observation.width * 0.18
                    )
                )
                previous_observed_gap = new_gap
                previous_gap = new_gap
                if is_new_pipe and pending is None:
                    pending = executor.submit(analyze_flappy_frame, client, png)
                    last_submitted_gap = new_gap
                    qwen_calls += 1
                    model_gap_generation += 1

            if pending is not None and pending.done():
                try:
                    qwen, latency, raw = pending.result()
                    qwen_gap_y = qwen["gap_y"] * observation.height / 1000
                    qwen_bird_y = qwen["bird_y"] * observation.height / 1000
                    cv_gap_y = previous_gap[1] if previous_gap is not None else None
                    accepted = cv_gap_y is not None and abs(qwen_gap_y - cv_gap_y) <= observation.height * 0.12
                    if accepted:
                        model_gap_y = qwen_gap_y
                        model_gap_received_at = now
                    qwen_audits.append(
                        {
                            "generation": model_gap_generation,
                            "latency_seconds": round(latency, 4),
                            "raw": raw,
                            "qwen_bird_y": round(qwen_bird_y, 2),
                            "qwen_gap_y": round(qwen_gap_y, 2),
                            "cv_bird_y_at_receive": round(observation.bird_y, 2),
                            "cv_gap_y_at_receive": round(cv_gap_y, 2) if cv_gap_y is not None else None,
                            "accepted": accepted,
                        }
                    )
                except Exception as error:  # Keep real-time control alive if advisory inference fails.
                    qwen_audits.append({"error": repr(error)})
                pending = None

            dt = max(0.001, now - last_frame_at)
            if last_bird_y is not None:
                measured_vy = (observation.bird_y - last_bird_y) / dt
                filtered_vy = filtered_vy * 0.62 + measured_vy * 0.38
            last_bird_y = observation.bird_y
            last_frame_at = now

            if previous_gap is None:
                target_y = observation.height * 0.50
            else:
                target_y = previous_gap[1]
            # Accepted Qwen geometry is blended only while it refers to the current gap.
            if model_gap_y is not None and now - model_gap_received_at < 2.2:
                target_y = target_y * 0.78 + model_gap_y * 0.22

            cooldown = now - last_flap
            below_target = observation.bird_y > target_y + observation.height * 0.018
            descending_fast = (
                filtered_vy > observation.height * 0.18
                and observation.bird_y > target_y - observation.height * 0.072
            )
            emergency = observation.bird_y > target_y + observation.height * 0.105
            should_flap = cooldown >= 0.205 and (below_target or descending_fast or emergency)
            if should_flap:
                dispatch_touch(
                    driver,
                    canvas_box["x"] + observation.bird_x,
                    canvas_box["y"] + observation.bird_y,
                )
                last_flap = time.perf_counter()
                touches += 1

            if should_flap or frame_count % 5 == 0:
                trace.append(
                    {
                        "t": round(now - started, 3),
                        "bird_y": round(observation.bird_y, 2),
                        "gap_y": round(target_y, 2),
                        "vy_px_s": round(filtered_vy, 2),
                        "cooldown": round(cooldown, 3),
                        "below_target": bool(below_target),
                        "descending_fast": bool(descending_fast),
                        "emergency": bool(emergency),
                        "flap": should_flap,
                    }
                )

            # Keep screenshot/CV cadence around 20 Hz without blocking Qwen inference.
            remaining = 0.045 - (time.perf_counter() - loop_started)
            if remaining > 0:
                time.sleep(remaining)

        wall_seconds = time.perf_counter() - started
        state = driver.execute_script("return window.game2State.get();")
        final_png = canvas.screenshot_as_png
        browser_logs = driver.get_log("browser")
        passed = bool(int(state["score"]) >= 20 and not gameover)
        result = {
            "game": 2,
            "passed": passed,
            "seed": seed,
            "score": int(state["score"]),
            "target": 20,
            "requested_stop_score": target,
            "status": state["status"],
            "target_reached": bool(state["targetReached"]),
            "game_elapsed_seconds": float(state["elapsed"]),
            "wall_seconds": round(wall_seconds, 3),
            "touches": touches,
            "frames_processed": frame_count,
            "effective_cv_fps": round(frame_count / max(wall_seconds, 0.001), 2),
            "qwen_calls": qwen_calls,
            "qwen_audits": qwen_audits,
            "accepted_qwen_audits": sum(1 for item in qwen_audits if item.get("accepted")),
            "detection_failures_at_end": detection_failures,
            "browser_console_errors": [entry for entry in browser_logs if entry["level"] == "SEVERE"],
            "trace": trace,
        }
        if save_artifacts:
            if first_play_png is not None:
                save_png(ARTIFACT_DIR / f"game2_first_seed_{seed}.png", first_play_png)
            save_png(ARTIFACT_DIR / f"game2_final_seed_{seed}.png", final_png)
            write_json(RESULT_DIR / f"game2_seed_{seed}.json", result)
        return result
    finally:
        if pending is not None:
            pending.cancel()
        executor.shutdown(wait=False, cancel_futures=True)
        driver.quit()


def print_summary(result: dict[str, Any]) -> None:
    if result["game"] == 1:
        print(
            f"GAME1 passed={result['passed']} elapsed_ms={result['elapsed_ms']} "
            f"errors={result['errors']} qwen_latency={result['qwen_latency_seconds']}s"
        )
    else:
        print(
            f"GAME2 passed={result['passed']} score={result['score']} "
            f"wall={result['wall_seconds']}s cv_fps={result['effective_cv_fps']} "
            f"qwen_calls={result['qwen_calls']} accepted={result['accepted_qwen_audits']}"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description="Pixel-only Qwen/CV game interaction agent")
    parser.add_argument("game", choices=["game1", "game2", "all"])
    parser.add_argument("--api", default=DEFAULT_API)
    parser.add_argument("--seed", type=int, default=20260714)
    parser.add_argument("--headed", action="store_true")
    parser.add_argument("--game2-target", type=int, default=21)
    parser.add_argument("--game2-timeout", type=float, default=75)
    args = parser.parse_args()

    ensure_dirs()
    health = requests.get(args.api.rstrip("/") + "/health", timeout=5)
    health.raise_for_status()
    if health.json().get("status") != "ok":
        raise RuntimeError(f"Qwen server is not ready: {health.text}")
    client = QwenVisionClient(args.api)

    results: list[dict[str, Any]] = []
    if args.game in {"game1", "all"}:
        result = play_game1(client, args.seed, args.headed)
        results.append(result)
        print_summary(result)
    if args.game in {"game2", "all"}:
        result = play_game2(
            client,
            args.seed,
            args.headed,
            target=args.game2_target,
            max_seconds=args.game2_timeout,
        )
        results.append(result)
        print_summary(result)

    combined = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "all_passed": all(result["passed"] for result in results),
        "results": results,
    }
    write_json(RESULT_DIR / "latest.json", combined)
    return 0 if combined["all_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
