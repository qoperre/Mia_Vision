"""true_runs가 예전 손코딩 상태머신과 같은 구간을 내는지 확인한다.

detect_flappy의 열 스캔과 행 스캔이 이 함수 하나로 합쳐졌으므로, 동등성이 깨지면
파이프 간격 판정이 조용히 틀어진다. 실행: python tests/test_true_runs.py
"""

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agents.vision_game_agent import true_runs  # noqa: E402


def legacy_runs(flags: np.ndarray) -> list[tuple[int, int]]:
    """삭제된 상태머신 원본. 비교 기준으로만 남긴다."""
    found: list[tuple[int, int]] = []
    start: int | None = None
    for index, active in enumerate(flags):
        if active and start is None:
            start = index
        elif not active and start is not None:
            found.append((start, index - 1))
            start = None
    if start is not None:
        found.append((start, len(flags) - 1))
    return found


def main() -> None:
    assert true_runs(np.array([False, True, True, False])) == [(1, 2)]
    assert true_runs(np.array([True, True])) == [(0, 1)]
    assert true_runs(np.array([False, False])) == []
    assert true_runs(np.array([True, False, True])) == [(0, 0), (2, 2)]

    rng = np.random.default_rng(42)
    for _ in range(500):
        flags = rng.random(rng.integers(1, 40)) < rng.random()
        assert true_runs(flags) == legacy_runs(flags), flags.astype(int).tolist()
    print("test_true_runs OK")


if __name__ == "__main__":
    main()
