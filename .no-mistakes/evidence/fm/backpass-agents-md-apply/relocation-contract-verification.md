# Relocation contract verification

- Base: `d6cf2ab888c068c1cab2e56f0f0ce7946a4e17c2`
- Target: `3222439a65065b50538323a26587049778c4a78c`

The prompt bodies are intentional machine-consumed runtime contracts. The removed AGENTS.md procedure blocks were compared line-for-line with the three new skill bodies. Normalization was limited to the accepted relocation fixes: relative link targets, “section 4” → “above”, and an explicit `AGENTS.md section 6` owner.

- PASS: Worker dispatch resolution matches the base contract after only the accepted relocation-specific path/context normalizations.
- PASS: Worker spawn, steering, and lifecycle control matches the base contract after only the accepted relocation-specific path/context normalizations.
- PASS: Backlog operations matches the base contract after only the accepted relocation-specific path/context normalizations.
- PASS: Task briefing matches the base contract after only the accepted relocation-specific path/context normalizations.

## Always-loaded file size

- Base `AGENTS.md`: 48,990 bytes
- Target `AGENTS.md`: 37,693 bytes
- Reduction: 11,297 bytes (23.1%)

This byte comparison supports the intended reduction; it does not claim to reproduce backpass’s tokenizer-specific 18% token estimate.
