"""生成只加中文注释的阅读副本。运行前逐一验证锚点；原仓库不被修改。"""
from pathlib import Path
import ast
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "study/core"
OUT.mkdir(exist_ok=True)
records = []


def copy(name, source, notes, *, start=1, stop=None):
    path = ROOT / source
    original = "".join(path.read_text(encoding="utf-8").splitlines(keepends=True)[start-1:stop])
    prefix = "// 学习注：" if name.endswith(".sv") else "# 学习注："
    header = [f"{prefix} 来源 {source}，原始行 {start}–{stop or len(path.read_text(encoding='utf-8').splitlines())}。",
              f"{prefix} 这是核心阅读副本；运行仍用原目录及其依赖。只新增注释，没有修改逻辑。"]
    annotated = original
    for anchor, note in notes:
        if annotated.count(anchor) != 1:
            raise ValueError(f"{name}: expected one anchor: {anchor!r}")
        indent = anchor[:len(anchor)-len(anchor.lstrip())]
        annotated = annotated.replace(anchor, f"{indent}{prefix}{note}\n" + anchor, 1)
    # 可以删去所有新增注释还原原文；Python 还核对 AST，防止缩进或位置误改行为。
    clean = "".join(line for line in annotated.splitlines(keepends=True) if not line.lstrip().startswith(prefix))
    assert clean == original, name
    if name.endswith(".py"):
        assert ast.dump(ast.parse(original)) == ast.dump(ast.parse(annotated)), name
    (OUT / name).write_text("\n".join(header) + "\n" + annotated, encoding="utf-8")
    records.append({"file": name, "source": source, "start": start, "stop": stop,
                    "notes": len(notes), "original_slice_sha256": hashlib.sha256(original.encode()).hexdigest()})


copy("01_linear_workload.py", "PLENA/PLENA_RTL/tools/testworkloads/linear.py", [
    ('class LinearWorkload(', '入口先看 shape=(B,K)@(K,N)，再看 B/K/N 对 BLEN/MLEN 的整除限制。'),
    ('        # Validate dimensions against hardware constraints', 'tile 对齐是映射契约；尾块需 padding/mask，不能只把 assert 删掉。'),
    ('        # 1. Generate random tensors', '固定 seed 产生小输入；此处没有下载真实 Qwen 权重。'),
    ('        # 2. Quantize tensors', '先量化再算 golden，让 reference 与硬件实际读取的数据一致。'),
    ('        # 3. Compute golden result', 'golden 是功能标准；它的生成成功不等于 RTL 算对。'),
    ('        # 4. Save tensors', '张量下一步会按元素和共享 scale 拆成 HBM 存储镜像。'),
    ('    def get_config(', '保存 seed、shape、tile 和精度才能复现实验；只有一张结果截图不够。'),
    ('    paths = workload.generate()', '跟着 generate 的调用顺序看汇编、机器码、输入内存与 golden 四类产物。'),
])

copy("02_packed_gqa_schedule.py", "PLENA-Prefill/PLENA_Compiler/aten/plena/program_attention.py", [
    ('class PackedGQASchedule:', '同一 KV head 对应多个 Q heads。目标是打包利用阵列并复用 KV 数据。'),
    ('    def build(', '这里只建立调度计划，没有运行 attention 数值计算。'),
    ('        for name, value in values.items():', '合法 shape 先检查，否则后面的 ceil 和地址计算会掩盖配置错误。'),
    ('        chunks_per_kv =', '逻辑 GQA 比例不一定等于物理广播宽度；不足一组会产生 head tail。'),
    ('        q_blocks =', 'query 和 key 都按 MLEN 切块；长上下文的工作量来自块对组合。'),
    ('        residency =', 'SRAM 是否放得下 K/V 决定 streaming 或部分驻留，直接影响重复 DMA。'),
    ('        return cls(', '编译输出和成本统计应共用这个计划，避免性能模型统计另一套算法。'),
], stop=103)

copy("03_cost_trace.py", "PLENA-Prefill/PLENA_Compiler/aten/cost_emitter.py", [
    ('class StageCost:', '每个语义阶段同时记录静态代码量、动态执行次数和能耗动作。'),
    ('class CostTrace:', '把真实编译 schedule 变成可分析数据；不必展开 90k token 的全部张量。'),
    ('    memory_events: list[MemoryEvent]', 'DMA 地址、shape、stride 等信息送给 HBM 模型，不能只用总字节数代替。'),
    ('    schedule: ScheduleSequence', '保留顺序和循环结构，才能讨论依赖、重叠及 symbolic compression。'),
    ('    def dynamic_instruction_count(self)', '一条循环体指令可执行很多次；静态汇编行数不能直接当运行时间。'),
    ('        unavailable =', '模型没覆盖的 schedule 必须显式暴露；缺失成本不能默认为零。'),
], start=2733, stop=2804)

copy("04_softmax_state_bank.sv", "lab/rtl-prefill/src/vector_machine/rtl/softmax_state_bank.sv", [
    ('module softmax_state_bank', 'online softmax 的 m/l 存在行状态 bank；减少通过通用标量 SRAM 反复搬运。'),
    ('    parameter int ROW_LANES = 4,', 'R 个 query 行并行；不是把整条序列的 softmax 一次全部展开。'),
    ('    logic [DATA_WIDTH-1:0] data_storage', '每 bank 持有不同 query 行状态；有效位用于区分首块和后续块。'),
    ('    assign read_bank_row =', '连续 R 行组成一组，地址除以 R 得到 bank 内行号。'),
    ('        if (ROW_LANES < 1', '当前实现只接受 R1/2/4/8；R16 研究结果不可直接称为已验证 RTL。'),
])

copy("05_softmax_state_simd.sv", "lab/rtl-prefill/src/vector_machine/rtl/softmax_state_simd.sv", [
    ('module softmax_state_simd', '先跑 online_attention_lab.py，再把数学递推对应到三个 phase。'),
    ('    input  logic [1:0] phase,', 'phase0 求新 m 和 exp(old_m-new_m)；phase1 更新 l；phase2 求最终倒数。'),
    ('    assign p0_done =', '计算结果必须与上下文 FIFO 同步返回；不能读取此刻已经变化的输入。'),
    ('            m_out = p0_new_m_exp;', '输出的新最大值与之前保存的 l 一起交给后续 phase。'),
    ('            factor_out = exp_data;', '这是旧输出/分母的重缩放因子 alpha；漏用会让跨块结果错误。'),
    ('            factor_out = recip_data;', '硬件倒数是近似运算，测试应区分精确数学误差与相同舍入路径的一致性。'),
])

copy("06_softmax_row_engine.sv", "lab/rtl-prefill/src/vector_machine/rtl/softmax_row_engine.sv", [
    ('module softmax_row_engine', '把多行 SRAM、状态 bank 与计算流水接起来；重点看接受条件和返回提交。'),
    ('    parameter int ROW_LANES = 4,', '每次处理 R 行，每行 VLEN 个 key 元素；更长序列仍须多次迭代。'),
    ('    logic pending_valid [0:CONTEXT_DEPTH-1];', 'scoreboard 记住在途访问范围，防止同一状态/向量的读写依赖冲突。'),
    ('    function automatic logic ranges_overlap(', '用半开区间判重叠；这是允许独立组连续发射的前提。'),
    ('    assign class_compatible =', '同时在途的组需要属于兼容操作阶段，不能把不同 phase 任意混发。'),
    ('    assign scalar_ready =', '需要标量的 MUL 必须等 scalar_valid，否则会用到旧标量。'),
    ('    assign command_ready =', 'ready 同时受操作类型、地址冲突、标量就绪和容量约束。'),
    ('    assign accept =', 'valid && ready 才是一次真实接收；性能计数应在这里记账。'),
    ('    assign preview_vector_access =', 'preview 让前端提前知道下一拍是否可接受，避免流水级推进后丢命令。'),
])

copy("07_packed_pv_writeback.sv", "lab/rtl-prefill/src/matrix_machine/rtl/packed_pv_writeback.sv", [
    ('module packed_pv_writeback', 'P@V 的窄结果直接写进 packed O 的目标 lane，省去后续 shift/add。'),
    ('    input  logic accumulate,', '覆盖和累加是两条路径；累加需要读旧 O，再做 read-modify-write。'),
    ('    assign matrix_row_ready =', '接收不能超过 BLEN 行；RMW 还受 SRAM 读端口 ready 约束。'),
    ('    assign input_accept =', '只有握手成功才能推进地址/行计数。'),
    ('    assign input_addr =', '地址按 VLEN 行跨度增加；lane_offset 决定行内哪几路被写。'),
    ('    assign sram_read_req =', '仅 accumulate 需要读旧值；覆盖路径省去这次读取。'),
])

copy("08_packed_pv_accumulator.sv", "lab/rtl-prefill/src/matrix_machine/rtl/packed_pv_accumulator.sv", [
    ('module packed_pv_accumulator', 'WRITE_LANES 条有效乘加结果嵌入 VLEN 宽的 O；mask 保留未更新 lanes。'),
    ('    assign context_in =', '将旧 O 与 lane offset 随事务入队，匹配流水加法器的延迟。'),
    ('    assign context_pop =', '结果 valid 且上下文存在才出队，防止背靠背写回串行号。'),
    ('    for (genvar lane =', '复用原有 fp_fix_adder，维持与旧向量加法相同的舍入行为。'),
    ('    always_comb begin', '写掩码与写数据必须对齐；不参与当前 PV 的 lane 不得被覆盖。'),
])

copy("09_softmax_test.py", "lab/rtl-prefill/src/vector_machine/test/softmax_row_engine_tb.py", [
    ('ACTIVE_ROWS = 3', '故意只用四路中的三路，验证尾行 mask，而非只测整齐满载。'),
    ('async def issue_command(', '驱动 valid/ready、提供 SRAM 返回数据、等 done，并给超时边界。'),
    ('    for _ in range(300):', '超时可发现死锁；测试通过必须含功能检查，不能只是等到 finish。'),
    ('async def first_block_state_tail_and_final_factor_flow_through_row_engine', '覆盖首块、递推块、final reciprocal 与最终输出缩放。'),
    ('    assert int(dut.state_reference_mismatch.value) == 0', '对照单行 RTL oracle，核对相同低精度路径的 bit-exact 行为。'),
    ('    assert launches[1] - launches[0] == 1', 'II=1 指独立组每拍可发射；不是所有依赖操作一拍完成。'),
])

copy("10_system_metrics.py", "PLENA-Prefill/analytic_models/serving_benchmark/system_metrics.py", [
    ('def aggregated_system_metrics(', 'A100 聚合基线由 batch 实测耗时和能耗计算输出 TPS、tokens/J。'),
    ('def disaggregated_pipeline_metrics(', 'NPU prefill + KV 搬运 + GPU decode 的解析流水组合入口。'),
    ('    service_interval = max(', '稳态吞吐取最慢阶段；单批 E2E 则包括串行阶段，二者不能混用。'),
    ('    stage_idle_durations =', '快阶段完成后等待慢阶段仍有静态功耗；9 月修订补计这部分能量。'),
    ('    system_energy = active_stage_energy', '把各阶段工作能耗和等待能耗都算上，再比较能效。'),
    ('    output_tps = output_tokens / service_interval', '只计算输出 tokens；把 90k 输入也放分子会换掉指标。'),
    ('    slo_complete =', '只有明确 TTFT/TPOT 阈值和 request-visible 时间才可以谈 goodput。'),
])

copy("11_system_power.py", "PLENA-Prefill/analytic_models/power/system_power.py", [
    ('def estimate_system_power(', '合并逻辑、SRAM、外部 HBM 的能耗模型，输入来自编译 trace 与 timing。'),
    ('    external =', 'HBM 既有读写动态能耗，也有随运行时长累积的 background 能耗。'),
    ('    onchip =', 'EnergyAction 次数乘校准系数，再叠加背景/时钟项。'),
    ('    ungated_system_energy =', '与 ideal gating 并列保留 ungated 情况，用于观察结论对假设的敏感性。'),
    ('    excludes =', '封装、散热、板级稳压等未建模；不能把此结果当整机插座功率。'),
    ('            "rtl_clock_gating_implemented": False,', '模型假定 gating 效果；这个字段明确它不是已实现并测量的 clock gating。'),
])

copy("12_dse_objective.py", "PLENA-Prefill/analytic_models/dse/objective.py", [
    ('OBJECTIVE_DIRECTIONS =', '两个目标均最小化：prefill 延迟与能量；没有把 accuracy 当作越高越好的第三目标。'),
    ('def area_budget_constraints(', '面积是可行性限制；缺失或非有限值按不可行处理。'),
    ('class ObjectiveValues:', '传给 Optuna 的值仍是原始 ms/mJ。'),
    ('    def normalized_latency(self)', '历史命名 normalized 不代表除以 A100；这会直接影响结果解释。'),
    ('    def as_optuna_values(self)', '优化器比较的是这个二元组，accuracy/HBM 等约束在外层筛选。'),
])

copy("13_agu.py", "PLENA-Prefill/PLENA_Compiler/aten/agu.py", [
    ('def encode_agu_stride(', '大 stride 用有符号尾数加移位精确表示；不能编码就回退，不能截断地址。'),
    ('def _candidate_groups(', '先找循环尾最后使用的地址寄存器更新，保证移动更新不会改变中途读取。'),
    ('def _optimize_nodes(', '从内层向外处理循环；比较省掉的动态指令和新增 setup 成本。'),
    ('        if projected <= 0:', '小循环不一定值得配置 AGU；保留旧路径也是优化决策。'),
    ('        removed = {id(item)', '仅移除已经识别为可替代的地址更新链；循环内计算仍保留。'),
    ('def optimize_agu_assembly(', '阅读入口：解析、折叠精确重复、优化、输出统计；统计不等于实测周期。'),
])

copy("14_moe_routing.py", "PLENA-Prefill/PLENA_Compiler/aten/moe.py", [
    ('class MoeRoutingPlan:', '保存 host 选出的离散 expert 索引；静态路由验证范围需要单独说明。'),
    ('        expected_route_count =', '每个有效 token 应有 top-k 条边；漏边、重复边会直接改变模型。'),
    ('class MoeExpertRoutePlan:', '同一份路由建立 token/expert 两种索引，用于 dispatch、FFN 与 combine。'),
    ('            while start < len(routes):', '把相同 rank、等步长地址压缩成 affine run，减少逐 token 搬运指令。'),
    ('class FixedBalancedRoutingSummary:', '大规模成本搜索假定专家负载均衡；它没有模拟真实 router 偏斜。'),
    ('    values, indices = torch.topk(', '功能实验的 TopK 来自实际概率；低精度影响边界排序时，路由本身也会改变。'),
])

(OUT / "sources.json").write_text(json.dumps(records, ensure_ascii=False, indent=2), encoding="utf-8")
print(f"Generated {len(records)} reading files; {sum(r['notes'] for r in records)} annotations; source content and Python AST checked.")
