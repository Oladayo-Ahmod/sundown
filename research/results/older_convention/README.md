# Older liquidation convention (upper bound)

Copies of the result files as committed before M2.4, produced with the M2.2 convention: the full
liquidation bonus is charged on any account liquidated after the gap. The deployed market caps the
bonus at collateral/debt - 1 while collateral exceeds debt (SundownMarket._planLiquidation), which
removes losses on accounts liquidated between 1/(1+b) and 100 % LTV. That market rule is now the
default everywhere; this directory is the older convention, kept as an **upper bound** on lender
loss for before/after comparison (research/CLAIMS.md, "M2.4 before/after"). Reproduce with
SUNDOWN_LIQ_CONVENTION=older (it overwrites results/; move the outputs here afterwards).
