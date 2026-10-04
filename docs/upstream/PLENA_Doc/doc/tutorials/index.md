# Tutorials

These hands-on tutorials walk through running the three PLENA evaluation
backends end-to-end. They assume you have already followed
[Getting Started](../getting-started.md) and can enter the relevant dev shell
(Nix + direnv, or the provided Docker image).

| # | Tutorial | Repository | What you will run |
|---|---|---|---|
| 1 | [Running the Transactional Emulator](transactional_emulator.md) | `PLENA_Simulator` | Compile a Linear layer to PLENA ISA and execute it on the Rust cycle-approximate emulator. |
| 2 | [Running the Analytic Model](analytic_model.md) | `PLENA_Simulator` | Estimate TTFT / TPS for a real LLM (Llama-3.1-8B) from a closed-form cost model. |
| 3 | [Running an RTL Simulation](rtl_simulation.md) | `PLENA_RTL` | Drive the SystemVerilog design with cocotb + Verilator on a Linear workload and verify against a golden reference. |

The three tutorials are independent — pick whichever evaluation layer matches
your task. Tutorial 1 → Tutorial 3 also forms a useful progression from
fastest / least detailed (analytic) to slowest / most detailed (RTL):

```
       Analytic Model            Transactional Emulator              RTL Simulation
       (closed-form)              (cycle-approximate)                (cycle-accurate)
   ┌───────────────────┐       ┌─────────────────────────┐       ┌────────────────────┐
   │ seconds           │  →    │ seconds–minutes         │  →    │ minutes–hours      │
   │ no memory model   │       │ Ramulator / DRAMSys     │       │ full RTL + cocotb  │
   │ DSE-friendly      │       │ trade-off studies       │       │ pre-silicon sign-off│
   └───────────────────┘       └─────────────────────────┘       └────────────────────┘
```

See the [Toolchain Overview](../toolchain_overview.md) for how these three
fit together inside the broader PLENA compile → evaluate flow.
