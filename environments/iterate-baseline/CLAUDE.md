# Iteration Instructions

You are iterating on a full-stack web application. Each turn should follow this process:

## Turn Structure
1. **Assess current state** — Read the app from a user's perspective. What's the most impactful gap between "demo" and "real product"?
2. **Prioritize by user impact** — Fix what a real user would hit first. Broken flows > missing data > cosmetic polish.
3. **Implement with invariant tests** — For every cross-layer change, write a test that verifies the contract between producer and consumer (e.g., if the backend returns data the frontend relies on, test the shape).
4. **Verify end-to-end** — TypeScript compiles clean, all tests pass, deploy succeeds, site returns 200.

## Prioritization Rules
- Data correctness > feature completeness > visual polish
- If a feature exists but shows wrong/missing data, fix the data before adding new features
- If adding a feature, include the unit and price context — users need to know what they're getting
- Every store reference must include address when available
- Every price must include unit (per lb, per oz, each, etc.)

## Anti-patterns to Avoid
- Don't add features without testing the data flow end-to-end
- Don't create database records without required fields (coordinates for stores, units for prices)
- Don't show raw IDs, placeholder text, or "94102 area" to users
- Don't add buttons that just show a toast — every action should have a meaningful result
