# ccxt differential fixtures

These fixtures are static ccxt-style captures used by
`test/delta_calc/ccxt_differential_test.exs`. The default test path is offline:
it reads JSON from this directory and must not call ccxt, HTTP, exchange APIs, or
private credentials.

## Refresh procedure

1. Use a consumer BEAM that already has both `ccxt_client` and `delta_calc`
   compiled, for example the dashboard Tidewave node on port 4025.
2. Capture public funding rows with ccxt/ccxt_client:
   - funding rate
   - funding interval in hours
   - raw exchange response under `raw`
3. Capture a private test account position with ccxt/ccxt_client:
   - maintenance-margin tier used by the venue
   - equity
   - contracts, side, entry price, and mark price
   - venue-published liquidation price
   - raw ccxt position response under `raw`
4. Paste the recorded values into `funding_and_liquidation.json`.
5. Re-run:

   ```sh
   mix test.json --quiet test/delta_calc/ccxt_differential_test.exs
   ```

Any live refresh helper belongs in the consumer project, not delta_calc. Tag it
with `@moduletag :integration`, require credentials loudly with `flunk/1`, and
keep it excluded from `mix ci`.
