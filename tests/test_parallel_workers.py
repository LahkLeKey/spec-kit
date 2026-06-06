"""Tests for system-aware parallel worker sizing."""

from tests import _parallel
from tests._parallel import compute_recommended_workers, detect_effective_cpu_count


def test_worker_count_cpu_bound_when_memory_is_large():
    settings = compute_recommended_workers(
        cpu_count=8,
        total_memory_bytes=64 * 1024 ** 3,
        available_memory_bytes=16 * 1024 ** 3,
        platform_name="linux",
        max_workers=None,
        tier="medium",
    )
    # cpu_count - 1, capped by linux platform max (8)
    assert settings.workers == 7


def test_worker_count_memory_bound_on_low_memory_system():
    settings = compute_recommended_workers(
        cpu_count=8,
        total_memory_bytes=3 * 1024 ** 3,
        available_memory_bytes=3 * 1024 ** 3,
        platform_name="linux",
        max_workers=None,
        tier="medium",
    )
    # 3 GiB => floor(3 / 1.5) == 2 workers
    assert settings.workers == 2


def test_worker_count_platform_cap_on_windows():
    settings = compute_recommended_workers(
        cpu_count=16,
        total_memory_bytes=64 * 1024 ** 3,
        available_memory_bytes=64 * 1024 ** 3,
        platform_name="win32",
        max_workers=None,
        tier="medium",
    )
    assert settings.workers == 4


def test_worker_count_honors_parallel_max_workers():
    settings = compute_recommended_workers(
        cpu_count=16,
        total_memory_bytes=64 * 1024 ** 3,
        available_memory_bytes=64 * 1024 ** 3,
        platform_name="linux",
        max_workers=3,
        tier="medium",
    )
    assert settings.workers == 3


def test_worker_count_never_below_one():
    settings = compute_recommended_workers(
        cpu_count=1,
        total_memory_bytes=256 * 1024 ** 2,
        available_memory_bytes=128 * 1024 ** 2,
        platform_name="linux",
        max_workers=None,
        tier="medium",
    )
    assert settings.workers == 1


def test_worker_count_uses_total_memory_when_available_unknown():
    settings = compute_recommended_workers(
        cpu_count=8,
        total_memory_bytes=3 * 1024 ** 3,
        available_memory_bytes=None,
        platform_name="linux",
        max_workers=None,
        tier="medium",
    )
    assert settings.workers == 2


def test_low_tier_is_more_conservative_than_high_tier():
    low = compute_recommended_workers(
        cpu_count=12,
        total_memory_bytes=64 * 1024 ** 3,
        available_memory_bytes=64 * 1024 ** 3,
        platform_name="linux",
        max_workers=None,
        tier="low",
    )
    high = compute_recommended_workers(
        cpu_count=12,
        total_memory_bytes=64 * 1024 ** 3,
        available_memory_bytes=64 * 1024 ** 3,
        platform_name="linux",
        max_workers=None,
        tier="high",
    )
    assert low.workers < high.workers


def test_tier_changes_memory_per_worker_budget():
    low = compute_recommended_workers(
        cpu_count=8,
        total_memory_bytes=8 * 1024 ** 3,
        available_memory_bytes=8 * 1024 ** 3,
        platform_name="linux",
        max_workers=None,
        tier="low",
    )
    medium = compute_recommended_workers(
        cpu_count=8,
        total_memory_bytes=8 * 1024 ** 3,
        available_memory_bytes=8 * 1024 ** 3,
        platform_name="linux",
        max_workers=None,
        tier="medium",
    )
    high = compute_recommended_workers(
        cpu_count=8,
        total_memory_bytes=8 * 1024 ** 3,
        available_memory_bytes=8 * 1024 ** 3,
        platform_name="linux",
        max_workers=None,
        tier="high",
    )
    assert low.memory_per_worker_gib > medium.memory_per_worker_gib > high.memory_per_worker_gib


def test_detect_effective_cpu_count_never_below_one():
    assert detect_effective_cpu_count() >= 1


def test_detect_cgroup_cpu_quota_count_v2_parses_cpu_max(monkeypatch):
    def fake_read_text(path):
        values = {
            "/sys/fs/cgroup/cpu.max": "200000 100000",
        }
        return values.get(path)

    monkeypatch.setattr(_parallel, "_read_text", fake_read_text)
    assert _parallel._detect_cgroup_cpu_quota_count() == 2


def test_detect_cgroup_cpu_quota_count_v1_parses_cfs_files(monkeypatch):
    def fake_read_text(path):
        values = {
            "/sys/fs/cgroup/cpu.max": None,
            "/sys/fs/cgroup/cpu/cpu.cfs_quota_us": "300000",
            "/sys/fs/cgroup/cpu/cpu.cfs_period_us": "100000",
        }
        return values.get(path)

    monkeypatch.setattr(_parallel, "_read_text", fake_read_text)
    assert _parallel._detect_cgroup_cpu_quota_count() == 3
