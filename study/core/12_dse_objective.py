# 学习注： 来源 PLENA-Prefill/analytic_models/dse/objective.py，原始行 1–71。
# 学习注： 这是核心阅读副本；运行仍用原目录及其依赖。只新增注释，没有修改逻辑。
"""Formal latency-energy objective schema for Qwen3 prefill exploration."""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any


# 学习注：两个目标均最小化：prefill 延迟与能量；没有把 accuracy 当作越高越好的第三目标。
OBJECTIVE_DIRECTIONS = ("minimize", "minimize")
OBJECTIVE_NORMALIZATION = "identity"
OBJECTIVE_FIELDS = (
    "prefill_latency_ms",
    "prefill_system_energy_mj_ideal",
)


# 学习注：面积是可行性限制；缺失或非有限值按不可行处理。
def area_budget_constraints(trial: Any) -> tuple[float]:
    """Return the durable area constraint at Optuna's callback boundary."""

    constraint = trial.user_attrs.get(
        "area_budget_constraint_mm2",
        trial.user_attrs.get("a100_area_constraint_mm2"),
    )
    if constraint is None or not math.isfinite(float(constraint)):
        return (math.inf,)
    return (float(constraint),)


@dataclass(frozen=True)
# 学习注：传给 Optuna 的值仍是原始 ms/mJ。
class ObjectiveValues:
    prefill_latency_ms: float
    prefill_system_energy_mj_ideal: float

    @property
    # 学习注：历史命名 normalized 不代表除以 A100；这会直接影响结果解释。
    def normalized_latency(self) -> float:
        """Compatibility alias retained for historical consumers."""

        return self.prefill_latency_ms

    @property
    def normalized_energy(self) -> float:
        """Compatibility alias retained for historical consumers."""

        return self.prefill_system_energy_mj_ideal

    # 学习注：优化器比较的是这个二元组，accuracy/HBM 等约束在外层筛选。
    def as_optuna_values(self) -> tuple[float, float]:
        return (
            float(self.prefill_latency_ms),
            float(self.prefill_system_energy_mj_ideal),
        )

    @classmethod
    def from_trial_record(cls, record: dict[str, Any]) -> ObjectiveValues:
        return cls(
            prefill_latency_ms=float(
                record.get(
                    "prefill_latency_ms",
                    record.get("normalized_latency", record["latency_ms"]),
                )
            ),
            prefill_system_energy_mj_ideal=float(
                record.get(
                    "prefill_system_energy_mj_ideal",
                    record.get(
                        "normalized_energy",
                        record["system_energy_nominal_mj"],
                    ),
                )
            ),
        )
