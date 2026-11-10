# MabeleLink

MabeleLink is an agriculture coordination product for the Democratic Republic
of the Congo. The MVP starts with a focused workflow: farmers publish produce
available for sale, buyers can discover listings, and a buyer can reserve a
quantity while the service prevents over-reservation.

## Current MVP slice

- OTP application and supervision tree.
- DETS-backed produce listing service (survives normal application restarts).
- Listing validation for farmer, crop, quantity, unit, and location.
- Browse and fetch listings.
- Pending/confirmed/cancelled reservation records, idempotent retries, and an audit event list.
- Bearer-token protection for all data and operator actions.
- Offline browser drafts and an operator queue for confirming or cancelling requests.

This is a supervised single-node pilot slice, not ready for public or multi-user
deployment. The local DETS state is synchronously written as one snapshot, but
DETS does not provide database transactions or multi-node coordination. Move to
PostgreSQL before field use with real transaction volume. The operator key is a
shared credential, not individual user identity.

## Run

Requires Erlang/OTP and rebar3. Configure a fresh operator key before starting
the app. In PowerShell, generate a 256-bit key for the current session:

```powershell
$random = New-Object byte[] 32
$generator = [Security.Cryptography.RandomNumberGenerator]::Create()
$generator.GetBytes($random)
$env:MABELELINK_API_TOKEN = [BitConverter]::ToString($random).Replace('-', '')
rebar3 shell
```

Run the EUnit suite with:

```powershell
rebar3 eunit
```

Open `http://localhost:8080/` to use the browser interface, then enter the
operator key. The key stays in the current browser tab's session storage. The
server binds to `127.0.0.1` only. Do not change the bind address or expose this
HTTP listener to a network; field hosting needs TLS, per-user accounts, and a
production deployment configuration.

The browser caches its app shell and stores unfinished produce forms in local
browser storage. Offline drafts are not sent automatically. After reconnecting,
the operator reviews and submits the draft. An offline buyer request must be
relayed by phone or through the cooperative and entered by an authorized
operator; the operator then verifies stock and confirms or cancels it.

API endpoints:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/healthz` | Health check |
| `GET` | `/api/v1/listings` | Browse listings |
| `POST` | `/api/v1/listings` | Create a produce listing |
| `GET` | `/api/v1/listings/:id` | Fetch one listing |
| `POST` | `/api/v1/listings/:id/reservations` | Request a quantity reservation |
| `GET` | `/api/v1/reservations` | Operator queue |
| `POST` | `/api/v1/reservations/:id/confirm` | Confirm a pending reservation |
| `POST` | `/api/v1/reservations/:id/cancel` | Cancel and return reserved stock |
| `GET` | `/api/v1/audit-events` | Read operator audit events |

All `/api/v1/*` calls require `Authorization: Bearer <operator-key>`. Health
and the static browser shell are public; they do not return business data.

Create a listing with JSON:

```json
{
  "farmer_name": "Amina",
  "crop": "cassava",
  "quantity": 500,
  "unit": "kg",
  "location": "Kongo Central"
}
```

Reserve quantity with `POST /api/v1/listings/1/reservations` and body
`{"quantity":100,"buyer_name":"Marché Central","buyer_contact":"+243..."}`.
The `buyer_contact` field is optional. Send an `Idempotency-Key` header to make
retries of the same request safe. A reservation holds stock in `pending` until
an operator confirms or cancels it. Cancelling restores the held quantity.

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
| 1. Core service (weeks 3–4) | Listing and operator reservation workflow | Validation, pending/confirmed/cancelled reservation records, idempotent retries, audit events |
| 2. Field MVP (weeks 5–8) | Usable low-connectivity experience | French-first responsive interface, offline draft capture, safe sync, phone-assisted listing and reservation support |
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
- DETS is a local single-node snapshot store; its limitations make PostgreSQL
  and tested backup/restore mandatory before real multi-user field use.
- A shared operator key gives no individual accountability; issue per-person
  accounts and roles before expanding beyond a supervised operator pilot.
- Offline reservation requests are never queued automatically, to avoid
  overselling. Use the documented phone/cooperative fallback.

## Next engineering increments

1. Replace DETS with PostgreSQL transactions, migrations, and verified backup/restore.
2. Add individual accounts, operator roles, and an actor identity in every audit event.
3. Test the API and browser workflow end to end, including offline recovery and access controls.
4. Add a field deployment with TLS, monitoring, alerts, and an operator runbook.
5. Pilot with a named cooperative and buyer group; revise the workflow from
   observed transactions.
