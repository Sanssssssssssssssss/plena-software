# Design Space

The table below lists the hardware and quantization parameters that are jointly explored during co-design. Hardware tile sizes and SRAM–HBM transfer widths are expressed as powers of two; precision parameters are categorical and one-hot encoded.

## Search Space

| Parameter | Description | Search Range |
|-----------|-------------|--------------|
| `BLEN` | Tile size of block unit | [2, 4, …, 64] |
| `MLEN` | Tile size of Matrix Unit | [2, 4, …, 1024] |
| `VLEN` | Tile size of Vector Unit | [2, 4, …, 1024] |
| `M_LOAD` | Matrix SRAM load amount from HBM (matrices loaded per instruction) | [2, 4, …, 256] |
| `V_LOAD` | Vector SRAM load amount from HBM (vectors loaded per iteration) | [2, 4, …, 256] |
| `V_WRITE` | Vector SRAM write amount to HBM (vectors written per iteration) | [2, 4, …, 256] |
| `ACT_WIDTH` | Activation precision | MXINT, MXFP |
| `KV_WIDTH` | Key/Value precision | MXINT, MXFP |
| `FP_SETTING` | Floating-point precision | FP |

## Example Constraints

Valid configurations must satisfy constraints that couple the hardware and quantization parameters. Representative examples:

1. **Memory bandwidth** — `MLEN × KV_WIDTH ≤ MemBandwidth`
2. **Tile divisibility** — `MLEN mod BLEN = 0`
3. **Tile ordering** — `MLEN ≥ HLEN ≥ BLEN`
