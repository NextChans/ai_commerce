# 03. Core Agent API Spec (v1)

AI 에이전트가 호출하는 **상품 검색 API**와 **결제 세션 생성 API** 명세. 자체 REST가 정본이며, ACP/MCP 어댑터는 이 API를 래핑한다.

## 0. 공통 규약

| 항목 | 규약 |
|---|---|
| Base URL | `https://api.{domain}/v1` |
| 인증 | `Authorization: Bearer <access_token>` (OAuth2 client_credentials, `private_key_jwt`) |
| Scope | 검색/조회 `catalog:read`, 체크아웃 `checkout:write` |
| 멱등성 | 모든 `POST` 상태 변경 요청에 `Idempotency-Key` (UUID/ULID, ≤ 64자) **필수**. 24h 보관. 같은 키+같은 바디 → 최초 응답 재생, 같은 키+다른 바디 → `422`, 처리 중 → `409` |
| 추적 | `X-Request-Id` 요청 시 그대로 전파, 미전송 시 서버 생성하여 응답 헤더로 반환 |
| 금액 | `{ "amount": 129000, "currency": "KRW" }` — 정수 minor unit. 문자열/소수 금지 |
| 시간 | RFC 3339 UTC (`2026-10-07T03:00:00Z`) |
| 레이트리밋 | `RateLimit-Limit`, `RateLimit-Remaining`, `RateLimit-Reset` 헤더. 초과 시 `429` + `Retry-After` |
| 에러 | RFC 9457 `application/problem+json` + 기계 판독용 `code` |
| 버저닝 | URL 메이저 버전. 응답에 필드 추가는 하위호환으로 간주 → 클라이언트는 unknown field 무시 |

### 에러 포맷
```json
{
  "type": "https://docs.{domain}/errors/price-changed",
  "title": "Price changed",
  "status": 409,
  "code": "PRICE_CHANGED",
  "detail": "var_01J9Z… price changed from 129000 to 119000",
  "request_id": "req_01J9Z…",
  "retryable": false,
  "agent_hint": "Re-fetch the product and confirm the new price with the user before retrying."
}
```
> `agent_hint`: LLM 에이전트가 다음 행동을 결정할 수 있도록 자연어 가이드를 함께 준다. 에이전트 대상 API의 핵심 UX.

| code | HTTP | retryable | 의미 |
|---|---|---|---|
| `INVALID_REQUEST` | 400 | N | 스키마 위반 |
| `UNAUTHORIZED` / `FORBIDDEN_SCOPE` | 401 / 403 | N | 인증 실패 / scope 부족 |
| `MERCHANT_NOT_AVAILABLE` | 403 | N | 가맹점이 해당 에이전트에 체크아웃 미허용 |
| `NOT_FOUND` | 404 | N | |
| `IDEMPOTENCY_IN_PROGRESS` | 409 | Y | 동일 키 처리 중 |
| `PRICE_CHANGED` | 409 | N | `expected_unit_price` 불일치 |
| `OUT_OF_STOCK` | 409 | N | 재고 홀드 실패 (`detail` 에 가용 수량) |
| `IDEMPOTENCY_KEY_REUSED` | 422 | N | 같은 키, 다른 바디 |
| `ORDER_LIMIT_EXCEEDED` | 422 | N | 가맹점/에이전트 정책상 최대 주문금액 초과 |
| `RATE_LIMITED` | 429 | Y | |
| `UPSTREAM_UNAVAILABLE` | 503 | Y | 내부/DB 장애, `Retry-After` 포함 |

---

## 1. 상품 검색 API

### `POST /v1/catalog/search`
복합 필터와 자연어 질의를 함께 받기 위해 `POST`를 사용한다 (부작용 없음, 멱등키 불필요, 캐시 가능).

**Request**
```json
{
  "query": "원룸에 놓을 화이트 수납 침대 퀸사이즈",
  "mode": "hybrid",
  "filters": {
    "category": ["가구", "침대"],
    "price": { "min": 100000, "max": 500000, "currency": "KRW" },
    "attributes": { "color": ["화이트"], "bed_size": ["Q"] },
    "in_stock_only": true,
    "merchant_ids": null
  },
  "sort": "relevance",
  "limit": 20,
  "cursor": null,
  "include": ["variants", "schema_org"]
}
```

| 필드 | 타입 | 필수 | 설명 |
|---|---|---|---|
| `query` | string(≤512) | N* | 자연어 질의. `query`·`filters` 중 하나는 필수 |
| `mode` | `hybrid` \| `lexical` \| `semantic` | N | 기본 `hybrid` (bigm + vector, RRF 결합) |
| `filters.category` | string[] | N | 표준 카테고리 경로 prefix |
| `filters.price` | object | N | variant 판매가 기준, 포함 범위 |
| `filters.attributes` | map<string,string[]> | N | 카테고리 스키마 속성. 키별 AND, 값 목록 OR. 사용 가능한 키는 `GET /v1/catalog/categories/{path}/schema` |
| `filters.in_stock_only` | bool | N | 기본 `true`. `available_quantity > 0` 인 variant 보유 상품만 |
| `sort` | `relevance` \| `price_asc` \| `price_desc` \| `newest` | N | |
| `limit` | int(1–50) | N | 기본 20. 에이전트 컨텍스트 윈도우 보호를 위해 상한 50 |
| `cursor` | string | N | opaque 커서 (offset 페이징 미지원) |
| `include` | string[] | N | `variants`, `schema_org`, `description` — 기본 응답은 토큰 절약형 요약 |

**Response `200`**
```json
{
  "results": [
    {
      "product_id": "prd_01J9Z8X3…",
      "merchant": { "id": "mch_01J9…", "name": "하우스퍼니처", "return_policy_url": "https://…" },
      "title": "모던 화이트 수납 침대 프레임 Q",
      "brand": "하우스퍼니처",
      "category": ["가구", "침대", "침대프레임"],
      "summary": "서랍 4칸 수납형 퀸 침대 프레임, E0 등급 PB 소재",
      "key_attributes": { "color": "화이트", "bed_size": "Q", "material": "PB(E0)", "storage": "서랍형" },
      "price_range": {
        "min": { "amount": 289000, "currency": "KRW" },
        "max": { "amount": 319000, "currency": "KRW" }
      },
      "availability": {
        "status": "IN_STOCK",
        "stock_synced_at": "2026-10-07T02:58:12Z",
        "freshness": "FRESH"
      },
      "image_url": "https://cdn.{domain}/i/prd_01J9Z8X3/0.webp",
      "product_url": "https://merchant.example.com/goods/12345",
      "variants": [
        {
          "variant_id": "var_01J9Z8X4…",
          "options": { "color": "화이트", "bed_size": "Q" },
          "price": { "amount": 289000, "currency": "KRW" },
          "list_price": { "amount": 359000, "currency": "KRW" },
          "available_quantity": 12,
          "purchasable": true
        }
      ],
      "score": 0.87
    }
  ],
  "next_cursor": "eyJrIjoi…",
  "search_meta": { "mode": "hybrid", "latency_ms": 84, "total_estimate": 143 }
}
```

- `availability.freshness`: `FRESH`(<10분) / `STALE`(<24h) / `UNKNOWN`. 에이전트가 사용자에게 "재고는 결제 시 확정"을 안내할지 판단하는 근거.
- `available_quantity` = `stock_quantity - reserved_quantity`, 노출 상한 99 (재고 정보 스크래핑 완화).
- 가격은 **조회 시점 표시가**이며 확정 가격은 체크아웃 세션 생성 응답이 기준.

### `GET /v1/products/{product_id}`
단건 상세. `?include=schema_org,description,variants`. 응답 `ETag` / `If-None-Match` 지원(`304`). 404 시 `NOT_FOUND`, 판매중지 상품은 `200` + `status: INACTIVE` (에이전트가 "단종"을 사용자에게 설명할 수 있도록).

---

## 2. 결제 세션 생성 API

### `POST /v1/checkout-sessions`
에이전트가 구매를 결정하면 호출. 결제는 **플랫폼 MID**(Toss Payments 또는 KG이니시스)로 이루어지므로 **여러 하위몰 상품을 한 세션에 담을 수 있다**(통합결제). 플랫폼은 **서버측으로 가격을 재계산**하고, 재고를 홀드한 뒤 사용자가 승인할 **1회성 결제 URL**을 반환한다. 이 시점엔 PG 호출이 없다(PG 결제창은 사용자가 URL을 열 때 생성).

**Headers**
```
Authorization: Bearer eyJ…
Idempotency-Key: 01J9ZA0K6T5Q2X3N7Y8B1C4D5E
Content-Type: application/json
```

**Request**
```json
{
  "line_items": [
    {
      "variant_id": "var_01J9Z8X4…",
      "quantity": 1,
      "expected_unit_price": { "amount": 289000, "currency": "KRW" }
    },
    {
      "variant_id": "var_01J9ZC7Q…",
      "quantity": 2,
      "expected_unit_price": { "amount": 24900, "currency": "KRW" }
    }
  ],
  "buyer": {
    "name": "홍길동",
    "email": "buyer@example.com",
    "phone": "+821012345678"
  },
  "shipping_address": {
    "recipient": "홍길동",
    "phone": "+821012345678",
    "postal_code": "06236",
    "address1": "서울특별시 강남구 테헤란로 123",
    "address2": "4층",
    "country": "KR",
    "delivery_note": "부재 시 문 앞"
  },
  "agent_context": {
    "reference_id": "conv_abc123:turn_17",
    "user_locale": "ko-KR"
  },
  "redirect": {
    "success_url": "https://agent.example.com/checkout/return?status=success",
    "cancel_url": "https://agent.example.com/checkout/return?status=cancel"
  }
}
```

| 필드 | 필수 | 검증 |
|---|---|---|
| `line_items[]` | Y | 1–20개, variant 중복 불가. 하위몰 최대 5곳. 각 하위몰은 `merchant_agent_policies.checkout_enabled = true` 이고 정산 프로필 `kyc_status = APPROVED` 여야 함. 하나라도 위반하면 세션 전체를 거부(원자성), 위반 variant는 `detail`/`invalid_items`로 반환 |
| `line_items[].quantity` | Y | 1–99 |
| `line_items[].expected_unit_price` | Y | 서버 현재가와 다르면 `409 PRICE_CHANGED` (에이전트가 사용자에게 보여준 가격 = 결제 가격 보장) |
| `buyer` | N | 생략 시 결제 페이지에서 사용자가 직접 입력 (PII 최소 수집 원칙상 권장) |
| `shipping_address` | N | 위와 동일. 제공 시 배송비 즉시 계산 |
| `agent_context.reference_id` | N | 분쟁/CS 시 에이전트 대화 추적용 (≤128자) |
| `redirect.*_url` | N | `agent_clients` 에 사전 등록된 origin 만 허용 (open redirect 방지) |

**Response `201 Created`**
```json
{
  "id": "cs_01J9ZA0M2…",
  "status": "OPEN",
  "merchant_groups": [
    {
      "merchant": { "id": "mch_01J9…", "name": "하우스퍼니처" },
      "line_items": [
        {
          "variant_id": "var_01J9Z8X4…",
          "title": "모던 화이트 수납 침대 프레임 Q",
          "options": { "color": "화이트", "bed_size": "Q" },
          "quantity": 1,
          "unit_price": { "amount": 289000, "currency": "KRW" },
          "line_total": { "amount": 289000, "currency": "KRW" }
        }
      ],
      "shipping": { "amount": 0, "currency": "KRW" },
      "total":    { "amount": 289000, "currency": "KRW" }
    },
    {
      "merchant": { "id": "mch_01J9K…", "name": "리빙소품샵" },
      "line_items": [
        {
          "variant_id": "var_01J9ZC7Q…",
          "title": "린넨 베개커버 50x70",
          "options": { "color": "오트밀" },
          "quantity": 2,
          "unit_price": { "amount": 24900, "currency": "KRW" },
          "line_total": { "amount": 49800, "currency": "KRW" }
        }
      ],
      "shipping": { "amount": 3000, "currency": "KRW" },
      "total":    { "amount": 52800, "currency": "KRW" }
    }
  ],
  "totals": {
    "subtotal": { "amount": 338800, "currency": "KRW" },
    "shipping": { "amount": 3000, "currency": "KRW" },
    "discount": { "amount": 0, "currency": "KRW" },
    "total":    { "amount": 341800, "currency": "KRW" }
  },
  "checkout_url": "https://pay.{domain}/c/Zk3n…(43 chars)…",
  "expires_at": "2026-10-07T03:30:00Z",
  "inventory_hold": { "held": true, "expires_at": "2026-10-07T03:30:00Z" },
  "payment_methods": ["CARD", "EASY_PAY", "TRANSFER"],
  "agent_hint": "Show checkout_url to the user. One payment covers all merchants; items ship separately per merchant. Payment must be approved within 30 minutes. Poll GET /v1/checkout-sessions/{id} or subscribe to webhooks for the result."
}
```
- 배송비는 하위몰별로 계산된다(묶음배송 단위 = 하위몰). `merchant_groups[].total`의 합 = `totals.total`.
- 결제 페이지에는 하위몰별 판매자 정보(상호·사업자번호·통신판매업 신고번호)와 "플랫폼은 통신판매중개자" 고지를 표시한다(전자상거래법).
- `checkout_url`은 **이 응답에서 단 한 번만** 원문으로 반환된다(서버는 해시만 저장). 같은 `Idempotency-Key` 재시도 시에는 멱등 응답 캐시에서 재생.
- 기본 TTL 30분 (가맹점 정책으로 10–60분 조정).

### `GET /v1/checkout-sessions/{id}`
상태 폴링. `checkout_url` 은 반환하지 않음. 하위몰별 주문 상태가 따로 움직이므로(위 예시: 한 곳은 품절 거절 → 부분환불) 에이전트는 `orders[]` 단위로 사용자에게 안내해야 한다. 권장 폴링 간격 5s 이상, 대신 에이전트 웹훅(`checkout.completed`, `order.accepted`, `order.refunded`) 구독 권장.
```json
{
  "id": "cs_01J9ZA0M2…",
  "status": "COMPLETED",
  "totals": { "total": { "amount": 341800, "currency": "KRW" } },
  "payment": { "pg_provider": "TOSS", "method": "CARD", "approved_amount": { "amount": 341800, "currency": "KRW" } },
  "orders": [
    { "id": "ord_01J9ZB…", "merchant_id": "mch_01J9…",  "status": "ACCEPTED", "merchant_order_ref": "20261007-0001234",
      "total": { "amount": 289000, "currency": "KRW" }, "refunded": { "amount": 0, "currency": "KRW" } },
    { "id": "ord_01J9ZC…", "merchant_id": "mch_01J9K…", "status": "REJECTED", "merchant_order_ref": null,
      "total": { "amount": 52800, "currency": "KRW" },  "refunded": { "amount": 52800, "currency": "KRW" } }
  ],
  "expires_at": "2026-10-07T03:30:00Z",
  "completed_at": "2026-10-07T03:04:51Z"
}
```

### `POST /v1/checkout-sessions/{id}/cancel`
`OPEN` / `PAYMENT_PENDING` 에서만 가능 → 재고 홀드 해제. `Idempotency-Key` 필수. 이미 `COMPLETED`면 `409` (주문 취소는 별도 `POST /v1/orders/{id}/cancel`).

---

## 3. 서버 처리 순서 (구현 가이드: `POST /v1/checkout-sessions`)

```ts
// 의사코드 — 트랜잭션 경계와 실패 지점 명시
async function createCheckoutSession(cmd: CreateCheckoutCommand): Promise<CheckoutSessionResult> {
  const claimed = await idempotency.claim(cmd.agentId, cmd.idempotencyKey, cmd.requestHash); // INSERT ON CONFLICT
  if (claimed.kind === 'replay') return claimed.response;          // 완료 응답 재생 (처리중 409 / 바디 상이 422 는 throw)

  try {
    const result = await db.transaction().execute(async (trx) => {
      const variants = await variantRepo.findActive(trx, cmd.variantIds);          // ACTIVE 검증
      const groups = groupByMerchant(variants, cmd.lineItems);                     // 하위몰 ≤ 5
      const policies = await policyRepo.getMany(trx, groups.merchantIds, cmd.agentId);
      policies.requireCheckoutEnabledAndKycApproved();              // 403 MERCHANT_NOT_AVAILABLE (+ invalid_items)

      const quote = pricing.quote(groups, cmd.shipping);            // 하위몰별 소계/배송비 서버측 재계산 (bigint)
      quote.assertMatches(cmd.expectedPrices);                      // 409 PRICE_CHANGED
      policies.assertWithinLimit(quote);                            // 422 ORDER_LIMIT_EXCEEDED (하위몰별 한도)

      for (const item of [...cmd.lineItems].sort(byVariantId)) {    // 데드락 방지: 고정 순서로 락
        await inventory.hold(trx, item.variantId, item.quantity);   // 조건부 UPDATE, 0 row → 409 OUT_OF_STOCK
      }

      const token = CheckoutToken.generate();                       // crypto.randomBytes(32), DB엔 sha256만
      const pgAccount = await pgRouter.pickPrimary(trx, quote.currency);           // Toss/이니시스 중 활성 primary
      const session = await sessionRepo.insert(trx, {                 // sessions + session_merchants + items
        quote, cmd, pgAccount, tokenHash: token.hash, ttl: policies.minTtl,
      });
      return { session, checkoutUrl: token.toUrl() };
    });
    await idempotency.complete(cmd, 201, result);
    return result;
  } catch (e) {
    await idempotency.release(cmd);                                 // 실패 시 키 해제(재시도 허용)
    throw e;
  }
}
```

## 4. 리뷰 포인트 / 남은 결정

1. **`expected_unit_price` 강제**는 에이전트 UX상 마찰(가격 변동 시 재조회 필요)이 있지만, "AI가 보여준 가격과 실제 결제 가격이 다르다"는 분쟁을 원천 차단하므로 유지 권장.
2. **PII를 에이전트가 전달하는 경로**: 에이전트 플랫폼이 사용자 주소를 보유한 경우 편의성이 크지만, 개인정보 수집 주체·제3자 제공 고지가 복잡해진다. MVP는 *선택 필드*로 두고 결제 페이지에서 동의와 함께 최종 확정.
3. **재고 홀드 남용**: 악성/버그 에이전트가 세션을 대량 생성해 재고를 묶을 수 있음 → 에이전트별 `OPEN` 세션 수 상한, variant별 1세션 최대 홀드 수량, 미결제율 모니터링.
4. **검색 API 스크래핑**: 경쟁사 가격 수집 악용 가능 → 에이전트 계약 기반 발급, 레이트리밋 티어, `available_quantity` 상한 노출.
5. **통합결제의 부분 실패 UX**: 하위몰 A는 접수, B는 품절 거절 → B만 부분환불. 결제수단별 부분취소 제약(가상계좌 환불계좌 수집 등)을 결제 페이지에서 미리 안내해야 합니다.
6. 다음 단계로 이 명세를 OpenAPI 3.1 로 옮겨 계약 테스트(schemathesis)와 MCP tool 정의를 자동 생성하는 것을 권장. `packages/contracts`의 zod 스키마를 단일 소스로 둔다.
