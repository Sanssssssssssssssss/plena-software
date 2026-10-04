# PLENA Instruction Set Architecture (ISA) Specification

The PLENA ISA is designed to cover all operations required for transformer inference. The instructions are structured to balance efficiency with flexibility and are built to support multiple transformer-based models and computation optimizations.

## Instruction Format

Instructions follow one of the following encoding formats:

| Format | Operands | Used By |
|--------|----------|---------|
| `OPCODE rd, rs1, rs2, rstride, precision` | 5 | H_PREFETCH_M, H_PREFETCH_V, H_STORE_V |
| `OPCODE rd, rs1, rs2, rmask, rorder` | 5 | V_SUB_VF |
| `OPCODE rd, rs1, rs2, rmask` | 4 | V_ADD_VV, V_SUB_VV, V_MUL_VV, V_ADD_VF, V_MUL_VF |
| `OPCODE rd, rs1, rmask` | 3 | V_EXP_V, V_RECI_V, V_RED_MAX |
| `OPCODE 0, rs1, rs2` | 3 | M_MM, M_TMM, M_BMM, M_BTMM, M_MV, M_TMV |
| `OPCODE rd, rs1, rs2` | 3 | S_ADD_INT, S_SUB_INT, S_MUL_INT, S_ADD_FP, S_SUB_FP, S_MUL_FP, S_MAX_FP, C_SET_ADDR_REG |
| `OPCODE rd, rs1, imm` | 3 | S_ADDI_INT, S_LD_INT, S_ST_INT, S_LD_FP, S_ST_FP, S_MAP_V_FP, M_MM_WO |
| `OPCODE rd, rs1` | 2 | V_RED_SUM, S_EXP_FP, S_RECI_FP, S_SQRT_FP |
| `OPCODE rd, imm` | 2 | S_LUI_INT, M_BMM_WO, M_MV_WO, C_LOOP_START |
| `OPCODE rd` | 1 | C_SET_SCALE_REG, C_SET_STRIDE_REG, C_SET_V_MASK_REG, C_LOOP_END |
| `OPCODE` (no operands) | 0 | C_BREAK |

### Notation Conventions

The following notation is used throughout this document:

| Symbol | Meaning |
|--------|---------|
| `gp_reg<rX>` | Value held in general-purpose register indexed by operand `rX` |
| `fp_reg<rX>` | Value held in floating-point register indexed by operand `rX` |
| `hbm_addr_reg<rX>` | Value held in HBM address register indexed by operand `rX` |
| `Matrix_SRAM[addr]` | Tile of Matrix SRAM starting at `addr` |
| `Vector_SRAM[addr]` | Tile of Vector SRAM starting at `addr` |
| `HBM[addr]` | Tile of HBM starting at `addr` |
| `X & gp_reg<rmask>` | Elements of `X` masked by the bit pattern held in the register indexed by `rmask` |

## Parameters

Refer to `plena_settings.toml` for the detailed parameters.

| Parameter | Description | Value |
|-----------|-------------|-------|
| **MLEN** | Tile size used in matrix machine | 64 |
| **BLEN** | Block length (output tile granularity) | 4 |
| **HLEN** | Head dimension for batched/partitioned attention | 16 |
| **VLEN** | Tile size used in vector machine | 64 |
| **HBM_M_Prefetch_Amount** | Number of MLEN rows fetched from HBM | 64 |
| **HBM_V_Prefetch_Amount** | Number of rows fetched per H_PREFETCH_V | 4 |

## Register Types

The PLENA architecture supports four types of registers:

- **gp_reg** (`gp0` to `gp15`): 16 general-purpose integer registers (gp0-gp15 only, no gp16+)
  - **gp0 is always 0**: Use `S_ADDI_INT gpX, gp0, value` to load immediate values.
- **fp_reg** (`f0` to `f7`): 8 floating-point registers
  - **f0 is always 0.0**: Use `S_ADD_FP fX, f0, f0` to initialize any FP register to 0.0.
- **hbm_addr_reg** (`a0` to `a7`): 8 HBM address registers

## Matrix (M-Type) Instructions

M-type instructions drive the systolic array. Compute instructions (`M_MM`, `M_TMM`, `M_BMM`, `M_BTMM`, `M_MV`, `M_TMV`) **accumulate** into the array. The `*_WO` variants (`M_MM_WO`, `M_BMM_WO`, `M_MV_WO`) write the accumulated result back to Vector SRAM and clear the array.

**Addressing Strides (Matrix SRAM):**

| Instruction  | MSRAM Stride | Purpose |
|--------------|--------------|---------|
| M_MM         | `BLEN`       | Select `BLEN`-column slice within the tile |
| M_TMM        | `MLEN × BLEN`| Select `BLEN`-row slice (transposed) |
| M_MM_WO      | `BLEN`       | Output column block |
| H_PREFETCH_M | `MLEN × MLEN`| Tile destination address |

### M_MM

**Format:** `M_MM 0, rs1, rs2`

**Operation:** `Systolic Array += Vector_SRAM[gp_reg<rs2>] @ Matrix_SRAM[gp_reg<rs1>]`

**Operand Order:**
- `rs1` = Matrix SRAM address (weights)
- `rs2` = Vector SRAM address (activations)

**Description:**

Fetch a `(BLEN, MLEN)` tile from Vector SRAM at `gp_reg<rs2>` and an `(MLEN, BLEN)` tile from Matrix SRAM at `gp_reg<rs1>`, compute the matrix product, and accumulate into the systolic array. The first operand is a placeholder and must be `0`. Call `M_MM` repeatedly to accumulate across the K dimension, then use `M_MM_WO` to write the result to Vector SRAM.

### M_TMM

**Format:** `M_TMM 0, rs1, rs2`

**Operation:** `Systolic Array += Vector_SRAM[gp_reg<rs1>] @ Matrix_SRAM[gp_reg<rs2>]^T`

**Operand Order (swapped vs. M_MM):**
- `rs1` = Vector SRAM address (activations)
- `rs2` = Matrix SRAM address (weights)

**Description:**

Same as `M_MM`, but the tile fetched from Matrix SRAM is transposed before the multiply. **Note:** the Vector / Matrix operand roles of `rs1` and `rs2` are reversed relative to `M_MM`.

### M_BMM

**Format:** `M_BMM 0, rs1, rs2`

**Operation:** `Systolic Array += Per-Head (Vector_SRAM[gp_reg<rs2>] @ Matrix_SRAM[gp_reg<rs1>])`

Dimensions: `[MLEN/HLEN, MLEN, HLEN] @ [HLEN, MLEN] = [MLEN/HLEN, MLEN, MLEN]`

**Operand Order:**
- rs1 = Matrix SRAM address (weights)
- rs2 = Vector SRAM address (activations)

**Description:**

Performs `MLEN/HLEN` independent matrix multiplies in parallel, accumulating into the systolic array. Use `M_BMM` / `M_BTMM` instead of `M_MM` / `M_TMM` when the workload has a batch dimension (e.g., multi-head attention, batched matmul) that can be mapped to the `MLEN/HLEN` parallel lanes.

### M_BTMM

**Format:** `M_BTMM 0, rs1, rs2`

**Operation:** `Systolic Array += Per-Head (Vector_SRAM[gp_reg<rs2>] @ Matrix_SRAM[gp_reg<rs1>]^T)`

**Description:**

Same as `M_BMM`, but the tile fetched from Matrix SRAM is transposed before the multiply.

### M_MM_WO

**Format:** `M_MM_WO rd, 0, imm`

**Operation:** `Vector_SRAM[gp_reg<rd> + imm] = Systolic Array`

**Description:**

Write the accumulated `(BLEN × BLEN)` result tile from the systolic array to **Vector SRAM only** (not HBM). After this instruction, the systolic array is cleared and ready for new accumulation. The middle operand is a placeholder and must be `0`.

### M_BMM_WO

**Format:** `M_BMM_WO rd, imm`

**Operation:** `Vector_SRAM[gp_reg<rd> + imm] = Systolic Array`  *(per-head, stride `MLEN/HLEN`)*

**Description:**

Store the accumulated `[MLEN/HLEN, MLEN, MLEN]` result from the systolic array to Vector SRAM, with stride `MLEN/HLEN`. Precision (`Weights` or `KeyValue`) is inferred from the MXFP precision of the accumulated data.

### M_MV

**Format:** `M_MV 0, rs1, rs2`

**Operation:** `Accumulator = Vector_SRAM[gp_reg<rs1>] @ Matrix_SRAM[gp_reg<rs2>]`

**Description:**

Fetch an `(MLEN, MLEN)` matrix from Matrix SRAM at `gp_reg<rs2>` and an `(MLEN, 1)` vector from Vector SRAM at `gp_reg<rs1>`, then perform a matrix-vector multiply. The resulting `(MLEN, 1)` vector is stored in the accumulator row of the systolic array. The first operand is a placeholder and must be `0`.

**Operand Order:**
- rs1 = Vector SRAM address (activation)
- rs2 = Matrix SRAM address (weights)

### M_TMV

**Format:** `M_TMV 0, rs1, rs2`

**Operation:** `Accumulator = Vector_SRAM[gp_reg<rs1>] @ Matrix_SRAM[gp_reg<rs2>]^T`

**Description:**

Same as `M_MV`, but the matrix fetched from Matrix SRAM is transposed before the multiply.

### M_MV_WO

**Format:** `M_MV_WO rd, imm`

**Operation:** `Vector_SRAM[gp_reg<rd> + imm] = Accumulator`

**Description:**

Store the accumulated `(MLEN, 1)` vector from the first row of the systolic array to Vector SRAM.

### M_BMV, M_BTMV, M_BMV_WO

*Not yet implemented — reserved for future batched matrix-vector support.*

---

## Vector (V-Type) Instructions

### Notation

| Notation | Description |
|----------|-------------|
| **Vector_SRAM[i]** | i-th entry of the Vector SRAM |

`rmask` is a GP-register index that selects the element mask applied to the result of each vector operation. The mask value held in that register is configured by the `C_SET_V_MASK_REG` instruction. Use `gp0` to disable masking.

**Addressing Constraints:**
- All read addresses (`gp_reg<rs1>`, `gp_reg<rs2>`) must be multiples of `VLEN` (i.e. `gp_reg<rsX> % VLEN == 0`).
- All write addresses (`gp_reg<rd>`) must be multiples of `VLEN`.

### V_ADD_VV

**Format:** `V_ADD_VV rd, rs1, rs2, rmask`

**Operation:** `Vector_SRAM[gp_reg<rd>] = (Vector_SRAM[gp_reg<rs1>] + Vector_SRAM[gp_reg<rs2>]) & gp_reg<rmask>`

**Description:**

Fetch two `(VLEN, 1)` vectors from Vector SRAM at `gp_reg<rs1>` and `gp_reg<rs2>`, perform element-wise addition, and write the masked result to Vector SRAM at `gp_reg<rd>`.

**Note:** When `rs1` or `rs2` is `gp0`, the instruction reads `Vector_SRAM[0]` from VRAM — **not** a zero vector. To copy a vector, use `V_ADD_VF` with `f0` (which is always `0.0`).

### V_ADD_VF

**Format:** `V_ADD_VF rd, rs1, rs2, rmask`

**Operation:** `Vector_SRAM[gp_reg<rd>] = (Vector_SRAM[gp_reg<rs1>] + Broadcast(fp_reg<rs2>)) & gp_reg<rmask>`

**Description:**

Fetch a `(VLEN, 1)` vector from Vector SRAM at `gp_reg<rs1>` and a scalar from the FP register file (operand `rs2` is an FP register index). Broadcast the scalar to a `(VLEN, 1)` vector, add element-wise, and write the masked result to Vector SRAM at `gp_reg<rd>`.

### V_SUB_VV

**Format:** `V_SUB_VV rd, rs1, rs2, rmask`

**Operation:** `Vector_SRAM[gp_reg<rd>] = (Vector_SRAM[gp_reg<rs2>] - Vector_SRAM[gp_reg<rs1>]) & gp_reg<rmask>`

**Description:**

Element-wise subtraction: `Vector_SRAM[rs2] − Vector_SRAM[rs1]`. Note the operand order — the second source is the minuend, the first source is the subtrahend.

### V_SUB_VF

**Format:** `V_SUB_VF rd, rs1, rs2, rmask, rorder`

**Operation:**
- `rorder = 0` (normal): `Vector_SRAM[gp_reg<rd>] = (Vector_SRAM[gp_reg<rs1>] - Broadcast(fp_reg<rs2>)) & gp_reg<rmask>`
- `rorder = 1` (reverse): `Vector_SRAM[gp_reg<rd>] = (Broadcast(fp_reg<rs2>) - Vector_SRAM[gp_reg<rs1>]) & gp_reg<rmask>`

**Description:**

Element-wise subtraction between a vector and a broadcast scalar. The `rorder` field controls operand order. Operand `rs2` is an FP register index.

### V_MUL_VV

**Format:** `V_MUL_VV rd, rs1, rs2, rmask`

**Operation:** `Vector_SRAM[gp_reg<rd>] = (Vector_SRAM[gp_reg<rs1>] * Vector_SRAM[gp_reg<rs2>]) & gp_reg<rmask>`

**Description:**

Element-wise multiplication of two Vector SRAM tiles, analogous to `V_ADD_VV`.

### V_MUL_VF

**Format:** `V_MUL_VF rd, rs1, rs2, rmask`

**Operation:** `Vector_SRAM[gp_reg<rd>] = (Vector_SRAM[gp_reg<rs1>] * Broadcast(fp_reg<rs2>)) & gp_reg<rmask>`

**Description:**

Element-wise multiplication of a vector by a broadcast FP scalar, analogous to `V_ADD_VF`.

### V_EXP_V

**Format:** `V_EXP_V rd, rs1, rmask`

**Operation:** `Vector_SRAM[gp_reg<rd>] = exp(Vector_SRAM[gp_reg<rs1>]) & gp_reg<rmask>`

**Description:**

Fetch a `(VLEN, 1)` vector from Vector SRAM at `gp_reg<rs1>`, apply element-wise exponentiation, and write the masked result back to Vector SRAM at `gp_reg<rd>`.

### V_RECI_V

**Format:** `V_RECI_V rd, rs1, rmask`

**Operation:** `Vector_SRAM[gp_reg<rd>] = reciprocal(Vector_SRAM[gp_reg<rs1>]) & gp_reg<rmask>`

**Description:**

Element-wise reciprocal, analogous to `V_EXP_V`.

### V_RED_SUM

**Format:** `V_RED_SUM rd, rs1`

**Operation:** `fp_reg<rd> += sum(Vector_SRAM[gp_reg<rs1>])`

**Description:**

Fetch a `(VLEN, 1)` vector from Vector SRAM at `gp_reg<rs1>`, sum all elements, and **accumulate** the result into `fp_reg<rd>`. To initialize the accumulator, zero `fp_reg<rd>` before the first call (`S_ADD_FP rd, f0, f0`).

### V_RED_MAX

**Format:** `V_RED_MAX rd, rs1, rmask`

**Operation:** `fp_reg<rd> = max(max(Vector_SRAM[gp_reg<rs1>] & gp_reg<rmask>), fp_reg<rd>)`

**Description:**

Find the maximum over the masked elements of `Vector_SRAM[gp_reg<rs1>]` and update `fp_reg<rd>` if that maximum exceeds the current value. Accumulates the running max across multiple calls.

---

## Scalar (S-Type) Instructions

### Integer Operations

#### Notation

| Notation | Description |
|----------|-------------|
| **INT_MEM[i]** | i-th entry of the SRAM within the scalar machine specifically designed for integer operations |

#### S_ADD_INT

**Format:** `S_ADD_INT rd, rs1, rs2`

**Operation:** `gp_reg<rd> = gp_reg<rs1> + gp_reg<rs2>`

#### S_ADDI_INT

**Format:** `S_ADDI_INT rd, rs1, imm`

**Operation:** `gp_reg<rd> = gp_reg<rs1> + imm`

#### S_SUB_INT

**Format:** `S_SUB_INT rd, rs1, rs2`

**Operation:** `gp_reg<rd> = gp_reg<rs1> - gp_reg<rs2>`

#### S_MUL_INT

**Format:** `S_MUL_INT rd, rs1, rs2`

**Operation:** `gp_reg<rd> = gp_reg<rs1> * gp_reg<rs2>`

#### S_LUI_INT

**Format:** `S_LUI_INT rd, imm`

**Operation:** `gp_reg<rd> = imm << 12`

**Description:** Load upper immediate. Each `imm` unit = 4096. Example: `S_LUI_INT gp1, 4` → gp1 = 16384.

#### S_LD_INT

**Format:** `S_LD_INT rd, rs1, imm`

**Operation:** `gp_reg<rd> = INT_MEM[gp_reg<rs1> + imm]`

#### S_ST_INT

**Format:** `S_ST_INT rd, rs1, imm`

**Operation:** `INT_MEM[gp_reg<rs1> + imm] = gp_reg<rd>`

### Floating-Point Operations

#### Notation

| Notation | Description |
|----------|-------------|
| **FP_MEM[i]** | i-th entry of the SRAM within the scalar machine specifically designed for floating-point operations |

#### S_ADD_FP

**Format:** `S_ADD_FP rd, rs1, rs2`

**Operation:** `fp_reg<rd> = fp_reg<rs1> + fp_reg<rs2>`

#### S_SUB_FP

**Format:** `S_SUB_FP rd, rs1, rs2`

**Operation:** `fp_reg<rd> = fp_reg<rs1> - fp_reg<rs2>`

#### S_MAX_FP

**Format:** `S_MAX_FP rd, rs1, rs2`

**Operation:** `fp_reg<rd> = max(fp_reg<rs1>, fp_reg<rs2>)`

#### S_MUL_FP

**Format:** `S_MUL_FP rd, rs1, rs2`

**Operation:** `fp_reg<rd> = fp_reg<rs1> * fp_reg<rs2>`

#### S_EXP_FP

**Format:** `S_EXP_FP rd, rs1`

**Operation:** `fp_reg<rd> = exp(fp_reg<rs1>)`

#### S_RECI_FP

**Format:** `S_RECI_FP rd, rs1`

**Operation:** `fp_reg<rd> = 1.0 / fp_reg<rs1>`

#### S_SQRT_FP

**Format:** `S_SQRT_FP rd, rs1`

**Operation:** `fp_reg<rd> = sqrt(fp_reg<rs1>)`

#### S_LD_FP

**Format:** `S_LD_FP rd, rs1, imm`

**Operation:** `fp_reg<rd> = FP_MEM[gp_reg<rs1> + imm]`

**Note:** FP_MEM can be preloaded with constants. Use S_LD_FP to load them into FP registers before use.

#### S_ST_FP

**Format:** `S_ST_FP rd, rs1, imm`

**Operation:** `FP_MEM[gp_reg<rs1> + imm] = fp_reg<rd>`

#### S_MAP_V_FP

**Format:** `S_MAP_V_FP rd, rs1, imm`

**Operation:** `Vector_SRAM[gp_reg<rd> :+ VLEN] = FP_MEM[gp_reg<rs1> + imm :+ VLEN]`

**Description:**

Copy `VLEN` contiguous elements from FP_MEM to Vector SRAM.

---

## Memory (H-Type) Instructions

H-type instructions move data between HBM and on-chip SRAM. Every H-type instruction requires a previously initialized HBM address register (see `C_SET_ADDR_REG`) and — when using stride mode — a previously initialized `STRIDE_REG` (see `C_SET_STRIDE_REG`).

### H_PREFETCH_M

**Format:** `H_PREFETCH_M rd, rs1, rs2, rstride, precision`

**Operation:** `Matrix_SRAM[gp_reg<rd>] = HBM[hbm_addr_reg<rs2> + gp_reg<rs1>]`

**Description:**

Prefetch an `(MLEN × MLEN)` weight tile from HBM into Matrix SRAM. Element `(row, col)` within the tile is stored at HBM offset `col * STRIDE_REG + row`.

**Operands:**
- `rd`: GP register holding the destination address in Matrix SRAM
- `rs1`: GP register holding the HBM offset (relative to the base address in `rs2`)
- `rs2`: HBM address register index (`a0`-`a7`) holding the base address
- `rstride`: Stride mode selector (`0` = contiguous, `1` = use `STRIDE_REG`)
- `precision`: Data precision (`0` = Weights, `1` = KeyValue)

**Stride Mode Layout:** For the weight tile at row-block `k`, col-block `j`:

```
HBM offset = j × MLEN + k × MLEN × STRIDE_REG
```

**Multi-Tile Loading:** For a weight tensor `[rows, cols]`, loading multiple column tiles:

- `STRIDE_REG = cols` (row stride in HBM)
- Tile `j` HBM offset = `j × MLEN` (column offset — **not** `j × MLEN × MLEN`)

```asm
; Loading 4 tiles from a [64, 256] tensor:
C_SET_STRIDE_REG gp10             ; STRIDE_REG = 256 (cols)
; Tile offsets: 0, 64, 128, 192  (increment by MLEN, not MLEN*MLEN)
```

### H_PREFETCH_V

**Format:** `H_PREFETCH_V rd, rs1, rs2, rstride, precision`

**Operation:** `Vector_SRAM[gp_reg<rd>] = HBM[hbm_addr_reg<rs2> + gp_reg<rs1>]`

**Description:**

Prefetch activation tiles from HBM into Vector SRAM. Each call loads `BLEN × VLEN` elements (`HBM_V_Prefetch_Amount` rows of `VLEN`).

**Operands:**
- `rd`: GP register holding the destination address in Vector SRAM
- `rs1`: GP register holding the HBM offset (relative to the base address in `rs2`)
- `rs2`: HBM address register index (`a0`-`a7`) holding the base address
- `rstride`: Stride mode selector (see below)
- `precision`: Data precision (`0` = Activation, `1` = KeyValue)

**Stride Modes:**
- `rstride = 0`: Contiguous 1D load — reads `BLEN × VLEN` elements consecutively from HBM.
- `rstride = 1`: Strided 2D load — reads `BLEN` rows of `VLEN` elements each, spaced by `STRIDE_REG` in HBM.

### H_STORE_V

**Format:** `H_STORE_V rd, rs1, rs2, rstride, precision`

**Operation:** `HBM[hbm_addr_reg<rs2> + gp_reg<rs1>] = Vector_SRAM[gp_reg<rd>]`

**Description:**

Store an `HBM_V_Writeback_Amount × VLEN` tile from Vector SRAM to HBM, using `STRIDE_REG` as the row stride in HBM. This is the primary mechanism for moving on-chip results (e.g., computed K/V projections) back to HBM so they can later be prefetched into Matrix SRAM.

**Format Conversion:** Data is converted from VRAM `bf16` to MXFP as it is written to HBM.

**Note:** H_STORE_V is modeled in the behavioral simulator.

**Operands:**
- `rd`: GP register holding the source address in Vector SRAM
- `rs1`: GP register holding the HBM offset (relative to the base address in `rs2`)
- `rs2`: HBM address register index (`a0`-`a7`) holding the base address
- `rstride`: Stride mode selector (`0` = contiguous, `1` = use `STRIDE_REG`)
- `precision`: Data precision (`0` = Activation, `1` = KeyValue)

---

## Control and Status Register (C-Type) Instructions

### C_SET_ADDR_REG

**Format:** `C_SET_ADDR_REG rd, rs1, rs2`

**Operation:** `hbm_addr_reg<rd> = {gp_reg<rs1>, gp_reg<rs2>}`

**Description:**

Set `hbm_addr_reg<rd>` by concatenating two GP registers. HBM address registers are twice the bit width of a GP register; the concatenation order is `{rs1 = high bits, rs2 = low bits}`.

### C_SET_SCALE_REG

**Format:** `C_SET_SCALE_REG rd`

**Operation:** `SCALE_REG = gp_reg<rd>`

**Description:**

Set the scale-offset register used by MXFP prefetch. Must be set before `H_PREFETCH_M` and `H_PREFETCH_V`.

The scale register points to the scale factors associated with a data block in HBM:

```
scale_location = base_addr + SCALE_REG + (element_offset / 8)
```

Rearranged: `SCALE_REG = scale_location − (element_offset / 8)`.

### C_SET_STRIDE_REG

**Format:** `C_SET_STRIDE_REG rd`

**Operation:** `STRIDE_REG = gp_reg<rd>`

**Description:**

Set the stride value used by strided H-type instructions. The stride is read from `gp_reg<rd>` — it is **not** an immediate.

**Example:**
```asm
S_ADDI_INT gp4, gp0, 128           ; gp4 = 128
C_SET_STRIDE_REG gp4               ; STRIDE_REG = 128
```

### C_SET_V_MASK_REG

**Format:** `C_SET_V_MASK_REG rd`

**Operation:** `V_MASK = gp_reg<rd>`

**Description:**

Set the vector mask register consumed by masked vector operations (see `rmask` in the V-type section).

### C_LOOP_START

**Format:** `C_LOOP_START rd, imm`

**Operation:** Begin a hardware loop of `imm` iterations; `gp_reg<rd>` is reserved as the hardware loop counter.

**Description:**

Start a hardware loop. `imm` is the iteration count, and `rd` names the GP register the hardware uses to track remaining iterations.

**IMPORTANT:** `gp_reg<rd>` is a countdown register — it does **not** hold the current iteration index. If the loop body needs an induction variable, maintain a separate GP register and increment it manually.

### C_LOOP_END

**Format:** `C_LOOP_END rd, 0`

**Operation:** If `gp_reg<rd> > 0`, decrement `gp_reg<rd>` and jump to the matching `C_LOOP_START`.

**Description:**

Close a hardware loop. The second operand is a placeholder and must be `0`.

**Example:**
```asm
S_ADDI_INT gp5, gp0, 0             ; idx = 0 (separate induction variable)
C_LOOP_START gp4, 8                ; 8 iterations; gp4 is the hardware counter
  ; ... loop body using gp5 as the iteration index ...
  S_ADDI_INT gp5, gp5, 1           ; idx++
C_LOOP_END gp4, 0                  ; branch back while gp4 > 0
```

### C_BREAK

**Format:** `C_BREAK` (no operands)

**Operation:** Raise a breakpoint exception.

**Description:**

Trigger a breakpoint exception for debugging. Programs do **not** need `C_BREAK` to terminate — execution ends when all instructions have been issued.

---