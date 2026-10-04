# 学习注： 来源 PLENA-Prefill/PLENA_Compiler/aten/cost_emitter.py，原始行 2733–2804。
# 学习注： 这是核心阅读副本；运行仍用原目录及其依赖。只新增注释，没有修改逻辑。
@dataclass
# 学习注：每个语义阶段同时记录静态代码量、动态执行次数和能耗动作。
class StageCost:
    static_opcodes: Counter[str] = field(default_factory=Counter)
    dynamic_opcodes: Counter[str] = field(default_factory=Counter)
    energy_actions: list[EnergyAction] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "static_opcodes": dict(sorted(self.static_opcodes.items())),
            "dynamic_opcodes": dict(sorted(self.dynamic_opcodes.items())),
            "static_instruction_count": sum(self.static_opcodes.values()),
            "dynamic_instruction_count": sum(self.dynamic_opcodes.values()),
            "energy_actions": [action.to_dict() for action in self.energy_actions],
        }


@dataclass
# 学习注：把真实编译 schedule 变成可分析数据；不必展开 90k token 的全部张量。
class CostTrace:
    schema_version: ClassVar[int] = 7
    static_opcodes: Counter[str] = field(default_factory=Counter)
    dynamic_opcodes: Counter[str] = field(default_factory=Counter)
    # 学习注：DMA 地址、shape、stride 等信息送给 HBM 模型，不能只用总字节数代替。
    memory_events: list[MemoryEvent] = field(default_factory=list)
    stages: dict[str, StageCost] = field(default_factory=lambda: defaultdict(StageCost))
    # 学习注：保留顺序和循环结构，才能讨论依赖、重叠及 symbolic compression。
    schedule: ScheduleSequence = field(default_factory=ScheduleSequence)
    schedule_unavailable_reasons: Counter[str] = field(default_factory=Counter)
    energy_actions: list[EnergyAction] = field(default_factory=list)
    parallel_kernel_census: list[ParallelKernelCensusEntry] = field(
        default_factory=list
    )
    metadata: dict[str, Any] = field(default_factory=dict)

    @property
    def static_instruction_count(self) -> int:
        return sum(self.static_opcodes.values())

    @property
    # 学习注：一条循环体指令可执行很多次；静态汇编行数不能直接当运行时间。
    def dynamic_instruction_count(self) -> int:
        return sum(self.dynamic_opcodes.values())

    def to_dict(self) -> dict[str, Any]:
        categories: Counter[str] = Counter()
        for opcode, count in self.dynamic_opcodes.items():
            categories[opcode_category(opcode)] += count
        # 学习注：模型没覆盖的 schedule 必须显式暴露；缺失成本不能默认为零。
        unavailable = _schedule_unavailable_counts(self.schedule)
        unavailable_count = sum(unavailable.values())
        ordered_count = max(0, self.dynamic_instruction_count - unavailable_count)
        return {
            "schema_version": self.schema_version,
            **self.metadata,
            "static_instruction_count": self.static_instruction_count,
            "dynamic_instruction_count": self.dynamic_instruction_count,
            "static_opcodes": dict(sorted(self.static_opcodes.items())),
            "dynamic_opcodes": dict(sorted(self.dynamic_opcodes.items())),
            "instruction_categories": dict(sorted(categories.items())),
            "compressed_memory_events": [event.to_dict() for event in self.memory_events],
            "energy_actions": [action.to_dict() for action in self.energy_actions],
            "parallel_kernel_census": [
                entry.to_dict() for entry in self.parallel_kernel_census
            ],
            "stage_breakdown": {name: stage.to_dict() for name, stage in sorted(self.stages.items())},
            "compressed_schedule": self.schedule.to_dict(),
            "schedule_fidelity": ("unavailable" if self.schedule_unavailable_reasons else "ordered_compressed"),
            "schedule_unavailable_reasons": dict(sorted(self.schedule_unavailable_reasons.items())),
            "schedule_coverage": {
                "ordered_dynamic_instructions": ordered_count,
                "unavailable_dynamic_instructions": unavailable_count,
                "ordered_fraction": (
                    1.0 if self.dynamic_instruction_count == 0 else ordered_count / self.dynamic_instruction_count
                ),
                "unavailable_by_reason": dict(sorted(unavailable.items())),
            },
        }
