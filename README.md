# MabeleLink

MabeleLink is an agriculture coordination product for the Democratic Republic
of the Congo. The MVP starts with a focused workflow: farmers publish produce
available for sale, buyers can discover listings, and a buyer can reserve a
quantity while the service prevents over-reservation.

## Current MVP slice

- OTP application and supervision tree.
- In-memory produce listing service.
- Listing validation for farmer, crop, quantity, unit, and location.
- Browse and fetch listings.
- Atomic quantity reservations within the running Erlang process.

This is a backend foundation, not yet a deployable marketplace: state is lost
when the process stops, and there is no HTTP interface, authentication, payment,
or transport integration yet.

## Run

Requires Erlang/OTP and rebar3.

```powershell
rebar3 shell
```

In the Erlang shell:

```erlang
mabelelink_listings:create(#{farmer_name => <<"Amina">>, crop => cassava,
  quantity => 500, unit => kg, location => <<"Kongo Central">>} ).
mabelelink_listings:list().
mabelelink_listings:reserve(1, 100).
```

## Project plan

### Product goal

Help smallholder farmers and local buyers coordinate produce sales reliably,
starting in one pilot area. Validate the operational workflow before expanding
to transport, storage, and payments.

### First pilot assumptions to validate

- Start with one cooperative or trusted farmer group in Kongo Central, with
  buyers reachable from Kinshasa.
- Begin with cassava and maize, priced and measured in locally understood units.
- Treat phone/SMS-assisted operations as part of the product; do not assume
  every farmer has continuous data access.
- An MVP reservation is an expression of buyer intent, not a confirmed sale.

### Milestones

| Stage | Outcome | Scope |
|---|---|---|
| 0. Discovery (weeks 1–2) | Pilot workflow and unit economics understood | Interview farmers, cooperative leads, buyers, and transporters; map current pricing, trust, grading, and payment practices |
| 1. Core service (weeks 3–4) | Listing and reservation backend | Validation, listing lifecycle, reservation records, audit events, PostgreSQL persistence |
| 2. Field MVP (weeks 5–8) | Usable low-connectivity experience | French-first responsive interface, offline draft capture, sync, SMS/phone-assisted listing and reservation support |
| 3. Pilot (weeks 9–12) | Real transactions completed and measured | One cooperative, a small set of buyers, operator tools, delivery status, dispute handling |
| 4. Strengthen (months 4–6) | Repeatable operating model | Payments through locally available authorized providers, transport coordination, reporting, security and reliability |
| 5. Expand (months 7–12) | Second area only after pilot metrics hold | Additional crops/cooperatives, language expansion, partner APIs |

### MVP acceptance criteria

- A farmer or field operator can create a listing with crop, quantity, unit,
  location, and contact/availability details.
- A buyer can browse active listings and request a specific quantity.
- The system never reserves more than the listed available quantity.
- Both parties can see a clear reservation status and next action.
- An operator can resolve cancellation, rejection, and delivery exceptions.
- The workflow can be supported by a human operator when connectivity fails.

### Pilot measures

- Active farmers and buyers, and repeat participation.
- Listings that receive a serious buyer request.
- Time from listing to confirmed match.
- Fulfillment and cancellation rates, with reasons.
- Price received compared with each farmer's prior alternative.
- Spoilage avoided and transport cost per delivered unit where measurable.
- Support time and cost per completed transaction.

### Risks and decisions

- Trust, crop quality/grade, weights, and price disputes need field-tested rules.
- Transport availability and road conditions may constrain fulfillment more
  than software; keep logistics coordination manual during the first pilot.
- Mobile money access differs by location and provider; do not promise payment
  integration until local partner and settlement processes are verified.
- Use minimal personal data, role-based access, and explicit consent before
  exposing phone numbers or sharing a buyer request.
- The current in-memory service is for the first development slice only; add
  durable storage and a transaction/audit model before any field deployment.

## Next engineering increments

1. Add EUnit coverage for validation, reservations, and concurrent buyers.
2. Add PostgreSQL persistence and reservation history.
3. Expose a versioned HTTP API and operator authentication.
4. Add an offline-capable field client and an SMS-assisted fallback.
5. Pilot with a named cooperative and buyer group; revise the workflow from
   observed transactions.
