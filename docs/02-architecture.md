# 02. System Architecture

## 1. 기술 스택 결정

| 영역 | 선택 | 비고 |
|---|---|---|
| Runtime | **TypeScript + Node.js 22 LTS** (NestJS on Fastify adapter) | 워크로드가 I/O 바운드(PG/OMS/LLM/DB 호출)라 이벤트 루프 모델에 적합. MCP·ACP 공식 SDK가 TS 우선 제공, 가맹점 콘솔(Next.js)과 DTO/zod 스키마 공유. 임베딩·LLM은 호스팅 API 호출이라 Python ML 생태계가 필요 없음 → **단일 언어**로 운영 비용 최소화. NestJS는 모듈/DI 구조로 Hexagonal 경계를 강제하기 쉽다. |
| 구조 | **Modular Monolith** (pnpm workspace + Turborepo, Hexagonal) | 초기 트래픽·팀 규모 대비 MSA는 과설계. 패키지 경계 `catalog / checkout / order / ingestion`을 `eslint-plugin-boundaries`로 강제하고, 필요 시 배포 단위만 분리. |
| 검증/계약 | zod (런타임 검증) → OpenAPI 3.1 생성 (`zod-openapi`) | 요청 스키마 하나로 검증·문서·MCP tool 정의를 함께 생성. |
| DB 접근 | **Kysely** (타입 안전 SQL 빌더) + `node-pg-migrate`(정본 SQL 마이그레이션) | 조건부 UPDATE(재고), `FOR UPDATE SKIP LOCKED`(디스패치 큐), pgvector 연산자 등 SQL 제어가 핵심. Prisma는 부분 인덱스·pgvector·행 잠금 표현이 약해 raw SQL이 늘어남. |
| Ingestion Worker | 같은 코드베이스의 별도 엔트리포인트 | 엑셀(SheetJS 스트리밍)/크롤링(undici + cheerio, JS 렌더링 필요 시 Playwright) 파싱·LLM 정규화. CPU/메모리 패턴이 달라 API Pod과 별도 Deployment. |
| DB | **RDS PostgreSQL 16** + pgvector + pg_bigm | OLTP + 벡터 검색 단일 저장소로 시작. Multi-AZ, Read Replica는 카탈로그 검색용. |
| Cache / Rate limit | **ElastiCache Redis (cluster mode)** | 검색 결과·상품 상세 캐시, 토큰 버킷 레이트리밋, 세션 토큰 → 세션 ID 매핑. |
| 메시징 | **SQS (Standard + DLQ)**, FIFO는 주문 라우팅 큐에만 | 주문 단위 순서 보장이 필요한 곳만 FIFO(`MessageGroupId=orderId`). |
| 오브젝트 | S3 | 원본 상품 파일, 임포트 에러 리포트, 이미지 미러. |
| 임베딩/LLM | Amazon Bedrock (Titan Embed v2 / Claude) | 데이터 국외이전·VPC 엔드포인트 요건 고려해 Bedrock 우선, 어댑터로 교체 가능. |
| 인프라 | EKS, ALB + AWS WAF, KMS, Secrets Manager, Terraform | |
| 관측성 | OpenTelemetry → Prometheus/Grafana, Loki, Tempo | `X-Request-Id` 를 PG/OMS 호출까지 전파. |

## 2. 컴포넌트 다이어그램

```
                     ┌──────────────────────── AI Agent Platforms ────────────────────────┐
                     │   ChatGPT (ACP)      Gemini (AP2/UCP)      Claude (MCP)    기타     │
                     └───────────┬───────────────────┬──────────────────┬───────────────────┘
                                 │ OAuth2 client_credentials (private_key_jwt / mTLS)
                                 ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────┐
│  AWS WAF ─▶ ALB ─▶ EKS                                                                       │
│ ┌──────────────────────────────── agent-gateway (NestJS/Fastify) ──────────────────────────┐ │
│ │  [Edge]  AuthN/Z(scope) · Rate Limit(Redis) · Idempotency · Request Signing · Audit       │ │
│ │  [Protocol Adapters]  REST v1  │  ACP adapter  │  MCP server (tools: search, checkout)    │ │
│ │ ┌───────────────┐  ┌────────────────────┐  ┌──────────────────────┐                      │ │
│ │ │ catalog       │  │ checkout           │  │ order                │                      │ │
│ │ │ - HybridSearch│  │ - Quote/Pricing    │  │ - OrderStateMachine  │                      │ │
│ │ │ - ProductQuery│  │ - InventoryHold    │  │ - RefundPolicy       │                      │ │
│ │ │ - JSON-LD     │  │ - PgBridge(port)   │  │ - OmsRouter(port)    │                      │ │
│ │ └──────┬────────┘  └────────┬───────────┘  └──────────┬───────────┘                      │ │
│ │        │       ┌────────────┴───────────┐             │                                  │ │
│ │        │       │ PG Adapters            │             │  OMS Adapters                    │ │
│ │        │       │ Toss / PortOne / Stripe│             │  Cafe24 / Godomall / Shopify /…  │ │
│ └────────┼───────┴────────────┬───────────┴─────────────┼──────────────────────────────────┘ │
│          │                    │                         │                                    │
│ ┌────────┴─────────┐ ┌────────┴──────────┐ ┌────────────┴──────────┐ ┌──────────────────┐   │
│ │ webhook-receiver │ │ outbox-relay      │ │ order-dispatcher      │ │ ingestion-worker │   │
│ │ (서명검증→Inbox) │ │ (Outbox→SQS)      │ │ (SQS→OMS, 재시도)     │ │ (파싱→LLM 정규화 │   │
│ └────────┬─────────┘ └────────┬──────────┘ └────────────┬──────────┘ │  →임베딩)        │   │
│          │                    │                         │            └────────┬─────────┘   │
└──────────┼────────────────────┼─────────────────────────┼─────────────────────┼─────────────┘
           │                    ▼                         │                     │
           │        ┌────────────────────────┐            │                     │
           │        │ SQS: payment-events    │            │                     │
           │        │      order-dispatch.fifo (+DLQ)     │                     │
           │        │      catalog-ingest    (+DLQ)       │                     │
           │        └────────────────────────┘            │                     │
           ▼                                              ▼                     ▼
┌──────────────────────┐  ┌──────────────────────┐  ┌──────────────┐  ┌──────────────────┐
│ RDS PostgreSQL       │  │ ElastiCache Redis    │  │ S3 (raw/err) │  │ Bedrock          │
│ Writer + Reader(검색)│  │ cache · ratelimit    │  └──────────────┘  │ (embed / LLM)    │
└──────────────────────┘  └──────────────────────┘                    └──────────────────┘
           ▲                                                                   
   KMS (PII envelope) · Secrets Manager (PG/OMS keys)

External:  PG사 ──(webhook)──▶ webhook-receiver        order-dispatcher ──(API)──▶ 가맹점 OMS
           PG사 ◀──(결제 생성/조회/취소 API)── checkout · order
           가맹점 OMS ──(재고/주문상태 webhook 또는 폴링)──▶ agent-gateway(catalog/order)
```

### 모듈 경계 (pnpm workspace)
```
apps/agent-gateway       // API 진입점, 프로토콜 어댑터(REST/ACP/MCP)
apps/webhook-receiver    // 퍼블릭 엔드포인트 분리 (공격면/스케일 분리)
apps/worker              // outbox-relay, order-dispatcher, ingestion, 만료 스위퍼, 리컨실리에이션
apps/merchant-console    // Next.js (App Router) — 가맹점 온보딩/검수/주문 조회
packages/domain-catalog | domain-checkout | domain-order   // 순수 TS, 프레임워크/DB 의존 없음
packages/adapter-pg-{toss,portone,stripe}
packages/adapter-oms-{cafe24,godomall,shopify,webhook}
packages/infra-db (Kysely) | infra-messaging (SQS) | infra-crypto (KMS envelope)
packages/contracts       // zod 스키마 → OpenAPI / MCP tool / 콘솔 타입 공유
```
- 도메인 포트 예: `PaymentGateway.createPayment / inquire / cancel`, `OrderManagementSystem.pushOrder / fetchInventory`.
- **Node 특유 주의점**
  - **금액 BIGINT**: `pg` 드라이버는 `int8`을 문자열로 반환. `Money` 값 객체는 내부적으로 `bigint`를 쓰고 JSON 직렬화 시 `Number.isSafeInteger` 검증 후 number로 내보낸다(KRW는 2^53 한도 내). `parseFloat`/`Number()` 직접 캐스팅 금지 — lint 룰로 차단.
  - **이벤트 루프 블로킹**: 대용량 XLSX 파싱·HTML 정제는 worker_threads 또는 별도 워커 Pod에서만. API Pod은 `event loop lag` 메트릭 알람.
  - **장애 격리**: PG/OMS 호출은 `undici` 타임아웃 + `opossum` 서킷브레이커 + 커넥션풀 상한을 어댑터별로 분리(한 PG 장애가 전체 소켓 풀을 잠식하지 않도록).

## 3. 핵심 플로우

### 3.1 가맹점 온보딩 / 카탈로그 정제
```
Merchant Console ─(엑셀/URL 업로드)─▶ S3 ─▶ catalog_import_jobs(PENDING) ─▶ SQS catalog-ingest
ingestion-worker:
  1. Parse     : XLSX/CSV 스트리밍 파싱 | URL은 JSON-LD/OpenGraph 우선 추출 → 실패 시 HTML 파싱
  2. Normalize : LLM(구조화 출력, JSON Schema 강제)으로 카테고리 매핑·속성 추출·옵션 분해
                 → 규칙 기반 검증(가격>0, 옵션 조합 = SKU 수, 금칙어) → quality_score 산정
  3. Review    : score < 임계치 → REVIEW_REQUIRED (가맹점 검수 UI)
  4. Upsert    : (merchant_id, merchant_product_ref) 기준 멱등 upsert, content_hash 변경 시만 재임베딩
  5. Publish   : schema_org(JSON-LD) 사전 렌더링, 캐시 무효화
```
> LLM은 **추출/정규화에만** 사용하고 가격·재고 수치는 원본 값만 신뢰한다(LLM 환각으로 가격이 바뀌는 사고 방지 — 원본 vs 정규화 결과 수치 diff 검증).

### 3.2 에이전트 탐색 (Hybrid Search)
```
POST /v1/catalog/search
  ├─ Redis 캐시 hit? → 반환 (key = hash(query, filters, agent_scope), TTL 60s)
  ├─ 질의 임베딩 (Bedrock, 질의 임베딩도 Redis 캐시)
  ├─ 병렬 실행 (Reader DB)
  │    ├ Lexical : pg_bigm 유사도 + 구조화 필터(category, price range, attributes @>)
  │    └ Vector  : HNSW cosine top-K (동일 필터를 pre-filter, ef_search 조정)
  ├─ RRF(Reciprocal Rank Fusion) 결합 → quality_score/재고 가중치 재정렬
  └─ merchant_agent_policies 로 노출 불가 가맹점 제외 → 응답
```
- pgvector HNSW + 강한 필터 조합은 recall이 떨어질 수 있음 → `hnsw.iterative_scan`(pgvector ≥0.8) 사용 또는 필터 선택도가 높으면 exact scan으로 분기.

### 3.3 결제 세션 생성 → 결제 → 주문 라우팅
```
Agent              Gateway(checkout)            DB                 PG              User(Browser)
  │ POST /checkout-sessions (Idempotency-Key)                                              
  │──────────────────▶│ 1. idempotency 선점(INSERT … ON CONFLICT)                          
  │                   │ 2. 정책 검증(checkout_enabled, max_order_amount)                   
  │                   │ 3. 서버측 가격 재계산 (에이전트가 보낸 가격 불신)                    
  │                   │ 4. TX{ 재고 홀드(조건부 UPDATE) + session/items INSERT }──▶│       
  │                   │ 5. 1회성 토큰 발급 → checkout_url                                   
  │◀──────────────────│ 201 {checkout_url, expires_at, totals}                             
  │ (사용자에게 URL 제시) ─────────────────────────────────────────────────────────────────▶│
  │                   │◀──────────── GET /pay/{token} (우리 호스티드 결제 페이지) ─────────│
  │                   │ 6. 주문 요약·약관·개인정보 제3자 제공 동의 표시 → PG SDK 결제창 호출     
  │                   │                                      │◀──── 카드 인증/승인요청 ───│
  │                   │ 7. (Toss 등 승인 API 방식) successUrl 리다이렉트 → 서버에서 승인 API 호출
  │                   │                                      │                             
  │       webhook-receiver ◀──────────── payment webhook ────│                             
  │                   │ 8. 서명 검증 → pg_webhook_events INSERT(dedupe) → 200              
  │                   │ 9. 비동기: PG 조회 API로 상태/금액 재확인 (웹훅 바디 불신)          
  │                   │10. TX{ amount == session.total 검증, payment INSERT,                
  │                   │        session COMPLETED, reservation CONSUMED,                    
  │                   │        order/items INSERT, outbox(order.created) }                 
  │                   │11. outbox-relay → SQS order-dispatch.fifo                          
  │                   │12. order-dispatcher → OMS pushOrder (멱등키 = order.id)             
  │                   │      성공: merchant_order_ref 저장, ACCEPTED                       
  │                   │      품절/거절: REJECTED → PG 취소 → REFUNDED                       
  │                   │      일시 오류: 지수 백오프(1m,5m,15m,1h…) → N회 후 DEAD + 알람       
  │◀── (옵션) 에이전트 웹훅: order.accepted / order.shipped / order.refunded               
```

> 7(승인 API 응답)과 8~9(웹훅)는 경쟁 관계다. 둘 다 동일한 `PaymentConfirmationService.confirm(pgOrderId)`로 수렴하며, `checkout_sessions` 를 `SELECT … FOR UPDATE` 후 상태가 이미 `COMPLETED`면 no-op. 먼저 도착한 쪽이 주문을 만들고 나머지는 멱등하게 무시된다.

**사용자 승인(Human-in-the-loop) 원칙**: MVP는 에이전트가 결제를 *직접 실행하지 않는다*. 에이전트는 URL만 받고, 실제 인증·승인은 사용자가 PG 결제창에서 수행한다. 이후 ACP Delegated Payment(Shared Payment Token)·AP2 Mandate 기반 무인 결제는 PG가 해당 토큰을 지원하는 범위에서 `PgBridge` 어댑터로 확장한다.

## 4. 규제·보안 아키텍처 (금융 도메인)

1. **자금 비보유 구조 (가장 중요)**: 결제는 *가맹점 자신의 PG MID*로 승인되고 정산도 PG → 가맹점으로 직접 이뤄진다. 플랫폼이 대금을 수취해 재지급하면 전자금융거래법상 **PG업(전자지급결제대행업) 등록** 대상이 될 수 있다. 플랫폼 수수료는 별도 청구(월 인보이스)하거나 PG의 지급대행/분할정산 기능(PG가 등록업자로 수행)을 활용 — **법무 검토 필수 항목**.
2. **카드정보 비취급**: 카드번호는 PG 결제창/SDK에서만 입력 → 플랫폼은 PCI-DSS 범위 밖(SAQ-A 수준) 유지. 우리 호스티드 페이지에서 카드 입력 필드를 직접 렌더링하지 않는다.
3. **개인정보**: 구매자 정보는 가맹점에 *제3자 제공*되므로 결제 페이지에서 동의 수집, 증적은 `checkout_sessions.buyer_consent`. 보관기한(전자상거래법: 계약·대금결제 기록 5년) 경과 시 파기 배치.
4. **에이전트 인증**: OAuth2 client_credentials + `private_key_jwt`(또는 mTLS). Access token 5분 TTL, scope: `catalog:read`, `checkout:write`, `orders:read`.
5. **Checkout URL 토큰**: 256bit 랜덤, DB에는 SHA-256만 저장, 1회 사용 + 세션 TTL, 결제 페이지는 `Referrer-Policy: no-referrer`, `Cache-Control: no-store`.
6. **웹훅 신뢰 경계**: 서명 검증 + 출발지 IP allowlist(PG 공지 대역) + **PG 조회 API 재검증**. 웹훅 바디만으로 주문 확정 금지.
7. **감사 로그**: PII 열람, 환불/취소, 정책 변경, PG/OMS 자격증명 교체는 모두 `audit_logs`. 애플리케이션 DB 유저는 INSERT만.

## 5. 비기능 요구사항 & 장애 대응

| 항목 | 목표 |
|---|---|
| 검색 API | p95 < 300ms (캐시 hit < 30ms), 가용성 99.9% |
| 체크아웃 생성 | p95 < 500ms (PG 호출 없음 — URL은 우리 도메인), 가용성 99.95% |
| 웹훅 수신 | p99 < 200ms ACK (DB INSERT만), PG 재전송 정책 내 처리 |
| 주문 전송 | 결제 후 OMS 반영 p95 < 30s, 최종 실패 시 운영 알람 5분 내 |

| 장애 시나리오 | 대응 |
|---|---|
| PG 장애 | 결제 페이지에서 장애 PG 차단, 가맹점에 보조 MID 있으면 failover. Circuit Breaker(opossum). |
| 웹훅 유실 | 리컨실리에이션 배치: `PAYMENT_PENDING` 세션을 5분 주기로 PG 조회 → 승인 건 처리. **웹훅은 최적화일 뿐 정합성 근거는 PG 조회.** |
| OMS 장애/토큰 만료 | 디스패치 재시도 + `merchant_oms_connections.status=AUTH_EXPIRED` → 가맹점 알림. 장시간 실패 시 해당 가맹점 `checkout_enabled` 자동 OFF (결제는 됐는데 주문이 안 들어가는 상황 확산 방지). |
| OMS 품절 거절 | 자동 PG 전액 취소 + 에이전트/구매자 통지. 취소 실패는 DLQ + 수동 처리 대시보드. |
| DB Writer 장애 | Multi-AZ failover(~60s). 검색은 Reader로 무영향, 체크아웃은 503 + `Retry-After`. 멱등키 덕분에 에이전트 재시도 안전. |
| 일일 대사 | PG 거래내역(정산 파일/API) ↔ `payments` ↔ `orders` 3-way 대사 배치, 불일치 리포트. |

## 6. 오픈 이슈 (의사결정 필요)

1. 플랫폼 수수료 수취 방식 (별도 청구 vs PG 분할정산) — 법무/재무 검토.
2. 1차 지원 PG: 국내 가맹점 기준 Toss Payments + PortOne(멀티 PG 흡수) 우선, Stripe는 해외 가맹점 확장 시.
3. 1차 지원 OMS: 카페24(점유율)·고도몰 우선. 나머지는 `CUSTOM_WEBHOOK` 표준 스펙으로 흡수.
4. 프로토콜: 자체 REST를 정본으로 두고 ACP / MCP 는 어댑터 레이어. 스펙 변화 속도가 빨라 도메인 모델에 프로토콜 필드를 직접 섞지 않는다.
