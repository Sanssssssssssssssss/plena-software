# Related Projects

The following projects are developed alongside PLENA and address complementary challenges in accelerator design for LLM inference.

---

## KernelCraft

**[KernelCraft](https://kernelcraft-cam.github.io/)** is a benchmark suite that evaluates LLM agents' ability to generate and optimize low-level assembly kernels for customized AI accelerators with novel ISAs. It uses a feedback-driven workflow with compilation checks, simulation, and correctness validation.

---

## MemExplorer

**[MemExplorer](https://arxiv.org/abs/2604.16007)** is a memory system synthesizer that automatically explores heterogeneous memory technologies (SRAM, HBM, LPDDR, GDDR, HBF) and NPU design choices to find efficient memory architectures for multi-device inference accelerator systems serving agentic LLM workloads.

---

## DART

**[DART](https://arxiv.org/abs/2601.20706)** is an NPU architecture design targeting the sampling bottleneck in diffusion-based LLMs. It uses non-GEMM vector primitives and a decoupled mixed-precision memory hierarchy to efficiently handle diffusion LLM sampling, which can consume up to 70% of inference latency on conventional GPUs.
