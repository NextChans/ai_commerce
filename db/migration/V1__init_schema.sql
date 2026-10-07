-- =============================================================================
-- Agentic Commerce Gateway - Initial Schema (PostgreSQL 16, RDS)
--
-- 설계 원칙
--  * 금액: BIGINT minor unit (KRW=원, USD=cent) + ISO-4217 currency. FLOAT/NUMERIC 금지.
--  * 외부 노출 ID: prefix + ULID TEXT (e.g. 'cs_01J9...'). 시간순 정렬, 추측 불가.
--  * 상태값: PG ENUM 대신 TEXT + CHECK (무중단 마이그레이션 용이).
--  * 정합성 핵심 테이블은 version 컬럼으로 낙관적 락.
--  * PII(구매자 연락처/배송지)는 애플리케이션 레벨 envelope 암호화(KMS) 후 BYTEA 저장.
--    조회가 필요한 값은 HMAC-SHA256 blind index(*_hash) 를 별도 보관.
--  * PG/OMS 자격증명은 DB에 저장하지 않고 Secrets Manager ARN만 참조.
--  * 상태 이력/감사 로그는 append-only.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS vector;   -- pgvector (RDS 지원)
CREATE EXTENSION IF NOT EXISTS pg_bigm;  -- 한글 2-gram 부분일치 검색 (RDS 지원)

-- -----------------------------------------------------------------------------
-- 1. Merchant (가맹점)
-- -----------------------------------------------------------------------------
CREATE TABLE merchants (
    id                  TEXT PRIMARY KEY CHECK (id LIKE 'mch\_%'),
    legal_name          TEXT        NOT NULL,
    display_name        TEXT        NOT NULL,
    business_reg_no     TEXT        NOT NULL UNIQUE,          -- 사업자등록번호
    mail_order_reg_no   TEXT,                                  -- 통신판매업 신고번호
    status              TEXT        NOT NULL DEFAULT 'ONBOARDING'
                        CHECK (status IN ('ONBOARDING','ACTIVE','SUSPENDED','TERMINATED')),
    default_currency    CHAR(3)     NOT NULL DEFAULT 'KRW',
    support_contact     JSONB       NOT NULL DEFAULT '{}'::jsonb,
    return_policy       JSONB       NOT NULL DEFAULT '{}'::jsonb, -- 에이전트에 노출할 교환/반품 정책
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 가맹점별 PG 계정. 자금은 가맹점 MID로 직접 정산 → 플랫폼은 자금 비보유(PG업 등록 회피).
CREATE TABLE merchant_pg_accounts (
    id                      TEXT PRIMARY KEY CHECK (id LIKE 'mpg\_%'),
    merchant_id             TEXT        NOT NULL REFERENCES merchants(id),
    pg_provider             TEXT        NOT NULL CHECK (pg_provider IN ('TOSS','PORTONE','STRIPE')),
    pg_mid                  TEXT        NOT NULL,
    credentials_secret_arn  TEXT        NOT NULL,   -- API secret key (Secrets Manager)
    webhook_secret_arn      TEXT,                   -- 웹훅 서명 검증 키
    is_default              BOOLEAN     NOT NULL DEFAULT false,
    status                  TEXT        NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','DISABLED')),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (pg_provider, pg_mid)
);
CREATE UNIQUE INDEX uq_merchant_pg_default
    ON merchant_pg_accounts (merchant_id) WHERE is_default AND status = 'ACTIVE';

-- 가맹점 OMS(카페24/고도몰/메이크샵/Shopify/자체 Webhook) 연동 정보
CREATE TABLE merchant_oms_connections (
    id                      TEXT PRIMARY KEY CHECK (id LIKE 'oms\_%'),
    merchant_id             TEXT        NOT NULL REFERENCES merchants(id),
    oms_type                TEXT        NOT NULL
                            CHECK (oms_type IN ('CAFE24','GODOMALL','MAKESHOP','SHOPIFY','CUSTOM_WEBHOOK')),
    endpoint_url            TEXT,
    credentials_secret_arn  TEXT        NOT NULL,   -- OAuth refresh token 등
    supports_inventory_push BOOLEAN     NOT NULL DEFAULT false, -- OMS → 플랫폼 재고 웹훅 지원 여부
    inventory_poll_interval INTERVAL,               -- push 미지원 시 폴링 주기
    status                  TEXT        NOT NULL DEFAULT 'ACTIVE'
                            CHECK (status IN ('ACTIVE','AUTH_EXPIRED','DISABLED')),
    last_healthy_at         TIMESTAMPTZ,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_oms_active_per_merchant
    ON merchant_oms_connections (merchant_id) WHERE status <> 'DISABLED';

-- -----------------------------------------------------------------------------
-- 2. Agent Client (AI 에이전트 플랫폼 = API 소비자)
-- -----------------------------------------------------------------------------
CREATE TABLE agent_clients (
    id                  TEXT PRIMARY KEY CHECK (id LIKE 'agt\_%'),
    name                TEXT        NOT NULL UNIQUE,     -- e.g. 'openai-chatgpt'
    oauth_client_id     TEXT        NOT NULL UNIQUE,
    client_secret_hash  TEXT,                            -- argon2id. mTLS/private_key_jwt 사용 시 NULL
    jwks_uri            TEXT,                            -- private_key_jwt 클라이언트 인증
    scopes              TEXT[]      NOT NULL DEFAULT ARRAY['catalog:read'],
    rate_limit_tier     TEXT        NOT NULL DEFAULT 'STANDARD',
    status              TEXT        NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','SUSPENDED')),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 가맹점이 어떤 에이전트에 노출/판매를 허용할지 (opt-in) + 리스크 한도
CREATE TABLE merchant_agent_policies (
    merchant_id         TEXT        NOT NULL REFERENCES merchants(id),
    agent_client_id     TEXT        NOT NULL REFERENCES agent_clients(id),
    catalog_enabled     BOOLEAN     NOT NULL DEFAULT true,
    checkout_enabled    BOOLEAN     NOT NULL DEFAULT false,
    max_order_amount    BIGINT      CHECK (max_order_amount > 0),
    commission_bps      INT         NOT NULL DEFAULT 0 CHECK (commission_bps BETWEEN 0 AND 10000),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (merchant_id, agent_client_id)
);

-- -----------------------------------------------------------------------------
-- 3. Catalog (상품)
-- -----------------------------------------------------------------------------
CREATE TABLE catalog_import_jobs (
    id                  TEXT PRIMARY KEY CHECK (id LIKE 'imp\_%'),
    merchant_id         TEXT        NOT NULL REFERENCES merchants(id),
    source_type         TEXT        NOT NULL
                        CHECK (source_type IN ('CSV','XLSX','URL_CRAWL','OMS_API','MANUAL')),
    source_uri          TEXT        NOT NULL,             -- s3://... 원본 보관 (재처리/감사)
    status              TEXT        NOT NULL DEFAULT 'PENDING'
                        CHECK (status IN ('PENDING','PARSING','NORMALIZING','REVIEW_REQUIRED','COMPLETED','FAILED')),
    stats               JSONB       NOT NULL DEFAULT '{}'::jsonb, -- {total, created, updated, rejected}
    error_report_uri    TEXT,
    requested_by        TEXT        NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at         TIMESTAMPTZ
);

CREATE TABLE products (
    id                  TEXT PRIMARY KEY CHECK (id LIKE 'prd\_%'),
    merchant_id         TEXT        NOT NULL REFERENCES merchants(id),
    merchant_product_ref TEXT       NOT NULL,             -- 가맹점 OMS 상품번호
    title               TEXT        NOT NULL,
    description         TEXT,                             -- 정제된 plain text (HTML 제거)
    brand               TEXT,
    gtin                TEXT,                             -- 바코드/GTIN (있을 때만)
    category_path       TEXT[]      NOT NULL DEFAULT '{}',-- 표준 카테고리 ['가구','침대','프레임']
    attributes          JSONB       NOT NULL DEFAULT '{}'::jsonb, -- 카테고리 스키마로 정규화된 스펙
    schema_org          JSONB,                            -- 사전 렌더링한 JSON-LD (Product)
    image_urls          TEXT[]      NOT NULL DEFAULT '{}',
    canonical_url       TEXT,                             -- 원 쇼핑몰 상품 URL
    status              TEXT        NOT NULL DEFAULT 'DRAFT'
                        CHECK (status IN ('DRAFT','ACTIVE','INACTIVE','DELETED')),
    quality_score       SMALLINT    CHECK (quality_score BETWEEN 0 AND 100), -- 정제 품질 (노출 랭킹/검수)
    source_import_job_id TEXT       REFERENCES catalog_import_jobs(id),
    content_hash        TEXT        NOT NULL,             -- 재임베딩 필요 여부 판단
    version             INT         NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (merchant_id, merchant_product_ref)
);
CREATE INDEX idx_products_merchant_status ON products (merchant_id, status);
CREATE INDEX idx_products_category        ON products USING GIN (category_path);
CREATE INDEX idx_products_attributes      ON products USING GIN (attributes jsonb_path_ops);
CREATE INDEX idx_products_title_bigm      ON products USING GIN (title gin_bigm_ops);

-- 판매 단위(SKU). 가격/재고는 variant 레벨.
CREATE TABLE product_variants (
    id                  TEXT PRIMARY KEY CHECK (id LIKE 'var\_%'),
    product_id          TEXT        NOT NULL REFERENCES products(id),
    merchant_id         TEXT        NOT NULL REFERENCES merchants(id), -- 비정규화: 테넌트 필터
    merchant_sku        TEXT        NOT NULL,
    option_values       JSONB       NOT NULL DEFAULT '{}'::jsonb, -- {"color":"화이트","size":"Q"}
    currency            CHAR(3)     NOT NULL DEFAULT 'KRW',
    price_amount        BIGINT      NOT NULL CHECK (price_amount >= 0),       -- 판매가 (VAT 포함)
    list_price_amount   BIGINT      CHECK (list_price_amount >= 0),           -- 정가
    stock_quantity      INT         NOT NULL DEFAULT 0 CHECK (stock_quantity >= 0),   -- OMS 동기화 값
    reserved_quantity   INT         NOT NULL DEFAULT 0 CHECK (reserved_quantity >= 0),-- 체크아웃 홀드
    stock_synced_at     TIMESTAMPTZ,                      -- 재고 신선도 → 에이전트에 노출
    status              TEXT        NOT NULL DEFAULT 'ACTIVE'
                        CHECK (status IN ('ACTIVE','SOLD_OUT','INACTIVE')),
    version             INT         NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (merchant_id, merchant_sku),
    CHECK (reserved_quantity <= stock_quantity)
);
CREATE INDEX idx_variants_product ON product_variants (product_id);
CREATE INDEX idx_variants_price   ON product_variants (merchant_id, price_amount) WHERE status = 'ACTIVE';

-- 벡터 검색용 임베딩. 모델 교체(blue/green) 대비 (product_id, model) 복합키.
-- 차원은 컬럼 타입에 고정되므로 모델 차원이 바뀌면 신규 컬럼/테이블로 마이그레이션.
CREATE TABLE product_embeddings (
    product_id          TEXT        NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    model               TEXT        NOT NULL,             -- e.g. 'titan-embed-text-v2:1024'
    embedding           vector(1024) NOT NULL,
    source_content_hash TEXT        NOT NULL,             -- = products.content_hash 일 때 최신
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (product_id, model)
);
CREATE INDEX idx_product_embeddings_hnsw
    ON product_embeddings USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64);

-- -----------------------------------------------------------------------------
-- 4. Checkout Session (에이전트 결제 세션)
--    * 1 세션 = 1 가맹점 (가맹점 MID로 직접 결제되므로 멀티 가맹점 장바구니는 세션 분리)
--    * 생성 시점 가격/수량을 스냅샷하여 이후 상품가 변경과 무관하게 결제 금액 고정
-- -----------------------------------------------------------------------------
CREATE TABLE checkout_sessions (
    id                  TEXT PRIMARY KEY CHECK (id LIKE 'cs\_%'),
    merchant_id         TEXT        NOT NULL REFERENCES merchants(id),
    agent_client_id     TEXT        NOT NULL REFERENCES agent_clients(id),
    merchant_pg_account_id TEXT     NOT NULL REFERENCES merchant_pg_accounts(id),
    status              TEXT        NOT NULL DEFAULT 'OPEN'
                        CHECK (status IN ('OPEN','PAYMENT_PENDING','COMPLETED','EXPIRED','CANCELED','FAILED')),
    currency            CHAR(3)     NOT NULL,
    subtotal_amount     BIGINT      NOT NULL CHECK (subtotal_amount >= 0),
    shipping_amount     BIGINT      NOT NULL DEFAULT 0 CHECK (shipping_amount >= 0),
    discount_amount     BIGINT      NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
    total_amount        BIGINT      NOT NULL CHECK (total_amount >= 0),
    -- 구매자 PII (envelope encryption)
    buyer_name_enc      BYTEA,
    buyer_email_enc     BYTEA,
    buyer_phone_enc     BYTEA,
    buyer_phone_hash    TEXT,                             -- blind index (CS 조회용)
    shipping_address_enc BYTEA,
    -- PG 연계
    pg_order_id         TEXT        NOT NULL UNIQUE,      -- PG에 전달하는 가맹점 주문번호(orderId/merchant_uid)
    checkout_url        TEXT,                             -- 사용자 승인용 호스티드 결제 페이지
    checkout_token_hash TEXT        UNIQUE,               -- URL 내 1회성 토큰의 SHA-256 (원문 미저장)
    -- 에이전트 컨텍스트 (감사/분쟁 대응)
    agent_reference     TEXT,                             -- 에이전트 측 대화/요청 ID
    buyer_consent       JSONB,                            -- 사용자 승인 증적 {method, at, ip_hash, ua}
    idempotency_key     TEXT        NOT NULL,
    expires_at          TIMESTAMPTZ NOT NULL,
    completed_at        TIMESTAMPTZ,
    version             INT         NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (agent_client_id, idempotency_key),
    CHECK (total_amount = subtotal_amount + shipping_amount - discount_amount)
);
CREATE INDEX idx_cs_expiry ON checkout_sessions (expires_at) WHERE status IN ('OPEN','PAYMENT_PENDING');
CREATE INDEX idx_cs_merchant_created ON checkout_sessions (merchant_id, created_at DESC);

CREATE TABLE checkout_session_items (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    checkout_session_id TEXT        NOT NULL REFERENCES checkout_sessions(id),
    variant_id          TEXT        NOT NULL REFERENCES product_variants(id),
    product_title       TEXT        NOT NULL,             -- 스냅샷
    option_values       JSONB       NOT NULL,             -- 스냅샷
    unit_price_amount   BIGINT      NOT NULL CHECK (unit_price_amount >= 0),
    quantity            INT         NOT NULL CHECK (quantity > 0),
    line_total_amount   BIGINT      NOT NULL,
    CHECK (line_total_amount = unit_price_amount * quantity),
    UNIQUE (checkout_session_id, variant_id)
);

-- 재고 홀드 원장. variant.reserved_quantity 와 원자적으로 함께 갱신.
CREATE TABLE inventory_reservations (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    variant_id          TEXT        NOT NULL REFERENCES product_variants(id),
    checkout_session_id TEXT        NOT NULL REFERENCES checkout_sessions(id),
    quantity            INT         NOT NULL CHECK (quantity > 0),
    status              TEXT        NOT NULL DEFAULT 'HELD'
                        CHECK (status IN ('HELD','CONSUMED','RELEASED','EXPIRED')),
    expires_at          TIMESTAMPTZ NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (checkout_session_id, variant_id)
);
CREATE INDEX idx_resv_expiry ON inventory_reservations (expires_at) WHERE status = 'HELD';

-- -----------------------------------------------------------------------------
-- 5. Payment / PG Webhook
-- -----------------------------------------------------------------------------
CREATE TABLE payments (
    id                  TEXT PRIMARY KEY CHECK (id LIKE 'pay\_%'),
    checkout_session_id TEXT        NOT NULL REFERENCES checkout_sessions(id),
    pg_provider         TEXT        NOT NULL,
    pg_payment_key      TEXT        NOT NULL,             -- PG 거래 키 (tid/paymentKey/imp_uid/pi_...)
    method              TEXT,                             -- CARD, EASY_PAY, TRANSFER ...
    status              TEXT        NOT NULL
                        CHECK (status IN ('APPROVED','PARTIAL_CANCELED','CANCELED','FAILED')),
    currency            CHAR(3)     NOT NULL,
    approved_amount     BIGINT      NOT NULL CHECK (approved_amount >= 0),
    canceled_amount     BIGINT      NOT NULL DEFAULT 0 CHECK (canceled_amount >= 0),
    approved_at         TIMESTAMPTZ,
    pg_raw              JSONB,                            -- PG 조회 응답 (카드번호 등 마스킹 후 저장)
    version             INT         NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (pg_provider, pg_payment_key),
    CHECK (canceled_amount <= approved_amount)
);
-- 세션당 승인 결제는 최대 1건 (이중결제 방지 최후 방어선)
CREATE UNIQUE INDEX uq_payment_approved_per_session
    ON payments (checkout_session_id) WHERE status IN ('APPROVED','PARTIAL_CANCELED');

-- 웹훅 수신 원장 (Inbox). 수신 즉시 저장 → 200 응답 → 비동기 처리.
CREATE TABLE pg_webhook_events (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pg_provider         TEXT        NOT NULL,
    dedupe_key          TEXT        NOT NULL,             -- PG event id, 없으면 sha256(payload)
    event_type          TEXT        NOT NULL,
    pg_order_id         TEXT,
    signature_verified  BOOLEAN     NOT NULL,
    payload             JSONB       NOT NULL,
    process_status      TEXT        NOT NULL DEFAULT 'RECEIVED'
                        CHECK (process_status IN ('RECEIVED','PROCESSED','IGNORED','FAILED')),
    attempt_count       INT         NOT NULL DEFAULT 0,
    last_error          TEXT,
    received_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at        TIMESTAMPTZ,
    UNIQUE (pg_provider, dedupe_key)
);
CREATE INDEX idx_webhook_pending ON pg_webhook_events (received_at) WHERE process_status IN ('RECEIVED','FAILED');

-- -----------------------------------------------------------------------------
-- 6. Order (주문) & OMS 라우팅
-- -----------------------------------------------------------------------------
CREATE TABLE orders (
    id                  TEXT PRIMARY KEY CHECK (id LIKE 'ord\_%'),
    merchant_id         TEXT        NOT NULL REFERENCES merchants(id),
    agent_client_id     TEXT        NOT NULL REFERENCES agent_clients(id),
    checkout_session_id TEXT        NOT NULL UNIQUE REFERENCES checkout_sessions(id), -- 세션당 주문 1건 보장
    payment_id          TEXT        NOT NULL UNIQUE REFERENCES payments(id),
    status              TEXT        NOT NULL DEFAULT 'CREATED'
                        CHECK (status IN ('CREATED','DISPATCHING','ACCEPTED','REJECTED',
                                          'SHIPPED','DELIVERED','CANCEL_REQUESTED','CANCELED','REFUNDED')),
    currency            CHAR(3)     NOT NULL,
    total_amount        BIGINT      NOT NULL CHECK (total_amount >= 0),
    commission_amount   BIGINT      NOT NULL DEFAULT 0,   -- 플랫폼 수수료 (별도 청구)
    buyer_name_enc      BYTEA,
    buyer_email_enc     BYTEA,
    buyer_phone_enc     BYTEA,
    buyer_phone_hash    TEXT,
    shipping_address_enc BYTEA,
    merchant_order_ref  TEXT,                             -- OMS 발급 주문번호 (전송 성공 후)
    tracking_info       JSONB,                            -- {carrier, tracking_no}
    version             INT         NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_orders_merchant_created ON orders (merchant_id, created_at DESC);
CREATE INDEX idx_orders_status ON orders (status) WHERE status IN ('CREATED','DISPATCHING','CANCEL_REQUESTED');
CREATE UNIQUE INDEX uq_orders_merchant_ref ON orders (merchant_id, merchant_order_ref) WHERE merchant_order_ref IS NOT NULL;

CREATE TABLE order_items (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id            TEXT        NOT NULL REFERENCES orders(id),
    variant_id          TEXT        NOT NULL REFERENCES product_variants(id),
    merchant_sku        TEXT        NOT NULL,             -- OMS 매핑 키 스냅샷
    product_title       TEXT        NOT NULL,
    option_values       JSONB       NOT NULL,
    unit_price_amount   BIGINT      NOT NULL,
    quantity            INT         NOT NULL CHECK (quantity > 0),
    line_total_amount   BIGINT      NOT NULL
);
CREATE INDEX idx_order_items_order ON order_items (order_id);

-- 주문 상태 전이 이력 (append-only, 감사 대상)
CREATE TABLE order_status_history (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id            TEXT        NOT NULL REFERENCES orders(id),
    from_status         TEXT,
    to_status           TEXT        NOT NULL,
    reason              TEXT,
    actor_type          TEXT        NOT NULL CHECK (actor_type IN ('SYSTEM','PG','OMS','AGENT','OPERATOR')),
    actor_id            TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_osh_order ON order_status_history (order_id, created_at);

-- OMS 전송 작업 (at-least-once + 재시도/백오프). 1 주문 1 행, 시도 내역은 attempts.
CREATE TABLE order_dispatches (
    order_id            TEXT PRIMARY KEY REFERENCES orders(id),
    oms_connection_id   TEXT        NOT NULL REFERENCES merchant_oms_connections(id),
    status              TEXT        NOT NULL DEFAULT 'PENDING'
                        CHECK (status IN ('PENDING','IN_FLIGHT','SUCCEEDED','RETRYING','DEAD')),
    attempt_count       INT         NOT NULL DEFAULT 0,
    next_attempt_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_error          TEXT,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_dispatch_due ON order_dispatches (next_attempt_at) WHERE status IN ('PENDING','RETRYING');

CREATE TABLE order_dispatch_attempts (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id            TEXT        NOT NULL REFERENCES orders(id),
    attempt_no          INT         NOT NULL,
    http_status         INT,
    request_body        JSONB,                            -- PII 마스킹
    response_body       JSONB,
    error_class         TEXT,                             -- TIMEOUT, AUTH, VALIDATION, OUT_OF_STOCK ...
    latency_ms          INT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (order_id, attempt_no)
);

-- -----------------------------------------------------------------------------
-- 7. Cross-cutting: Idempotency / Outbox / Audit
-- -----------------------------------------------------------------------------
CREATE TABLE idempotency_keys (
    agent_client_id     TEXT        NOT NULL REFERENCES agent_clients(id),
    idempotency_key     TEXT        NOT NULL,
    request_method      TEXT        NOT NULL,
    request_path        TEXT        NOT NULL,
    request_hash        TEXT        NOT NULL,             -- 같은 키 + 다른 바디 → 422
    response_status     INT,                              -- NULL = 처리 중 (409 반환)
    response_body       JSONB,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at          TIMESTAMPTZ NOT NULL DEFAULT now() + INTERVAL '24 hours',
    PRIMARY KEY (agent_client_id, idempotency_key)
);
CREATE INDEX idx_idem_expiry ON idempotency_keys (expires_at);

-- Transactional Outbox → relay가 SQS로 발행 (DB 커밋과 이벤트 발행의 원자성)
CREATE TABLE outbox_events (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    aggregate_type      TEXT        NOT NULL,             -- ORDER, CHECKOUT_SESSION, PRODUCT ...
    aggregate_id        TEXT        NOT NULL,
    event_type          TEXT        NOT NULL,             -- order.created, payment.approved ...
    payload             JSONB       NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at        TIMESTAMPTZ
);
CREATE INDEX idx_outbox_unpublished ON outbox_events (id) WHERE published_at IS NULL;

-- 감사 로그 (append-only, 월 파티션). 운영자 PII 열람/설정 변경/환불 등 기록.
CREATE TABLE audit_logs (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY,
    occurred_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    actor_type          TEXT        NOT NULL,             -- AGENT, MERCHANT_USER, OPERATOR, SYSTEM
    actor_id            TEXT        NOT NULL,
    action              TEXT        NOT NULL,             -- e.g. 'order.refund', 'pii.view'
    target_type         TEXT        NOT NULL,
    target_id           TEXT        NOT NULL,
    request_id          TEXT,                             -- trace 연계
    source_ip           INET,
    detail              JSONB,                            -- before/after (마스킹)
    PRIMARY KEY (id, occurred_at)
) PARTITION BY RANGE (occurred_at);
CREATE TABLE audit_logs_2026_10 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
-- 이후 파티션은 pg_partman 또는 배치로 선생성. 애플리케이션 계정에는 INSERT 권한만 부여.
